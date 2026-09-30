// Differential test: the same random operations on the in-memory ledger
// (web, tests) and the SQLite ledger (phones) must give the same results,
// errors included.
import 'dart:math';
import 'dart:typed_data';

import 'package:aura_core/aura_core.dart';
import 'package:aura_store/aura_store.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

String _txn(Txn t) => [
  t.id, t.kind.name, t.date, t.accountId, t.toAccountId, t.amount, t.toAmount, t.baseAmount, t.fxRateDisplay, //
  t.categoryId, t.projectId, t.note, t.place, t.location, t.createdAt, t.feeOfTxnId, t.recurringId, t.needsReview,
  t.legacyRows,
  t.invoice?.number, t.invoice?.sellerTaxId, t.invoice?.sellerName, t.invoice?.sellerAddress, t.invoice?.carrier,
  [for (final i in t.invoice?.items ?? const <InvoiceItem>[]) '${i.name}/${i.quantity}/${i.amount}'],
].join('|');

String _state(LedgerReader l, List<TxnFilter> filters) => [
  for (final a in l.accounts) 'A ${a.id} ${a.name} ${a.type.name} ${a.currency} ${a.archived} ${a.hidden} ${a.anchor?.amount} ${a.anchor?.date}',
  for (final c in l.categories) 'C ${c.id} ${c.kind.name} ${c.name} ${c.parentId}',
  for (final p in l.projects) 'P ${p.id} ${p.name}',
  for (final b in l.budgets) 'B ${b.id} ${b.categoryId} ${b.amount}',
  for (final r in l.recurrings) 'R ${r.id} ${r.unit.name} ${r.every} ${r.until} ${r.times} ${r.next} ${_txn(r.template)}',
  for (final t in l.transactions()) 'T ${_txn(t)} photos=${l.photoIds(t.id)}',
  'count ${l.count()}',
  for (final (i, f) in filters.indexed) ...[
    'F$i count ${l.count(f)}',
    'F$i ${[for (final t in l.transactions(f, i % 3, i.isEven ? null : 5)) t.id]}',
  ],
  'flows ${[for (final f in l.accountFlows()) '${f.accountId}${f.date}${f.delta}']..sort()}',
  'photos ${[for (final p in l.photos()) '${p.id}:${p.txnId}:${p.bytes.length}']..sort()}',
].join('\n');

