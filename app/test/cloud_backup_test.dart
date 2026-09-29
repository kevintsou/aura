import 'dart:io';
import 'dart:typed_data';

import 'package:aura/app_state.dart';
import 'package:aura/cloud/cloud_backup.dart';
import 'package:aura/cloud/cloud_target.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

/// A cloud folder in memory, shared by every "phone" in a test.
class _FakeCloud implements CloudTarget {
  final files = <String, Uint8List>{};
  String? failWith;
  final deleted = <String>[];

  void _maybeFail() {
    if (failWith case final m?) throw CloudException(m);
  }

  @override
  Future<void> test() async => _maybeFail();

  @override
  Future<List<CloudFile>> list() async {
    _maybeFail();
    return [for (final e in files.entries) CloudFile(name: e.key, size: e.value.length)]
      ..sort((a, b) => b.name.compareTo(a.name));
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    _maybeFail();
    files[name] = bytes;
  }

  @override
  Future<Uint8List> download(CloudFile file) async => files[file.name]!;

  @override
  Future<void> delete(CloudFile file) async {
    deleted.add(file.name);
    files.remove(file.name);
  }
}

var _now = DateTime(2026, 9, 29, 21, 30);

AppState _phone(_FakeCloud cloud, {MemoryCloudSettingsStore? store}) => AppState(
  ledger: InMemoryLedger(),
  settings: MemoryAiSettingsStore(),
  cloudStore: store ?? MemoryCloudSettingsStore(),
  cloudTargets: (config, {webdavPassword}) => cloud,
  kdfIterations: 1000,
  clock: () => _now,
);

const _webdav = CloudConfig(
  kind: CloudKind.webdav,
  account: 'me@cloud.example.com',
  webdavUrl: 'https://cloud.example.com/dav',
  webdavUser: 'me',
);

