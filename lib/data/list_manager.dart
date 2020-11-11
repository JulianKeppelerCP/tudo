import 'dart:convert';

import 'package:crdt/crdt.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import 'extensions.dart';
import 'hive/hive_crdt.dart';
import 'random_id.dart';

const listIdsKey = 'list_id_keys';

class ListManager with ChangeNotifier {
  final String nodeId;
  final Box<List<String>> _box;
  final _toDoLists = <String, ToDoList>{};

  List<String> get _listIds => _box.get(listIdsKey, defaultValue: []);

  set _listIds(List<String> values) => _box.put(listIdsKey, values);

  List<ToDoList> get lists =>
      _listIds.map((e) => _toDoLists[e]).where((e) => e != null).toList();

  static Future<ListManager> open(String nodeId) async {
    final box = await Hive.openBox<List<String>>('store');
    return ListManager._(nodeId, box);
  }

  ListManager._(this.nodeId, this._box) {
    _init();
  }

  Future<void> _init() async {
    // Open all the to do lists
    for (String id in _listIds) {
      _toDoLists[id] = await ToDoList.import(this, id);
    }
    notify();
  }

  Future<void> create(String name, Color color) async {
    final id = RandomId().generate();
    _listIds = _listIds..add(id);
    _toDoLists[id] = await ToDoList.open(this, id, name, color);
    notify();
  }

  Future<void> import(String id, [int index]) async {
    if (_listIds.contains(id)) return;
    _listIds =
        index == null ? (_listIds..add(id)) : (_listIds..insert(index, id));
    _toDoLists[id] = await ToDoList.import(this, id);
    notify();
  }

  ToDoList get(String id) => _toDoLists[id];

  void swap(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final id = _listIds[oldIndex];
    _listIds = _listIds
      ..removeAt(oldIndex)
      ..insert(newIndex, id);
  }

  int remove(String id) {
    final index = _listIds.indexOf(id);
    _listIds = _listIds..remove(id);
    _toDoLists.remove(id);
    notify();
    return index;
  }

  void notify() => notifyListeners();
}

class ToDoList {
  static final nameKey = '__name__';
  static final colorKey = '__color__';
  static final orderKey = '__order__';

  final ListManager _parent;
  final String id;
  final Crdt<String, dynamic> _toDoCrdt;

  String get name => _toDoCrdt.get(nameKey) ?? 'loading';

  Color get color => _toDoCrdt.get(colorKey) ?? Colors.blue;

  List<ToDo> get toDos =>
      _order.map((id) => _toDoCrdt.get(id)).toList().cast<ToDo>();

  List<String> get _order => _toDoCrdt.get(orderKey)?.cast<String>() ?? [];

  set _order(List<String> values) => _toDoCrdt.put(orderKey, values);

  set name(String value) {
    value = value.trim();
    if (value == name) return;
    _toDoCrdt.put(nameKey, value);
    _parent.notify();
  }

  set color(Color value) {
    if (value == color) return;
    _toDoCrdt.put(colorKey, value);
    _parent.notify();
  }

  ToDoList._internal(this._parent, this.id, this._toDoCrdt) {
    // Verify order integrity
    final toDos = _toDoCrdt.values.whereType<ToDo>().toList();
    if (_order.length != toDos.length) {
      _order = (toDos..sort((a, b) => a.name.compareTo(b.name)))
          .map((e) => e.id)
          .toList();
    }
  }

  static Future<ToDoList> open(
      ListManager parent, String id, String name, Color color) async {
    final crdt = await HiveCrdt.open<String, dynamic>(id, parent.nodeId);
    if (name != null) crdt.put(nameKey, name);
    if (color != null) crdt.put(colorKey, color);
    return ToDoList._internal(parent, id, crdt);
  }

  static Future<ToDoList> import(ListManager parent, String id) =>
      open(parent, id, null, null);

  void add(String name) => set(name, false);

  void set(String name, bool checked, [int index]) {
    if (name.trim().isEmpty) return;

    final toDo = ToDo(name, checked);

    if (!_order.contains(toDo.id)) {
      _order = index == null
          ? (_order..add(toDo.id))
          : (_order..insert(index, toDo.id));
    }
    _toDoCrdt.put(toDo.id, toDo);
    _parent.notify();
  }

  void swap(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final id = _order[oldIndex];
    _order = _order
      ..removeAt(oldIndex)
      ..insert(newIndex, id);
    _parent.notify();
  }

  int remove(String id) {
    final index = _order.indexOf(id);
    _order.remove(id);
    _toDoCrdt.delete(id);
    _parent.notify();
    return index;
  }

  String toJson() => _toDoCrdt.toJson(
      valueEncoder: (key, value) => value is Color ? value.hexValue : value);

  void mergeJson(String json) {
    final original = _toDoCrdt.recordMap();

    _toDoCrdt.mergeJson(
      json,
      valueDecoder: (key, value) {
        return value is Map
            ? ToDo.fromJson(value)
            : key == colorKey
                ? ColorExtensions.fromHex(value)
                : value;
      },
    );
    if (_toDoCrdt.recordMap().toString() != original.toString()) {
      _parent.notify();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ToDoList &&
      id == other.id &&
      name == other.name &&
      _toDoCrdt.recordMap() == other._toDoCrdt.recordMap();

  @override
  int get hashCode => id.hashCode & name.hashCode & _toDoCrdt.hashCode;

  @override
  String toString() => '$name [${toDos.length}]';
}

class ToDo {
  final String name;
  final bool checked;

  String get id => md5.convert(utf8.encode(name.toLowerCase())).toString();

  ToDo(String name, this.checked) : name = name.trim();

  factory ToDo.fromJson(Map<String, dynamic> map) =>
      ToDo(map['name'], map['checked']);

  Map<String, dynamic> toJson() => {
        'name': name,
        'checked': checked,
      };

  @override
  bool operator ==(Object other) => other is ToDo && other.name == this.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => toJson().toString();
}
