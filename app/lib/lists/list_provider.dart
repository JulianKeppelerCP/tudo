import 'package:flutter/material.dart';
import 'package:tudo_app/crdt/hlc.dart';
import 'package:tudo_app/crdt/sqflite_crdt.dart';
import 'package:tudo_app/crdt/tudo_crdt.dart';
import 'package:tudo_app/extensions.dart';
import 'package:tudo_app/util/store.dart';
import 'package:tudo_app/util/uuid.dart';

const listIdsKey = 'list_id_keys';

class ListProvider {
  final String userId;
  final TudoCrdt _crdt;

  Stream get allChanges => _crdt.allChanges;

  Stream<List<ToDoList>> get lists => _crdt.query('''
        SELECT * FROM user_lists
        LEFT JOIN lists ON user_lists.list_id = id
        LEFT JOIN (
          SELECT list_id as count_list_id, count(*) as item_count, sum(done) as done_count
          FROM todos WHERE is_deleted = 0 GROUP BY list_id
        ) ON count_list_id = id
        WHERE user_lists.is_deleted = 0
        ORDER BY position
      ''').map((l) => l.map(ToDoList.fromMap).toList());

  ListProvider(this.userId, this._crdt, StoreProvider storeProvider) {
    final legacyLists = storeProvider.legacyListIds;
    if (legacyLists != null) {
      // Upgrading from tudo v1
      Future.wait(legacyLists.map(import))
          .then((_) => storeProvider.purgeLegacyListIds());
    }
  }

  Future<void> createList(String name, Color color) async {
    final listId = uuid();

    final batch = _crdt.newBatch();
    batch.setFields('lists', [
      listId
    ], {
      'name': name,
      'color': color.hexValue,
      'creator_id': userId,
      'created_at': DateTime.now(),
    });
    await _setListReference(batch, listId);
    await _crdt.commit(batch);
  }

  Future<void> import(String listId, [int? position]) async {
    final exists = await _crdt.queryAsync('''
      SELECT EXISTS (
        SELECT * FROM user_lists WHERE user_id = ? AND list_id = ? AND is_deleted = 0
      ) AS e
    ''', [userId, listId]);
    if (exists.first['e'] == 1) {
      'Import: already have $listId'.log;
      return;
    }

    'Importing $listId'.log;
    final batch = _crdt.newBatch();
    await _setListReference(batch, listId);
    await _crdt.commit(batch);
  }

  Future<void> _setListReference(CrdtBatch batch, String listId) async {
    final maxPosition = (await _crdt.queryAsync('''
        SELECT max(position) as max_position FROM user_lists
        WHERE is_deleted = 0
      ''')).first['max_position'] ?? -1;
    batch
      ..setField('user_lists', [userId, listId], 'created_at', DateTime.now())
      ..setDeleted('user_lists', [userId, listId], false)
      ..setField('user_lists', [userId, listId], 'position', maxPosition + 1);
  }

  Stream<ToDoList> getList(String listId) =>
      lists.map((e) => e.firstWhere((e) => e.id == listId));

  Stream<List<ToDo>> getItems(String listId) => _crdt.query(
        '''
          SELECT * FROM todos
          WHERE list_id = ? AND is_deleted = 0
          ORDER BY position
        ''',
        [listId],
      ).map((l) => l.map(ToDo.fromMap).toList());

  Future<int> delete(String listId) async {
    await _crdt.setDeleted('lists', [listId]);
    return 0;
  }

  Future<void> deleteItem(String id) => _crdt.setDeleted('todos', [id]);

  Future<void> undeleteItem(String id) =>
      _crdt.setDeleted('todos', [id], false);

  Future<void> setDone(String itemId, bool isDone) =>
      _crdt.setField('todos', [itemId], 'done', isDone);

  Future<void> setItemName(String itemId, String name) =>
      _crdt.setField('todos', [itemId], 'name', name);

  Future<Hlc> merge(List<Map<String, dynamic>> changeset) =>
      _crdt.merge(changeset);

  Future<CrdtChangeset> changeset(Hlc? lastSync) =>
      _crdt.getChangeset(modifiedSince: lastSync, onlyModifiedHere: true);

  void setName(String listId, String name) =>
      _crdt.setField('lists', [listId], 'name', name);

  void setColor(String listId, Color color) =>
      _crdt.setField('lists', [listId], 'color', color.hexValue);

  Future<void> createItem(String listId, String name) async {
    final id = uuid();
    final maxPosition = (await _crdt.queryAsync('''
        SELECT max(position) AS max_position FROM todos
        WHERE list_id = ? AND is_deleted = 0
      ''', [listId])).first['max_position'] ?? -1;
    await _crdt.setFields('todos', [
      id
    ], {
      'list_id': listId,
      'name': name,
      'done': false,
      'position': maxPosition + 1,
      'creator_id': userId,
      'created_at': DateTime.now(),
    });
  }

  Future<void> setListOrder(List<ToDoList> lists) async {
    final batch = _crdt.newBatch();
    for (int i = 0; i < lists.length; i++) {
      final list = lists[i];
      if (list.position != i) {
        batch.setField('user_lists', [userId, list.id], 'position', i);
      }
    }
    await _crdt.commit(batch);
  }

  Future<void> setItemOrder(List<ToDo> items) async {
    final batch = _crdt.newBatch();
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.position != i) {
        batch.setField('todos', [item.id], 'position', i);
      }
    }
    await _crdt.commit(batch);
  }
}

class ToDoList {
  final String id;
  final String name;
  final Color color;
  final String? creatorId;
  final DateTime? createdAt;
  final int position;
  final int itemCount;
  final int doneCount;

  bool get isEmpty => itemCount == 0;

  const ToDoList(this.id, this.name, this.color, this.creatorId, this.createdAt,
      this.position, this.itemCount, this.doneCount);

  ToDoList.fromMap(Map<String, dynamic> map)
      : this(
          map['id'],
          map['name'],
          (map['color'] as String).asColor,
          map['creator_id'],
          (map['created_at'] as String?)?.asDateTime,
          map['position'],
          map['item_count'] ?? 0,
          map['done_count'] ?? 0,
        );

  @override
  String toString() => '$name [$doneCount/$itemCount]';
}

class ToDo {
  final String id;
  final String name;
  final bool done;
  final int position;
  final String? creatorId;
  final DateTime? createdAt;

  // Transient marker while item is deleted
  bool isDeleted;

  ToDo(this.id, this.name, this.done, this.position, this.creatorId,
      this.createdAt,
      [this.isDeleted = false]);

  factory ToDo.fromMap(Map<String, dynamic> map) => ToDo(
        map['id'],
        map['name'],
        map['done'] == 1,
        map['position'],
        map['creator_id'],
        (map['created_at'] as String?)?.asDateTime,
      );

  @override
  bool operator ==(Object other) => other is ToDo && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '$name ${done ? '🗹' : '☐'}';
}
