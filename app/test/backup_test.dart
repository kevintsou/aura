import 'dart:io';
import 'dart:typed_data';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/backup_files.dart';
import 'package:aura/services/snapshot_store.dart';
import 'package:aura/services/snapshot_store_io.dart';
import 'package:aura_core/aura_core.dart';
import 'package:aura_store/aura_store.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

class _FakeFiles implements BackupFiles {
  String? savedName;
  Uint8List? saved;
  ({String name, Uint8List bytes})? toPick;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    savedName = fileName;
    saved = bytes;
    return true;
  }

  @override
  Future<({String name, Uint8List bytes})?> pick({String title = ''}) async => toPick;
}

var _now = DateTime(2026, 9, 29, 21, 30);

Future<AppState> _app({LedgerStore? ledger, _FakeFiles? files, SnapshotStore? snapshots}) async {
  final app = AppState(
    ledger: ledger ?? SqliteLedger.inMemory(),
    settings: MemoryAiSettingsStore(),
    files: files ?? _FakeFiles(),
    snapshots: snapshots ?? MemorySnapshotStore(),
    kdfIterations: 1000,
    clock: () => _now,
  );
  await app.load();
  return app;
}

void main() {
  setUp(() => _now = DateTime(2026, 9, 29, 21, 30));

  group('backup files', () {
    test('a backup restores everything on another device', () async {
      final files = _FakeFiles();
      final phone = await _app(files: files);
      await phone.importCwmoney(_sample, 'sample.csv');
      final savings = phone.ledger.accounts.firstWhere((a) => a.name == '活存-測試');
      phone.setBalanceAnchor(savings.id, BalanceAnchor(amount: Decimal.fromInt(5000), date: DateTime(2026, 9, 29)));
      expect(phone.backupOverdue, isTrue);

      final name = await phone.exportBackup();
      expect(name, 'aura-20260929-2130.aura');
      expect(files.savedName, name);
      expect(phone.lastBackupAt, _now);
      expect(phone.backupOverdue, isFalse);

      final newPhone = await _app();
      final info = await newPhone.restoreBackup(files.saved!);
      expect(info.transactions, 11);
      expect(newPhone.ledger.count(), 11);
      expect(newPhone.importedFileName, 'sample.csv');
      expect(newPhone.balances[savings.id]!.current, Decimal.fromInt(5000));
      expect(newPhone.lastBackupAt, isNull, reason: 'backup history is per device');
    });

    test('password-protected backups need the right password', () async {
      final files = _FakeFiles();
      final phone = await _app(files: files);
      await phone.importCwmoney(_sample, 'sample.csv');
      await phone.exportBackup(password: 'secret');
      expect(readBackupInfo(files.saved!).encrypted, isTrue);

      final other = await _app();
      other.startFresh();
      await expectLater(
        other.restoreBackup(files.saved!, password: 'wrong'),
        throwsA(isA<BackupException>()),
      );
      expect(other.ledger.accounts.single.name, '現金', reason: 'untouched');
      await other.restoreBackup(files.saved!, password: 'secret');
      expect(other.ledger.count(), 11);
    });

    test('backups become overdue after 30 days', () async {
      final app = await _app();
      await app.importCwmoney(_sample, 'sample.csv');
      await app.exportBackup();
      _now = _now.add(const Duration(days: 29));
      expect(app.backupOverdue, isFalse);
      _now = _now.add(const Duration(days: 1));
      expect(app.backupOverdue, isTrue);
    });
  });

  group('automatic snapshots', () {
    test('a restore keeps the replaced data as a snapshot', () async {
      final files = _FakeFiles();
      final a = await _app(files: files);
      a.startFresh();
      await a.exportBackup(); // an empty-ish ledger: one cash account

      final b = await _app();
      await b.importCwmoney(_sample, 'sample.csv');
      await b.restoreBackup(files.saved!);
      expect(b.ledger.count(), 0);

      final snap = (await b.snapshots.list()).first;
      expect(snap.reason, SnapshotReason.beforeRestore);
      await b.restoreBackup(await b.snapshots.read(snap));
      expect(b.ledger.count(), 11, reason: 'rescued');
    });

    test('an import keeps the previous data as a snapshot', () async {
      final app = await _app();
      app.startFresh();
      await app.importCwmoney(_sample, 'sample.csv');
      final snaps = await app.snapshots.list();
      expect(snaps.single.reason, SnapshotReason.beforeImport);
    });

    test('daily snapshots happen once a day and not for an empty ledger', () async {
      final app = await _app();
      await app.dailySnapshot();
      expect(await app.snapshots.list(), isEmpty);

      app.startFresh();
      await app.dailySnapshot();
      await app.dailySnapshot();
      expect(await app.snapshots.list(), hasLength(1));

      _now = _now.add(const Duration(days: 1));
      await app.dailySnapshot();
      expect(await app.snapshots.list(), hasLength(2));
    });

    test('snapshot files keep the newest ${SnapshotStore.keep}', () async {
      final dir = Directory.systemTemp.createTempSync('aura_snap');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = DirectorySnapshotStore(dir);
      for (var i = 0; i < 9; i++) {
        await store.save(
          Uint8List.fromList([i]),
          at: DateTime(2026, 9, 1 + i),
          reason: SnapshotReason.daily,
        );
      }
      final list = await store.list();
      expect(list, hasLength(SnapshotStore.keep));
      expect(list.first.at, DateTime(2026, 9, 9));
      expect(await store.read(list.first), [8]);
      expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });
  });

  group('backup screen', () {
    /// Isolate work runs in real time, but the futures chained after it
    /// only advance when the fake clock pumps: alternate the two.
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(done(), isTrue, reason: 'background work did not finish');
      await tester.pumpAndSettle();
    }

    Future<AppState> open(WidgetTester tester, _FakeFiles files) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = (await tester.runAsync(() async {
        final app = await _app(ledger: InMemoryLedger(), files: files);
        await app.importCwmoney(_sample, 'sample.csv');
        return app;
      }))!;
      await tester.pumpWidget(AuraApp(app: app));
      await tester.tap(find.text('設定'));
      await tester.pumpAndSettle();
      expect(find.text('還沒有備份檔'), findsOneWidget);
      await tester.tap(find.byKey(const Key('backupSettings')));
      await tester.pumpAndSettle();
      return app;
    }

    testWidgets('creates a password-protected backup file', (tester) async {
      final files = _FakeFiles();
      final app = await open(tester, files);
      await tester.tap(find.byKey(const Key('exportBackup')));
      await tester.pumpAndSettle();

      final create = find.byKey(const Key('confirmExport'));
      await tester.enterText(find.byKey(const Key('backupPassword')), 'abcd');
      await tester.enterText(find.byKey(const Key('backupPasswordConfirm')), 'abce');
      await tester.pump();
      expect(find.text('兩次輸入的密碼不同'), findsOneWidget);
      expect(tester.widget<FilledButton>(create).onPressed, isNull);

      await tester.enterText(find.byKey(const Key('backupPasswordConfirm')), 'abcd');
      await tester.pump();
      await tester.tap(create);
      await settle(tester, () => files.saved != null);
      expect(find.text('已儲存 aura-20260929-2130.aura'), findsOneWidget);
      expect(readBackupInfo(files.saved!).encrypted, isTrue);
      expect(app.lastBackupAt, _now);
    });

    testWidgets('restores a backup file after showing what is in it', (tester) async {
      final files = _FakeFiles();
      final app = await open(tester, files);
      final backup = (await tester.runAsync(() async {
        final other = await _app(ledger: InMemoryLedger());
        other.startFresh();
        return encodeBackup(other.ledger, createdAt: DateTime(2026, 9, 1, 8), password: 'pw', iterations: 1000);
      }))!;
      files.toPick = (name: 'old.aura', bytes: backup);

      await tester.tap(find.byKey(const Key('restoreBackup')));
      await tester.pumpAndSettle();
      expect(find.textContaining('建立時間：2026/09/01 08:00'), findsOneWidget);
      expect(find.textContaining('目前的 11 筆紀錄會被取代'), findsOneWidget);
      final restore = find.byKey(const Key('confirmRestore'));
      expect(tester.widget<FilledButton>(restore).onPressed, isNull, reason: 'needs password');

      await tester.enterText(find.byKey(const Key('restorePassword')), 'pw');
      await tester.pump();
      await tester.tap(restore);
      await settle(tester, () => app.ledger.count() == 0);
      expect(app.ledger.accounts.single.name, '現金');
      expect(find.text('已還原 0 筆紀錄'), findsOneWidget);
      expect(find.text('還原備份之前'), findsOneWidget, reason: 'snapshot listed');
    });

    testWidgets('explains files that are not backups', (tester) async {
      final files = _FakeFiles()..toPick = (name: 'x.csv', bytes: Uint8List.fromList(_sample));
      await open(tester, files);
      await tester.tap(find.byKey(const Key('restoreBackup')));
      await tester.pumpAndSettle();
      expect(find.text('這不是 Aura 的備份檔'), findsOneWidget);
    });
  });
}
