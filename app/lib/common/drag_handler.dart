import 'package:flutter/material.dart';
import 'package:implicitly_animated_reorderable_list/implicitly_animated_reorderable_list.dart';
import 'package:tudo_app/extensions.dart';

class DragHandle extends StatelessWidget {
  const DragHandle({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Handle(
      vibrate: true,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          Icons.drag_indicator,
          color: context.theme.dividerColor,
        ),
      ),
    );
  }
}
