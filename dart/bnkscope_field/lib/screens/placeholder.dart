import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../observe.dart';
import '../widgets.dart';

/// A screen that has not been ported yet. Says so, rather than pretending.
class PlaceholderScreen extends StatelessWidget {
  final Section section;
  const PlaceholderScreen(this.section, {super.key});

  @override
  Widget build(BuildContext context) {
    final store = Engines.of(context).store;
    return Observe([store], builder: (context) {
      return Column(children: [
        Toolbar(title: section.title),
        Expanded(
          child: Message(
            title: '${section.title} is not here yet',
            detail: 'This screen has not been ported to the Flutter build. '
                '${store.current?.displayName ?? 'The cluster'} is selected and its engine is ready; the screen comes next.',
          ),
        ),
      ]);
    });
  }
}
