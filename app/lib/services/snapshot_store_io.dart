import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'snapshot_store.dart';

Future<SnapshotStore> openSnapshotStore() async {
  final base = await getApplicationSupportDirectory();
  return DirectorySnapshotStore(Directory('${base.path}/snapshots'));
}

/// One `<epoch-ms>-<reason>.aura` file per snapshot.
class DirectorySnapshotStore extends SnapshotStore {
  DirectorySnapshotStore(this.dir);

  final Directory dir;
  static final _name = RegExp(r'^(\d+)-(\w+)\.aura$');

  @override
  Future<List<Snapshot>> list() async {
    if (!await dir.exists()) return const [];
    final items = <Snapshot>[];
    await for (final f in dir.list()) {
      final m = _name.firstMatch(f.uri.pathSegments.last);
      final reason = SnapshotReason.values.where((r) => r.name == m?[2]).firstOrNull;
      if (m == null || reason == null) continue;
      items.add(
        Snapshot(
          id: f.path,
          at: DateTime.fromMillisecondsSinceEpoch(int.parse(m[1]!)),
          reason: reason,
        ),
      );
    }
    return items..sort((a, b) => b.at.compareTo(a.at));
  }

  @override
  Future<void> save(Uint8List bytes, {required DateTime at, required SnapshotReason reason}) async {
    await dir.create(recursive: true);
    final path = '${dir.path}/${at.millisecondsSinceEpoch}-${reason.name}.aura';
    // Write then rename, so a crash never leaves a half-written snapshot.
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
    for (final old in (await list()).skip(SnapshotStore.keep)) {
      await File(old.id).delete();
    }
  }

  @override
  Future<Uint8List> read(Snapshot snapshot) => File(snapshot.id).readAsBytes();
}
