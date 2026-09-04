import 'dart:async';

import 'package:meta/meta.dart';

/// State a screen watches.
///
/// Every engine changes its fields and then calls [notify]; a view rebuilds
/// on [changes]. That is the whole of the contract, and it is deliberately
/// smaller than a UI framework's: the engines must not depend on one.
abstract class Observable {
  final _changes = StreamController<void>.broadcast(sync: true);
  bool _disposed = false;

  /// Fires after every change of state. Sync, so a listener sees the new
  /// values in the same turn that produced them.
  Stream<void> get changes => _changes.stream;

  @protected
  void notify() {
    if (!_disposed) _changes.add(null);
  }

  @mustCallSuper
  void dispose() {
    _disposed = true;
    _changes.close();
  }
}
