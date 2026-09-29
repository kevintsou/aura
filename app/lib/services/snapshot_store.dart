import 'dart:typed_data';

import 'snapshot_store_memory.dart'
    if (dart.library.io) 'snapshot_store_io.dart'
    as impl;

enum SnapshotReason { daily, beforeImport, beforeRestore }

class Snapshot {
  const Snapshot({required this.id, required this.at, required this.reason});

  final String id;
  final DateTime at;
  final SnapshotReason reason;
}

/// Automatic backups kept on this device, newest first. They protect
/// against mistakes (a wrong import or restore), not against losing the
/// phone: that needs a backup file stored elsewhere.
abstract class SnapshotStore {
  /// How many snapshots are kept; older ones are deleted.
  static const keep = 7;

  Future<List<Snapshot>> list();
  Future<void> save(Uint8List bytes, {required DateTime at, required SnapshotReason reason});
  Future<Uint8List> read(Snapshot snapshot);
}

/// Files in the app's private directory on devices; memory on the web.
Future<SnapshotStore> openSnapshotStore() => impl.openSnapshotStore();

class MemorySnapshotStore extends SnapshotStore {
  final _items = <(Snapshot, Uint8List)>[];

  @override
  Future<List<Snapshot>> list() async => [for (final (s, _) in _items) s];

  @override
  Future<void> save(Uint8List bytes, {required DateTime at, required SnapshotReason reason}) async {
    _items.insert(0, (Snapshot(id: '${at.microsecondsSinceEpoch}', at: at, reason: reason), bytes));
    if (_items.length > SnapshotStore.keep) _items.removeRange(SnapshotStore.keep, _items.length);
  }

  @override
  Future<Uint8List> read(Snapshot snapshot) async =>
      _items.firstWhere((e) => e.$1.id == snapshot.id).$2;
}
