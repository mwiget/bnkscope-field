import 'dart:async';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds [builder] whenever any of [engines] notifies.
///
/// The one adapter between the engines' change stream and the widget tree.
/// Engines know nothing about widgets; widgets subscribe here and nowhere
/// else.
class Observe extends StatefulWidget {
  final List<Observable> engines;
  final WidgetBuilder builder;

  const Observe(this.engines, {super.key, required this.builder});

  @override
  State<Observe> createState() => _ObserveState();
}

class _ObserveState extends State<Observe> {
  final List<StreamSubscription<void>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(Observe old) {
    super.didUpdateWidget(old);
    if (old.engines.length != widget.engines.length ||
        Iterable<int>.generate(old.engines.length).any((i) => !identical(old.engines[i], widget.engines[i]))) {
      _unsubscribe();
      _subscribe();
    }
  }

  void _subscribe() {
    for (final e in widget.engines) {
      _subscriptions.add(e.changes.listen((_) {
        if (mounted) setState(() {});
      }));
    }
  }

  void _unsubscribe() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
