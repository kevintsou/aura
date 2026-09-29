import 'dart:io';
import 'dart:typed_data';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/backup_files.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

class _Files implements BackupFiles {
  String? name;
  Uint8List? bytes;

  @override
  Future<bool> save(String fileName, Uint8List bytes, {String title = ''}) async {
    name = fileName;
    this.bytes = bytes;
    return true;
  }

  @override
  Future<({String name, Uint8List bytes})?> pick({String title = ''}) async => null;
}

void main() {
  testWidgets('exports a CWMoney CSV from settings', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = _Files();
    final app = AppState(
      ledger: InMemoryLedger(),
      settings: MemoryAiSettingsStore(),
      files: files,
      clock: () => DateTime(2026, 9, 29, 21),
    );
    await tester.runAsync(() async {
      await app.load();
      await app.importCwmoney(_sample, 'a.csv');
    });
    await tester.pumpWidget(AuraApp(app: app));
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();

    Future<void> export({bool carrier = false}) async {
      files.bytes = null;
      await tester.tap(find.byKey(const Key('exportCwmoney')));
      await tester.pumpAndSettle();
      if (carrier) {
        await tester.tap(find.byKey(const Key('exportCarrier')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('confirmExport')));
      for (var i = 0; i < 200 && files.bytes == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await export();
    expect(files.name, 'cwmoney_ex2_db_CSV_20260929.csv');
    expect(find.textContaining('11 筆紀錄，14 列'), findsOneWidget);
    expect(find.textContaining('載具號碼已經隱藏'), findsOneWidget);
    final text = decodeBig5Hkscs(files.bytes!);
    expect(text, contains('[手機條碼,******]'));
    expect(text, isNot(contains('/TEST123')));
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();

    await export(carrier: true);
    expect(decodeBig5Hkscs(files.bytes!).split('\r\n').toSet(), decodeBig5Hkscs(_sample).split('\r\n').toSet());
  });
}