void main() {
  setUp(() => _now = DateTime(2026, 9, 29, 21, 30));

  test('turning on checks the connection and needs a long enough password', () async {
    final cloud = _FakeCloud();
    final store = MemoryCloudSettingsStore();
    final app = _phone(cloud, store: store);
    await app.load();
    await expectLater(app.cloud.enable(_webdav, backupPassword: 'short'), throwsA(isA<CloudException>()));
    cloud.failWith = '帳號或密碼不對';
    await expectLater(
      app.cloud.enable(_webdav, webdavPassword: 'dav', backupPassword: 'long enough'),
      throwsA(isA<CloudException>().having((e) => e.message, 'message', '帳號或密碼不對')),
    );
    expect(app.cloud.enabled, isFalse);
    expect(store.secrets, isEmpty);

    cloud.failWith = null;
    await app.cloud.enable(_webdav, webdavPassword: 'dav', backupPassword: 'long enough');
    expect(app.cloud.enabled, isTrue);
    expect(store.secrets, {'webdav_password': 'dav', 'backup_password': 'long enough'});
    expect(cloud.files, isEmpty, reason: 'no upload until the user has seen what is in the cloud');
  });

  test('backs up encrypted, keeps only the newest of its own files', () async {
    final cloud = _FakeCloud()..files['aura-20200101-0800.aura'] = Uint8List(1); // a manual export
    final app = _phone(cloud);
    await app.load();
    await app.importCwmoney(_sample, 'a.csv');
    await app.cloud.enable(_webdav, webdavPassword: 'dav', backupPassword: 'long enough');
    await app.cloud.setKeep(3);
    for (var i = 0; i < 5; i++) {
      await app.cloud.backupNow();
      _now = _now.add(const Duration(days: 1));
    }
    expect(cloud.files.keys.toList()..sort(), [
      'aura-20200101-0800.aura',
      'aura-20261001-213000.aura',
      'aura-20261002-213000.aura',
      'aura-20261003-213000.aura',
    ]);
    final info = readBackupInfo(cloud.files['aura-20261003-213000.aura']!);
    expect((info.encrypted, info.transactions), (true, 11));
    expect(app.cloud.config.lastFile, 'aura-20261003-213000.aura');
  });

  test('runs when due, records failures and waits before retrying', () async {
    final cloud = _FakeCloud();
    final app = _phone(cloud);
    await app.load();
    await app.cloud.enable(_webdav, backupPassword: 'long enough');
    await app.cloud.runIfDue();
    expect(cloud.files, isEmpty, reason: 'nothing to back up yet');

    await app.importCwmoney(_sample, 'a.csv');
    await app.cloud.runIfDue();
    expect(cloud.files, hasLength(1));
    _now = _now.add(const Duration(hours: 23));
    await app.cloud.runIfDue();
    expect(cloud.files, hasLength(1), reason: 'daily');

    _now = _now.add(const Duration(hours: 2));
    cloud.failWith = '連線逾時，請檢查網路或伺服器網址';
    await app.cloud.runIfDue();
    expect(app.cloud.config.lastError, '連線逾時，請檢查網路或伺服器網址');
    expect(app.backupOverdue, isFalse);

    cloud.failWith = null;
    _now = _now.add(const Duration(minutes: 30));
    await app.cloud.runIfDue();
    expect(cloud.files, hasLength(1), reason: 'waits an hour after a failure');
    _now = _now.add(const Duration(minutes: 31));
    await app.cloud.runIfDue();
    expect((cloud.files.length, app.cloud.config.lastError), (2, null));

    await app.cloud.setFrequency(CloudFrequency.weekly);
    _now = _now.add(const Duration(days: 2));
    expect(app.cloud.due, isFalse);
  });

  test('a new phone finds the old phone\'s backup and restores it', () async {
    final cloud = _FakeCloud();
    final old = _phone(cloud);
    await old.load();
    await old.importCwmoney(_sample, 'a.csv');
    await old.cloud.enable(_webdav, backupPassword: 'long enough');
    await old.cloud.backupNow();

    final fresh = _phone(cloud);
    await fresh.load();
    await fresh.cloud.enable(_webdav, backupPassword: 'long enough');
    final (file, bytes, info) = (await fresh.cloud.newerInCloud(fresh.ledger.count()))!;
    expect((file.name, info.transactions), ('aura-20260929-213000.aura', 11));
    await fresh.cloud.restore(bytes);
    expect(fresh.ledger.count(), 11);
    expect(await fresh.cloud.newerInCloud(fresh.ledger.count()), isNull);

    // A different password on this phone: the old backup needs the old one.
    await fresh.cloud.enable(_webdav, backupPassword: 'another password');
    await expectLater(fresh.cloud.restore(bytes), throwsA(isA<BackupException>()));
    await fresh.cloud.restore(bytes, password: 'long enough');

    await fresh.cloud.disable();
    expect(fresh.cloud.enabled, isFalse);
    expect(cloud.files, hasLength(1), reason: 'backups in the cloud stay');
  });

  testWidgets('set up WebDAV from the backup screen', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cloud = _FakeCloud();
    final app = _phone(cloud);
    await tester.runAsync(() async {
      await app.load();
      await app.importCwmoney(_sample, 'a.csv');
    });
    await tester.pumpWidget(AuraApp(app: app));
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await tap(find.text('設定'));
    await tap(find.text('備份與還原'));
    expect(find.text('自動加密備份到 Google 雲端硬碟或 WebDAV'), findsOneWidget);
    await tap(find.byKey(const Key('openCloudBackup')));
    expect(tester.widget<ListTile>(find.byKey(const Key('cloudGoogle'))).enabled, isFalse, reason: 'no client id in tests');
    await tap(find.byKey(const Key('cloudWebdav')));

    await tester.enterText(find.byKey(const Key('webdavUrl')), 'http://cloud.example.com/dav');
    await tap(find.byKey(const Key('webdavNext')));
    expect(find.textContaining('請用 https'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('webdavUrl')), 'https://cloud.example.com/dav');
    await tester.enterText(find.byKey(const Key('webdavUser')), 'me');
    await tester.enterText(find.byKey(const Key('webdavPassword')), 'app-password');
    await tap(find.byKey(const Key('webdavNext')));

    await tester.enterText(find.byKey(const Key('cloudPassword')), 'long enough');
    await tester.enterText(find.byKey(const Key('cloudPasswordConfirm')), 'long enougg');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('cloudEnable'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('cloudPasswordConfirm')), 'long enough');
    await tester.pump();
    await tester.tap(find.byKey(const Key('cloudEnable')));
    await until(() => cloud.files.isNotEmpty);

    expect(app.cloud.config.account, 'me@cloud.example.com');
    expect(find.text('上次備份：2026/09/29 21:30'), findsOneWidget);
    expect(find.text('2026/09/29 21:30'), findsOneWidget, reason: 'listed from the cloud');
    await tap(find.byType(BackButton));
    expect(find.text('上次雲端備份：2026/09/29 21:30'), findsOneWidget);
  });
}
