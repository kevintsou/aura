import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

/// Every field, for exact comparisons.
Object? _snapshot(LedgerReader l) => [
  [
    for (final a in l.accounts)
      [a.id, a.name, a.type, a.currency, a.archived, a.hidden, a.anchor?.amount, a.anchor?.date],
  ],
  [for (final c in l.categories) [c.id, c.kind, c.name, c.parentId]],
  [for (final p in l.projects) [p.id, p.name]],
  [for (final b in l.budgets) [b.id, b.categoryId, b.amount]],
  [for (final p in l.photos()) [p.id, p.txnId, p.mime, p.bytes]],
  [
    for (final r in l.recurrings)
      [r.id, r.unit, r.every, r.until, r.times, r.next, r.template.accountId, r.template.categoryId, r.template.amount,
        r.template.note, r.template.date],
  ],
  [
    for (final t in l.transactions())
      [
        t.id, t.kind, t.date, t.accountId, t.toAccountId, t.amount, t.toAmount, //
        t.baseAmount, t.fxRateDisplay, t.categoryId, t.projectId, t.note,
        t.place, t.createdAt, t.feeOfTxnId, t.recurringId, t.needsReview, t.legacyRows,
        t.invoice?.number, t.invoice?.sellerTaxId, t.invoice?.sellerName,
        t.invoice?.sellerAddress, t.invoice?.carrier,
        [for (final i in t.invoice?.items ?? const <InvoiceItem>[]) [i.name, i.quantity, i.amount]],
      ],
  ],
];

void main() {
  final created = DateTime(2026, 9, 29, 21, 30);
  late InMemoryLedger ledger;

  setUp(() {
    ledger = importCwmoneyCsv(
      File('test/fixtures/sample_cwmoney.csv').readAsBytesSync(),
    ).ledger;
    final savings = ledger.accounts.firstWhere((a) => a.name == '活存-測試');
    ledger
      ..setBalanceAnchor(
        savings.id,
        BalanceAnchor(amount: Decimal.parse('-1234.56'), date: DateTime(2026, 9, 29)),
      )
      ..updateAccount(ledger.accounts.first.id, archived: true)
      ..updateAccount(ledger.accounts.last.id, hidden: true)
      ..addProject(const Project(id: 'p-new', name: '新專案'))
      ..setBudget(Budget(id: 'b-total', amount: Decimal.parse('30000')))
      ..setBudget(
        Budget(
          id: 'b-food',
          amount: Decimal.parse('4500.5'),
          categoryId: ledger.categories.firstWhere((c) => c.name == '生活費').id,
        ),
      );
    final cash = ledger.accounts.firstWhere((a) => a.name == '現金');
    ledger.setRecurring(
      Recurring(
        id: 'rent',
        template: Txn(
          id: 'tpl',
          kind: TxnKind.expense,
          date: DateTime(2026, 9, 20),
          accountId: cash.id,
          amount: Decimal.fromInt(15000),
          baseAmount: Decimal.fromInt(15000),
          note: '房租',
        ),
        unit: RepeatUnit.month,
        times: 12,
        until: DateTime(2027, 12, 31),
        next: DateTime(2026, 9, 20),
      ),
    );
    recordDueRecurring(ledger, today: DateTime(2026, 9, 29));
    ledger.addPhoto(
      Photo(id: 'ph1', txnId: ledger.transactions().first.id, bytes: Uint8List.fromList(List.generate(300, (i) => i % 256))),
    );
  });

  test('round-trips every field without a password', () async {
    final bytes = await encodeBackup(ledger, createdAt: created, meta: {'import.fileName': 'a.csv'});
    final restored = await decodeBackup(bytes);
    expect(_snapshot(restored.ledger), _snapshot(ledger));
    expect(restored.meta, {'import.fileName': 'a.csv'});
    expect(restored.info.encrypted, isFalse);
  });

  test('round-trips with a password; the payload is unreadable without it', () async {
    final bytes = await encodeBackup(ledger, createdAt: created, password: '秘密', iterations: 1000);
    final text = utf8.decode(const GZipDecoder().decodeBytes(bytes));
    expect(text, isNot(contains('茶葉蛋')));
    expect(text, isNot(contains('/TEST123')));

    final restored = await decodeBackup(bytes, password: '秘密');
    expect(_snapshot(restored.ledger), _snapshot(ledger));
  });

  test('the summary is readable without the password', () async {
    final bytes = await encodeBackup(ledger, createdAt: created, password: 'pw', iterations: 1000);
    final info = readBackupInfo(bytes);
    expect(info.encrypted, isTrue);
    expect(info.createdAt, created);
    expect(info.transactions, ledger.count());
    expect(info.accounts, ledger.accounts.length);
    expect((info.firstDate, info.lastDate), (DateTime(2026, 9, 18), DateTime(2026, 9, 28)));
  });

  test('a wrong or missing password is reported', () async {
    final bytes = await encodeBackup(ledger, createdAt: created, password: 'pw', iterations: 1000);
    await expectLater(
      decodeBackup(bytes, password: 'nope'),
      throwsA(isA<BackupException>().having((e) => e.message, 'message', '密碼錯誤')),
    );
    await expectLater(
      decodeBackup(bytes),
      throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('密碼'))),
    );
  });

  test('rejects files that are not Aura backups', () async {
    for (final bad in [
      utf8.encode('hello'),
      const GZipEncoder().encodeBytes(utf8.encode('{"format":"other"}')),
    ]) {
      await expectLater(
        decodeBackup(bad),
        throwsA(isA<BackupException>().having((e) => e.message, 'm', '這不是 Aura 的備份檔')),
      );
    }
  });

  test('asks for an app update for a newer backup version', () async {
    final newer = const GZipEncoder().encodeBytes(
      utf8.encode(jsonEncode({'format': backupFormat, 'version': backupVersion + 1})),
    );
    expect(
      () => readBackupInfo(newer),
      throwsA(isA<BackupException>().having((e) => e.message, 'm', contains('更新'))),
    );
  });

  test('rejects inconsistent data instead of restoring half of it', () async {
    final bytes = await encodeBackup(ledger, createdAt: created);
    final json = jsonDecode(utf8.decode(const GZipDecoder().decodeBytes(bytes))) as Map;
    (json['data'] as Map)['accounts'] = <Object>[];
    final broken = const GZipEncoder().encodeBytes(utf8.encode(jsonEncode(json)));
    await expectLater(
      decodeBackup(broken),
      throwsA(isA<BackupException>().having((e) => e.message, 'm', contains('不一致'))),
    );
  });

  test('restores accounts that newer rules would reject', () async {
    final old = InMemoryLedger(
      accounts: const [Account(id: 'a', name: '', type: AccountType.other, currency: 'TWD')],
    );
    final restored = await decodeBackup(await encodeBackup(old, createdAt: created));
    expect(restored.ledger.accounts.single.name, '');
  });

  test('an empty ledger backs up and restores', () async {
    final restored = await decodeBackup(
      await encodeBackup(InMemoryLedger(), createdAt: created),
    );
    expect(restored.ledger.count(), 0);
    expect(restored.info.firstDate, isNull);
  });
}
