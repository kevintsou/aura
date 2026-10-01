// Behaviour every LedgerStore must have. Run by aura_core (in memory) and
// aura_store (SQLite) so both stores stay interchangeable.
import 'dart:typed_data';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

void ledgerStoreContract(LedgerStore Function() create) {
  late LedgerStore l;
  late Account cash, bank;
  late Category food, lunch, salaryMain, salary;

  Txn expense(
    String id, {
    String amount = '120',
    DateTime? date,
    String? categoryId,
    String? accountId,
  }) => Txn(
    id: id,
    kind: TxnKind.expense,
    date: date ?? DateTime(2026, 9, 1),
    accountId: accountId ?? cash.id,
    amount: Decimal.parse(amount),
    baseAmount: Decimal.parse(amount),
    categoryId: categoryId ?? lunch.id,
    createdAt: DateTime(2026, 9, 1, 12),
  );

  setUp(() {
    l = create();
    cash = defaultCashAccount();
    bank = Account(
      id: newId('a'),
      name: '銀行',
      type: AccountType.bank,
      currency: baseCurrency,
    );
    food = Category(id: 'food', kind: TxnKind.expense, name: '生活費');
    lunch = Category(id: 'lunch', kind: TxnKind.expense, name: '午餐', parentId: 'food');
    salaryMain = Category(id: 'work', kind: TxnKind.income, name: '工作收入');
    salary = Category(id: 'salary', kind: TxnKind.income, name: '薪資', parentId: 'work');
    l
      ..addAccount(cash)
      ..addAccount(bank);
    for (final c in [food, lunch, salaryMain, salary]) {
      l.addCategory(c);
    }
  });
  tearDown(() => l.close());

  group('accounts', () {
    test('add, rename, archive', () {
      expect(l.accounts.map((a) => a.name), ['現金', '銀行']);
      l.updateAccount(bank.id, name: '郵局', archived: true);
      final a = l.account(bank.id)!;
      expect((a.name, a.archived, a.type), ('郵局', true, AccountType.bank));
      l.updateAccount(bank.id, archived: false);
      expect(l.account(bank.id)!.archived, isFalse);
    });

    test('names are unique and required', () {
      expect(
        () => l.addAccount(
          const Account(id: 'x', name: '銀行', type: AccountType.cash, currency: 'TWD'),
        ),
        throwsArgumentError,
      );
      expect(() => l.updateAccount(cash.id, name: '銀行'), throwsArgumentError);
      expect(() => l.updateAccount(cash.id, name: ' '), throwsArgumentError);
      l.updateAccount(cash.id, name: '現金'); // its own name is fine
    });

    test('only unused accounts can be deleted', () {
      l.addTxn(expense('t1'));
      expect(() => l.deleteAccount(cash.id), throwsStateError);
      l.deleteAccount(bank.id);
      expect(l.account(bank.id), isNull);
    });
  });

  test('hidden accounts and their records can be left out', () {
    l
      ..addTxn(expense('t1'))
      ..addTxn(expense('t2', accountId: bank.id))
      ..addTxn(
        Txn(
          id: 't3',
          kind: TxnKind.transfer,
          date: DateTime(2026, 9, 2),
          accountId: cash.id,
          toAccountId: bank.id,
          amount: Decimal.one,
          baseAmount: Decimal.one,
        ),
      )
      ..updateAccount(bank.id, hidden: true);
    expect(l.account(bank.id)!.hidden, isTrue);
    expect(l.account(cash.id)!.hidden, isFalse);
    final visible = const TxnFilter().excluding({bank.id});
    expect([for (final t in l.transactions(visible)) t.id], ['t1']);
    expect(l.count(visible), 1);
    expect(l.count(TxnFilter(accountIds: {cash.id, bank.id}).excluding({bank.id})), 1);
    expect(l.count(), 3);
    l.updateAccount(bank.id, hidden: false);
    expect(l.account(bank.id)!.hidden, isFalse);
  });

  group('categories', () {
    test('new ones go after their siblings', () {
      l.addCategory(Category(id: 'dinner', kind: TxnKind.expense, name: '晚餐', parentId: 'food'));
      expect(
        l.categories.where((c) => c.parentId == 'food').map((c) => c.name),
        ['午餐', '晚餐'],
      );
    });

    test('rename checks siblings for duplicates', () {
      l.addCategory(Category(id: 'dinner', kind: TxnKind.expense, name: '晚餐', parentId: 'food'));
      expect(() => l.renameCategory('dinner', '午餐'), throwsArgumentError);
      l.renameCategory('dinner', '宵夜');
      expect(l.category('dinner')!.name, '宵夜');
      // The same name under another parent or kind is fine.
      l.addCategory(Category(id: 'x', kind: TxnKind.income, name: '午餐', parentId: 'work'));
    });

    test('subcategories must sit under a main category of the same kind', () {
      expect(
        () => l.addCategory(Category(id: 'x', kind: TxnKind.income, name: 'x', parentId: 'food')),
        throwsArgumentError,
      );
      expect(
        () => l.addCategory(Category(id: 'x', kind: TxnKind.expense, name: 'x', parentId: 'lunch')),
        throwsArgumentError,
      );
    });

    test('deleting a main category removes its unused subcategories', () {
      l.deleteCategory('food');
      expect(l.category('food'), isNull);
      expect(l.category('lunch'), isNull);
    });

    test('used categories cannot be deleted, directly or via the parent', () {
      l.addTxn(expense('t1'));
      expect(() => l.deleteCategory('lunch'), throwsStateError);
      expect(() => l.deleteCategory('food'), throwsStateError);
    });

    test('reorder moves siblings within their slots', () {
      l
        ..addCategory(Category(id: 'dinner', kind: TxnKind.expense, name: '晚餐', parentId: 'food'))
        ..addCategory(Category(id: 'car', kind: TxnKind.expense, name: '交通'))
        ..reorderCategories(['car', 'food']);
      final mains = l.categories.where((c) => c.parentId == null && c.kind == TxnKind.expense);
      expect(mains.map((c) => c.id), ['car', 'food']);
      l.reorderCategories(['dinner', 'lunch']);
      expect(
        l.categories.where((c) => c.parentId == 'food').map((c) => c.id),
        ['dinner', 'lunch'],
      );
    });
  });

  group('transactions', () {
    test('add, update and delete, keeping newest-first order', () {
      l
        ..addTxn(expense('old', date: DateTime(2026, 8, 1)))
        ..addTxn(expense('new', date: DateTime(2026, 9, 2)));
      expect(l.transactions().map((t) => t.id), ['new', 'old']);

      l.updateTxn(expense('old', amount: '99', date: DateTime(2026, 9, 3)));
      expect(l.transactions().map((t) => t.id), ['old', 'new']);
      expect(l.transactions().first.amount, Decimal.fromInt(99));

      l.deleteTxn('new');
      expect(l.transactions().map((t) => t.id), ['old']);
      expect(() => l.deleteTxn('new'), throwsArgumentError);
      expect(() => l.updateTxn(expense('ghost')), throwsArgumentError);
    });

    test('ids must be new', () {
      l.addTxn(expense('t1'));
      expect(() => l.addTxn(expense('t1')), throwsArgumentError);
    });

    test('balances follow manual records', () {
      l
        ..addTxn(expense('t1', amount: '120'))
        ..addTxn(
          Txn(
            id: 't2',
            kind: TxnKind.income,
            date: DateTime(2026, 9, 1),
            accountId: bank.id,
            amount: Decimal.fromInt(50000),
            baseAmount: Decimal.fromInt(50000),
            categoryId: salary.id,
          ),
        )
        ..addTxn(
          Txn(
            id: 't3',
            kind: TxnKind.transfer,
            date: DateTime(2026, 9, 2),
            accountId: bank.id,
            toAccountId: cash.id,
            amount: Decimal.fromInt(3000),
            baseAmount: Decimal.fromInt(3000),
          ),
        );
      final b = computeBalances(l, today: DateTime(2026, 9, 30));
      expect(b[cash.id]!.current, Decimal.fromInt(2880));
      expect(b[bank.id]!.current, Decimal.fromInt(47000));
    });

    test('rejects records that break the rules', () {
      expect(() => l.addTxn(expense('t', categoryId: salary.id)), throwsArgumentError);
      expect(() => l.addTxn(expense('t', accountId: 'ghost')), throwsArgumentError);
      expect(
        () => l.addTxn(
          Txn(
            id: 't',
            kind: TxnKind.transfer,
            date: DateTime(2026),
            accountId: cash.id,
            toAccountId: cash.id,
            amount: Decimal.one,
            baseAmount: Decimal.one,
          ),
        ),
        throwsArgumentError,
      );
      expect(l.count(), 0);
    });

    test('deleting a transfer unlinks its fee', () {
      l.addTxn(
        Txn(
          id: 'tr',
          kind: TxnKind.transfer,
          date: DateTime(2026, 9, 2),
          accountId: bank.id,
          toAccountId: cash.id,
          amount: Decimal.fromInt(3000),
          baseAmount: Decimal.fromInt(3000),
        ),
      );
      l.addCategory(Category(id: 'fee', kind: TxnKind.expense, name: '手續費', parentId: 'food'));
      l.addTxn(
        Txn(
          id: 'fee1',
          kind: TxnKind.expense,
          date: DateTime(2026, 9, 2),
          accountId: bank.id,
          amount: Decimal.fromInt(15),
          baseAmount: Decimal.fromInt(15),
          categoryId: 'fee',
          feeOfTxnId: 'tr',
        ),
      );
      l.deleteTxn('tr');
      expect(l.transactions().single.feeOfTxnId, isNull);
    });
  });

  group('budgets', () {
    Budget budget(String id, String amount, [String? categoryId]) =>
        Budget(id: id, amount: Decimal.parse(amount), categoryId: categoryId);
    List<(String, String?, String)> listed() => [
      for (final b in l.budgets) (b.id, b.categoryId, '${b.amount}'),
    ];

    test('set, change and delete, with the total listed first', () {
      l
        ..setBudget(budget('b1', '3000', 'food'))
        ..setBudget(budget('b2', '20000'))
        ..setBudget(budget('b3', '1500.5', 'lunch'));
      expect(listed(), [('b2', null, '20000'), ('b1', 'food', '3000'), ('b3', 'lunch', '1500.5')]);
      l
        ..setBudget(budget('b1', '3500', 'food'))
        ..deleteBudget('b3');
      expect(listed(), [('b2', null, '20000'), ('b1', 'food', '3500')]);
      expect(() => l.deleteBudget('b3'), throwsArgumentError);
    });

    test('one per category, positive, expense categories only', () {
      l
        ..setBudget(budget('b1', '100'))
        ..setBudget(budget('b2', '100', 'food'));
      expect(() => l.setBudget(budget('b3', '100')), throwsArgumentError);
      expect(() => l.setBudget(budget('b3', '100', 'food')), throwsArgumentError);
      expect(() => l.setBudget(budget('b3', '0', 'lunch')), throwsArgumentError);
      expect(() => l.setBudget(budget('b3', '100', 'work')), throwsArgumentError);
      expect(() => l.setBudget(budget('b3', '100', 'nope')), throwsArgumentError);
      expect(l.budgets, hasLength(2));
    });

    test('go away with their category', () {
      l
        ..setBudget(budget('b1', '100', 'lunch'))
        ..setBudget(budget('b2', '100'))
        ..deleteCategory('food');
      expect(listed(), [('b2', null, '100')]);
    });

    test('are replaced by replaceAll', () {
      l.setBudget(budget('b1', '100', 'food'));
      l.replaceAll(
        InMemoryLedger(
          categories: [food],
          budgets: [budget('b9', '42.5', 'food'), budget('b8', '900')],
        ),
      );
      expect(listed(), [('b8', null, '900'), ('b9', 'food', '42.5')]);
      l.replaceAll(InMemoryLedger());
      expect(l.budgets, isEmpty);
    });
  });

  group('recurring', () {
    Recurring monthly(String id, {String? account, String? categoryId, int every = 1, DateTime? until}) => Recurring(
      id: id,
      template: expense('tpl', date: DateTime(2026, 9, 5), accountId: account, categoryId: categoryId),
      unit: RepeatUnit.month,
      every: every,
      until: until,
      next: DateTime(2026, 9, 5),
    );

    test('repeats only what fits every occurrence', () {
      final source = expense('src', date: DateTime(2026, 8, 5));
      l.setRecurring(
        Recurring(
          id: 'r1',
          template: Txn(
            id: 'r1',
            kind: TxnKind.expense,
            date: DateTime(2026, 9, 5),
            accountId: source.accountId,
            categoryId: source.categoryId,
            amount: source.amount,
            baseAmount: source.baseAmount,
            note: '房租',
            place: '房東家',
            location: const GeoPoint(25, 121),
            createdAt: DateTime(2026, 8, 5, 9),
            invoice: const Invoice(number: 'AB12345678'),
            needsReview: true,
            legacyRows: const [
              ['2026/08/05'],
            ],
          ),
          unit: RepeatUnit.month,
          next: DateTime(2026, 9, 5),
        ),
      );
      final t = l.recurrings.single.template;
      expect((t.note, t.amount, t.accountId), ('房租', source.amount, source.accountId));
      expect([t.place, t.location, t.invoice, t.createdAt], everyElement(isNull));
      expect(t.needsReview, isFalse);
      expect(t.legacyRows, isEmpty);
      recordDueRecurring(l, today: DateTime(2026, 9, 5));
      final made = l.txn('r1@2026-09-05')!;
      expect((made.invoice, made.note), (null, '房租'));
      expect(made.legacyRows, isEmpty);
    });

    test('set, change, record and delete', () {
      l
        ..setRecurring(monthly('r1'))
        ..setRecurring(monthly('r2', account: bank.id));
      expect([for (final r in l.recurrings) (r.id, r.template.accountId)], [('r1', cash.id), ('r2', bank.id)]);
      l.setRecurring(monthly('r1', every: 2));
      final r1 = l.recurrings.first;
      expect((r1.every, r1.unit, r1.next, r1.template.note, r1.template.amount), (2, RepeatUnit.month, DateTime(2026, 9, 5), null, Decimal.parse('120')));

      recordDueRecurring(l, today: DateTime(2026, 9, 30));
      expect(l.txn('r1@2026-09-05')!.recurringId, 'r1');
      expect(l.txn('nope'), isNull);
      expect(l.recurrings.first.next, DateTime(2026, 11, 5));

      l.deleteRecurring('r1');
      expect([for (final r in l.recurrings) r.id], ['r2']);
      expect(l.txn('r1@2026-09-05')!.recurringId, isNull, reason: 'records stay, unlinked');
      expect(l.txn('r2@2026-09-05')!.recurringId, 'r2');
      expect(() => l.deleteRecurring('r1'), throwsArgumentError);
    });

    test('rejects broken rules', () {
      expect(() => l.setRecurring(monthly('r', every: 0)), throwsArgumentError);
      expect(() => l.setRecurring(monthly('r', until: DateTime(2026, 9, 4))), throwsArgumentError);
      expect(() => l.setRecurring(monthly('r', account: 'nope')), throwsArgumentError);
      expect(
        () => l.setRecurring(
          Recurring(
            id: 'r',
            template: Txn(
              id: 't',
              kind: TxnKind.transfer,
              date: DateTime(2026, 9, 5),
              accountId: cash.id,
              amount: Decimal.one,
              baseAmount: Decimal.one,
            ),
            unit: RepeatUnit.month,
          ),
        ),
        throwsArgumentError,
        reason: 'a repeating transfer needs both accounts',
      );
      expect(l.recurrings, isEmpty);
    });

    test('keep the accounts and categories they use', () {
      l.setRecurring(monthly('r1', account: bank.id));
      expect(() => l.deleteAccount(bank.id), throwsStateError);
      expect(() => l.deleteCategory('food'), throwsStateError, reason: 'via its subcategory');
      l.deleteRecurring('r1');
      l
        ..deleteAccount(bank.id)
        ..deleteCategory('food');
    });

    test('are replaced by replaceAll', () {
      l.setRecurring(monthly('r1'));
      l.replaceAll(InMemoryLedger(accounts: [cash], categories: [food, lunch], recurrings: [monthly('r9')]));
      expect([for (final r in l.recurrings) r.id], ['r9']);
      l.replaceAll(InMemoryLedger());
      expect(l.recurrings, isEmpty);
    });
  });

  test('photos belong to a record and go with it', () {
    l
      ..addTxn(expense('t1'))
      ..addTxn(expense('t2'));
    Photo photo(String id, String txn, List<int> bytes) =>
        Photo(id: id, txnId: txn, bytes: Uint8List.fromList(bytes));
    l
      ..addPhoto(photo('p1', 't1', [1, 2, 3]))
      ..addPhoto(photo('p2', 't1', [4]))
      ..addPhoto(photo('p3', 't2', [5]));
    expect(l.photoIds('t1'), ['p1', 'p2']);
    expect(l.photo('p1')!.bytes, [1, 2, 3]);
    expect(l.photo('p1')!.mime, 'image/jpeg');
    expect(() => l.addPhoto(photo('p1', 't2', [0])), throwsArgumentError);
    expect(() => l.addPhoto(photo('p9', 'nope', [0])), throwsArgumentError);

    l.deletePhoto('p2');
    expect(l.photoIds('t1'), ['p1']);
    l.deleteTxn('t1');
    expect(l.photo('p1'), isNull);
    expect([for (final p in l.photos()) p.id], ['p3']);

    l.replaceAll(
      InMemoryLedger(
        accounts: [cash],
        categories: [food, lunch],
        transactions: [expense('t9')],
        photos: [photo('p9', 't9', [9]), photo('px', 'gone', [0])],
      ),
    );
    expect([for (final p in l.photos()) p.id], ['p9'], reason: 'orphans are dropped');
  });

  test('a record keeps where it was made', () {
    Txn at(String id, GeoPoint? p) => Txn(
      id: id,
      kind: TxnKind.expense,
      date: DateTime(2026, 9, 1),
      accountId: cash.id,
      amount: Decimal.one,
      baseAmount: Decimal.one,
      categoryId: lunch.id,
      location: p,
    );
    l
      ..addTxn(at('t1', const GeoPoint(25.033964, 121.564468)))
      ..addTxn(at('t2', null));
    expect(l.txn('t1')!.location, const GeoPoint(25.033964, 121.564468));
    expect(l.txn('t2')!.location, isNull);
    l.updateTxn(at('t1', null));
    expect(l.txn('t1')!.location, isNull);
    l.updateTxn(at('t2', const GeoPoint(-33.8688, 151.2093)));
    expect(l.transactions().firstWhere((t) => t.id == 't2').location, const GeoPoint(-33.8688, 151.2093));
  });

  test('amount bounds include their ends', () {
    for (final (id, amount) in [('a', '99.99'), ('b', '100'), ('c', '250.5'), ('d', '-30'), ('e', '1000')]) {
      l.addTxn(expense(id, amount: amount));
    }
    List<String> ids(TxnFilter f) => [for (final t in l.transactions(f)) t.id]..sort();
    expect(ids(TxnFilter(minAmount: Decimal.fromInt(100))), ['b', 'c', 'e']);
    expect(ids(TxnFilter(maxAmount: Decimal.parse('250.5'))), ['a', 'b', 'c', 'd']);
    expect(ids(TxnFilter(minAmount: Decimal.fromInt(100), maxAmount: Decimal.fromInt(300))), ['b', 'c']);
    expect(l.count(TxnFilter(maxAmount: Decimal.zero)), 1, reason: 'refunds are negative');
  });

  test('meta values are listed', () {
    l
      ..setMeta('a', '1')
      ..setMeta('b', '2')
      ..setMeta('a', null);
    expect(l.allMeta(), {'b': '2'});
  });

  test('projects can be added once per name', () {
    l.addProject(const Project(id: 'p1', name: '旅遊'));
    expect(() => l.addProject(const Project(id: 'p2', name: '旅遊')), throwsArgumentError);
    l.addTxn(
      Txn(
        id: 't',
        kind: TxnKind.expense,
        date: DateTime(2026),
        accountId: cash.id,
        amount: Decimal.one,
        baseAmount: Decimal.one,
        categoryId: lunch.id,
        projectId: 'p1',
      ),
    );
    expect(l.transactions().single.projectId, 'p1');
  });

  test('default categories are valid and ordered parents first', () {
    final defaults = defaultCategories();
    final fresh = create();
    addTearDown(fresh.close);
    // Throws if a child came before its parent or a name repeated.
    defaults.forEach(fresh.addCategory);
    expect(fresh.categories.where((c) => c.name == '早餐'), hasLength(1));
    expect(fresh.categories.map((c) => c.id), defaults.map((c) => c.id));
    expect(
      defaults.where((c) => c.kind == TxnKind.income && c.parentId == null).map((c) => c.name),
      ['工作收入', '現金流', '其他收入'],
    );
  });
}