void main() {
  for (var seed = 0; seed < 30; seed++) {
    test('same results for random operations (seed $seed)', () {
      final rng = Random(seed);
      final mem = InMemoryLedger();
      final sql = SqliteLedger.inMemory();
      addTearDown(sql.close);
      var n = 0;
      String id(String p) => '$p${n++}';
      T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];
      String? maybe(List<String> xs) => xs.isEmpty || rng.nextInt(5) == 0 ? null : pick(xs);
      final names = ['現金', '銀行', '信用卡', '悠遊卡', 'Cash', ''];
      final words = ['早餐', '午餐', '咖啡', '房租', 'AB', 'ab', '便當 加蛋', '100%', "it's", '_'];
      DateTime day() => DateTime(2026, 1 + rng.nextInt(3), 1 + rng.nextInt(28));
      Decimal money() => Decimal.parse('${rng.nextInt(2000) - 200}${rng.nextBool() ? '' : '.${rng.nextInt(100)}'}');

      List<String> ids(LedgerReader l, String kind) => switch (kind) {
        'a' => [for (final a in l.accounts) a.id],
        'c' => [for (final c in l.categories) c.id],
        'p' => [for (final p in l.projects) p.id],
        'b' => [for (final b in l.budgets) b.id],
        'r' => [for (final r in l.recurrings) r.id],
        _ => [for (final t in l.transactions()) t.id],
      };

      Txn randomTxn(String txnId) {
        final kind = pick(TxnKind.values);
        final accounts = ids(mem, 'a');
        final cats = [for (final c in mem.categories) if (c.kind == kind) c.id];
        final txns = ids(mem, 't');
        final amount = money();
        return Txn(
          id: txnId,
          kind: kind,
          date: day(),
          accountId: kind == TxnKind.transfer && rng.nextInt(6) == 0 ? null : (maybe(accounts) ?? 'nope'),
          toAccountId: kind == TxnKind.transfer ? (maybe(accounts) ?? 'nope') : null,
          amount: amount,
          toAmount: kind == TxnKind.transfer && rng.nextBool() ? money() : null,
          baseAmount: rng.nextBool() ? amount : money(),
          fxRateDisplay: rng.nextInt(4) == 0 ? '32.1' : null,
          categoryId: kind == TxnKind.transfer ? null : maybe(cats),
          projectId: maybe(ids(mem, 'p')),
          note: rng.nextBool() ? '${pick(words)} ${pick(words)}' : null,
          place: rng.nextInt(4) == 0 ? pick(words) : null,
          location: rng.nextInt(5) == 0 ? GeoPoint(25 + rng.nextDouble(), 121 + rng.nextDouble()) : null,
          createdAt: rng.nextInt(4) == 0 ? null : day().add(Duration(seconds: rng.nextInt(86400))),
          feeOfTxnId: kind == TxnKind.expense && rng.nextInt(6) == 0 ? maybe(txns) : null,
          needsReview: rng.nextInt(8) == 0,
          legacyRows: rng.nextInt(4) == 0 ? [List.generate(15, (i) => '${pick(words)}$i')] : const [],
          invoice: rng.nextInt(4) == 0
              ? Invoice(
                  number: 'AB${rng.nextInt(99999999).toString().padLeft(8, '0')}',
                  sellerTaxId: rng.nextBool() ? '12345678' : null,
                  sellerName: rng.nextBool() ? pick(words) : null,
                  carrier: rng.nextBool() ? '/ABC1234' : null,
                  items: [
                    for (var i = 0; i < rng.nextInt(3); i++)
                      InvoiceItem(name: pick(words), quantity: Decimal.fromInt(1 + i), amount: money()),
                  ],
                )
              : null,
        );
      }

      TxnFilter randomFilter() => TxnFilter(
        from: rng.nextBool() ? day() : null,
        to: rng.nextBool() ? day() : null,
        kinds: rng.nextBool() ? {pick(TxnKind.values)} : null,
        accountIds: rng.nextInt(3) == 0 ? {...ids(mem, 'a').take(rng.nextInt(3))} : null,
        categoryIds: rng.nextInt(3) == 0 ? {...ids(mem, 'c').where((_) => rng.nextBool())} : null,
        projectIds: rng.nextInt(4) == 0 ? {...ids(mem, 'p').take(1)} : null,
        keyword: rng.nextInt(3) == 0 ? pick(['早', 'ab', 'AB', '加蛋', '%', "'", '_', ' ']) : null,
        searchInvoiceItems: rng.nextBool(),
        excludeAccountIds: rng.nextInt(3) == 0 ? {...ids(mem, 'a').take(1)} : null,
      );

      // Each operation runs on both stores; both must succeed or both
      // fail the same way.
      void both(String what, void Function(LedgerStore l) op) {
        Object? em, es;
        try {
          op(mem);
        } on Object catch (e) {
          em = e;
        }
        try {
          op(sql);
        } on Object catch (e) {
          es = e;
        }
        expect(es?.runtimeType.toString(), em?.runtimeType.toString(), reason: '$what: memory $em, sqlite $es');
      }

      for (var step = 0; step < 400; step++) {
        final op = rng.nextInt(24);
        switch (op) {
          case 0 || 1:
            final a = Account(id: id('a'), name: pick(names) + (rng.nextBool() ? '${rng.nextInt(3)}' : ''), type: pick(AccountType.values), currency: pick(['TWD', 'USD', 'usd']));
            both('addAccount', (l) => l.addAccount(a));
          case 2:
            final a = maybe(ids(mem, 'a')) ?? 'x';
            final name = rng.nextBool() ? pick(names) : null;
            final archived = rng.nextBool() ? rng.nextBool() : null, hidden = rng.nextBool() ? rng.nextBool() : null;
            final currency = rng.nextInt(5) == 0 ? 'JPY' : null;
            both('updateAccount', (l) => l.updateAccount(a, name: name, archived: archived, hidden: hidden, currency: currency));
          case 3:
            final a = maybe(ids(mem, 'a')) ?? 'x';
            both('deleteAccount', (l) => l.deleteAccount(a));
          case 4:
            final a = maybe(ids(mem, 'a')) ?? 'x';
            final anchor = rng.nextBool() ? BalanceAnchor(amount: money(), date: day()) : null;
            both('anchor', (l) => l.setBalanceAnchor(a, anchor));
          case 5 || 6:
            final kind = rng.nextBool() ? TxnKind.expense : TxnKind.income;
            final parent = rng.nextBool() ? maybe([for (final c in mem.categories) if (c.parentId == null) c.id]) : null;
            final c = Category(id: id('c'), kind: rng.nextInt(10) == 0 ? TxnKind.transfer : kind, name: pick(words), parentId: parent);
            both('addCategory', (l) => l.addCategory(c));
          case 7:
            final c = maybe(ids(mem, 'c')) ?? 'x';
            final name = pick(words);
            both('renameCategory', (l) => l.renameCategory(c, name));
          case 8:
            final c = maybe(ids(mem, 'c')) ?? 'x';
            both('deleteCategory', (l) => l.deleteCategory(c));
          case 9:
            final mains = [for (final c in mem.categories) if (c.parentId == null && c.kind == TxnKind.expense) c.id]..shuffle(rng);
            if (mains.isNotEmpty) both('reorder', (l) => l.reorderCategories(mains));
          case 10:
            final p = Project(id: id('p'), name: pick(words));
            both('addProject', (l) => l.addProject(p));
          case 11:
            final b = Budget(
              id: rng.nextBool() ? (maybe(ids(mem, 'b')) ?? id('b')) : id('b'),
              amount: money(),
              categoryId: rng.nextBool() ? null : maybe(ids(mem, 'c')),
            );
            both('setBudget', (l) => l.setBudget(b));
          case 12:
            final b = maybe(ids(mem, 'b')) ?? 'x';
            both('deleteBudget', (l) => l.deleteBudget(b));
          case 13:
            final rid = rng.nextBool() ? (maybe(ids(mem, 'r')) ?? id('r')) : id('r');
            final t = randomTxn(rid);
            final r = Recurring(
              id: rid,
              template: t,
              unit: pick(RepeatUnit.values),
              every: rng.nextInt(3),
              times: rng.nextBool() ? rng.nextInt(4) : null,
              until: rng.nextInt(3) == 0 ? day() : null,
              next: rng.nextBool() ? t.date : null,
            );
            both('setRecurring', (l) => l.setRecurring(r));
          case 14:
            final r = maybe(ids(mem, 'r')) ?? 'x';
            both('deleteRecurring', (l) => l.deleteRecurring(r));
          case 15:
            final today = day();
            both('recordDue', (l) => recordDueRecurring(l, today: today));
          case 16 || 17 || 18:
            final t = randomTxn(rng.nextInt(10) == 0 ? (maybe(ids(mem, 't')) ?? id('t')) : id('t'));
            both('addTxn', (l) => l.addTxn(t));
          case 19:
            final t = randomTxn(maybe(ids(mem, 't')) ?? 'x');
            both('updateTxn', (l) => l.updateTxn(t));
          case 20:
            final t = maybe(ids(mem, 't')) ?? 'x';
            both('deleteTxn', (l) => l.deleteTxn(t));
          case 21:
            final p = Photo(id: id('ph'), txnId: maybe(ids(mem, 't')) ?? 'x', bytes: Uint8List.fromList([rng.nextInt(256)]));
            both('addPhoto', (l) => l.addPhoto(p));
          case 22:
            final photo = maybe([for (final p in mem.photos()) p.id]) ?? 'x';
            both('deletePhoto', (l) => l.deletePhoto(photo));
          default:
            if (rng.nextInt(10) == 0) {
              final copy = InMemoryLedger(
                accounts: mem.accounts,
                categories: mem.categories,
                projects: mem.projects,
                transactions: mem.transactions(),
                budgets: mem.budgets,
                recurrings: mem.recurrings,
                photos: mem.photos().toList(),
              );
              both('replaceAll', (l) => l.replaceAll(copy));
            }
        }
        final filters = [for (var i = 0; i < 8; i++) randomFilter()];
        final a = _state(mem, filters), b = _state(sql, filters);
        if (a != b) {
          final la = a.split('\n'), lb = b.split('\n');
          final i = Iterable.generate(la.length).firstWhere((i) => i >= lb.length || la[i] != lb[i], orElse: () => la.length);
          fail('step $step (op $op): first difference\n memory: ${i < la.length ? la[i] : '-'}\n sqlite: ${i < lb.length ? lb[i] : '-'}');
        }
      }
    });
  }
}
