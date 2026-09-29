import 'dart:io';
import 'dart:typed_data';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/backup_files.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _sample = File('../packages/aura_core/test/fixtures/sample_cwmoney.csv').readAsBytesSync();

/// The sample export limited to records [ids] (1: 9/28 … 14: 9/18).
Uint8List _part(Iterable<int> ids) {
  final records = <List<int>>[[]];
  for (var i = 0; i < _sample.length; i++) {
    if (_sample[i] == 0x0D && i + 1 < _sample.length && _sample[i + 1] == 0x0A) {
      records.add([]);
      i++;
    } else {
      records.last.add(_sample[i]);
    }
  }
  return Uint8List.fromList([
    for (final i in [0, ...ids]) ...[...records[i], 0x0D, 0x0A],
  ]);
}

class _Files implements BackupFiles {
  ({String name, Uint8List bytes})? toPick;

  @override
  Future<bool> save(String fileName, Uint8List bytes, {String title = ''}) async => true;

  @override
  Future<({String name, Uint8List bytes})?> pick({String title = ''}) async => toPick;
}

Future<(AppState, _Files)> _open(WidgetTester tester, {void Function(AppState)? setUp}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final files = _Files();
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: MemoryAiSettingsStore(),
    files: files,
    clock: () => DateTime(2026, 9, 29),
  );
  await tester.runAsync(app.load);
  setUp?.call(app);
  await tester.pumpWidget(AuraApp(app: app));
  await tester.tap(find.text('設定'));
  await tester.pumpAndSettle();
  return (app, files);
}

/// Picks [bytes] from settings and waits for the next dialog [title].
Future<void> _import(WidgetTester tester, _Files files, Uint8List bytes, String title) async {
  files.toPick = (name: 'cwmoney.csv', bytes: bytes);
  await tester.tap(find.text('匯入 CWMoney CSV'));
  await _waitFor(tester, find.text(title));
}

Future<void> _waitFor(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 200 && f.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
  }
  expect(f, findsWidgets);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String _summary(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: find.byKey(const Key('mergeSummary')), matching: find.byType(Text)),
  ))
    t.data ?? '',
].join('\n');

Txn _manual(AppState app, DateTime date, int amount, String note) => Txn(
  id: newId('t'),
  kind: TxnKind.expense,
  date: date,
  accountId: app.ledger.accounts.single.id,
  categoryId: app.ledger.categories.firstWhere((c) => c.name == '午餐').id,
  amount: Decimal.fromInt(amount),
  baseAmount: Decimal.fromInt(amount),
  note: note,
);

void main() {
  testWidgets('a blank ledger imports straight away; later files merge', (tester) async {
    final (app, files) = await _open(tester);
    await _import(tester, files, _part([7, 8, 9, 10, 11, 12, 13, 14]), '匯入完成');
    await _tap(tester, find.text('好'));
    expect(app.ledger.count(), 6);

    await _import(tester, files, _sample, '合併到目前的帳本？');
    final summary = _summary(tester);
    expect(summary, contains('新紀錄 5 筆（2026/09/24–2026/09/28）'));
    expect(summary, contains('已經在帳本裡的 6 筆會略過'));
    expect(summary, contains('新增帳戶：信用卡-測試'));
    expect(find.byKey(const Key('skipDuplicates')), findsNothing);
    expect(find.byKey(const Key('mergeGap')), findsNothing);

    await tester.tap(find.byKey(const Key('mergeImport')));
    await _waitFor(tester, find.text('合併完成'));
    expect(find.textContaining('已加入 5 筆新紀錄'), findsOneWidget);
    expect(find.textContaining('新帳戶 信用卡-測試 還沒有餘額'), findsOneWidget);
    await _tap(tester, find.text('好'));
    expect(app.ledger.count(), 11);
    expect(app.ledger.accounts.map((a) => a.name).toSet(), hasLength(app.ledger.accounts.length));

    // The same file again has nothing new.
    await _import(tester, files, _sample, '沒有新紀錄');
    expect(_summary(tester), contains('檔案裡的 11 筆紀錄都已經在帳本裡，沒有新紀錄。'));
    expect(find.byKey(const Key('mergeImport')), findsNothing);
    await _tap(tester, find.text('取消'));
    expect(app.ledger.count(), 11);
  });

  testWidgets('can replace everything instead of merging', (tester) async {
    final (app, files) = await _open(
      tester,
      setUp: (app) {
        app.startFresh();
        app.saveTxn(_manual(app, DateTime(2026, 9, 10), 80, '手動'), isNew: true);
      },
    );
    await _import(tester, files, _sample, '合併到目前的帳本？');
    await _tap(tester, find.byKey(const Key('replaceImport')));
    expect(find.textContaining('目前的帳戶、分類和 1 筆紀錄'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmReplace')));
    await _waitFor(tester, find.text('匯入完成'));
    expect(app.ledger.count(), 11);
    expect(app.ledger.transactions().where((t) => t.note == '手動'), isEmpty);
  });

  testWidgets('offers to skip records already entered by hand', (tester) async {
    for (final skip in [true, false]) {
      await tester.pumpWidget(const SizedBox()); // a fresh app each round
      final (app, files) = await _open(
        tester,
        setUp: (app) {
          app.startFresh();
          app.saveTxn(_manual(app, DateTime(2026, 9, 18), 120, '午餐'), isNew: true);
        },
      );
      await _import(tester, files, _sample, '合併到目前的帳本？');
      expect(find.text('略過 1 筆可能重複的紀錄'), findsOneWidget);
      expect(find.textContaining('2026/09/18 NT\$120 便當'), findsOneWidget);
      if (!skip) await _tap(tester, find.byKey(const Key('skipDuplicates')));
      await tester.tap(find.byKey(const Key('mergeImport')));
      await _waitFor(tester, find.text('合併完成'));
      expect(app.ledger.count(), skip ? 11 : 12);
      expect(app.ledger.categories.where((c) => c.name == '午餐'), hasLength(1));
      await _tap(tester, find.text('好'));
    }
  });

  testWidgets('warns about a gap between the ledger and the new records', (tester) async {
    final (_, files) = await _open(
      tester,
      setUp: (app) {
        app.startFresh();
        app.saveTxn(_manual(app, DateTime(2026, 6, 18), 100, '六月'), isNew: true);
      },
    );
    await _import(tester, files, _sample, '合併到目前的帳本？');
    final gap = tester.widget<Text>(find.byKey(const Key('mergeGap'))).data!;
    expect(gap, contains('帳本目前的紀錄到 2026/06/18，新紀錄從 2026/09/18 開始'));
  });
}
