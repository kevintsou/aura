import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';

import '../messages.dart';
import 'tool.dart';

/// The ledger tools offered to the AI. All numbers are computed here, on
/// the device; the AI only chooses what to ask and explains the result.
List<AuraTool> ledgerTools(
  LedgerReader ledger, {
  required bool shareInvoiceItems,
  DateTime Function() clock = DateTime.now,
}) {
  final ctx = _Ctx(ledger, shareInvoiceItems);
  return [
    _OverviewTool(ctx, clock),
    _AggregateTool(ctx),
    _SearchTool(ctx),
    if (shareInvoiceItems) _InvoiceItemsTool(ctx),
  ];
}

const _dateProp = {
  'type': 'string',
  'description': 'YYYY-MM-DD, inclusive',
};

const _filterProps = {
  'date_from': _dateProp,
  'date_to': _dateProp,
  'category': {
    'type': 'string',
    'description': 'Main or subcategory name exactly as listed by get_ledger_overview',
  },
  'account': {'type': 'string', 'description': 'Account name'},
  'project': {'type': 'string', 'description': 'Project name'},
  'keyword': {
    'type': 'string',
    'description': 'Substring of note, place, seller or invoice item names',
  },
};

class _OverviewTool extends AuraTool {
  _OverviewTool(this.ctx, this.clock);
  final _Ctx ctx;
  final DateTime Function() clock;

  @override
  final spec = const ToolSpec(
    name: 'get_ledger_overview',
    description:
        'Returns the ledger structure: date range, accounts with their '
        'current balances, the category tree, projects. Call this first to '
        'learn valid names. Balances are in each account\'s own currency; '
        'balance_known=false means the user never set a real balance, so '
        'that balance only reflects recorded activity and may be wrong. '
        'budgets are monthly spending limits in the base currency with '
        'this month\'s spending (category null = all expenses). recurring '
        'lists repeating records (rent, salary, subscriptions) that the app '
        'records automatically; amount is in the base currency.',
    parameters: {'type': 'object', 'properties': <String, Object?>{}},
  );

  @override
  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final l = ctx.ledger;
    final all = l.transactions();
    final balances = computeBalances(l, today: clock());
    Map<String, List<String>> tree(TxnKind kind) {
      final mains = l.categories.where((c) => c.kind == kind && c.parentId == null);
      return {
        for (final m in mains)
          m.name: [for (final c in l.categories) if (c.parentId == m.id) c.name],
      };
    }

    return {
      'today': _fmtDate(clock()),
      'base_currency': baseCurrency,
      'transaction_count': all.length,
      if (all.isNotEmpty) 'first_date': _fmtDate(all.last.date),
      if (all.isNotEmpty) 'last_date': _fmtDate(all.first.date),
      'accounts': [
        for (final a in l.accounts)
          {
            'name': a.name,
            'type': a.type.name,
            'currency': a.currency,
            'balance': _num(balances[a.id]!.current),
            'balance_known': balances[a.id]!.isSet,
          },
      ],
      'expense_categories': tree(TxnKind.expense),
      'income_categories': tree(TxnKind.income),
      'projects': [for (final p in l.projects) p.name],
      if (l.budgets.isNotEmpty)
        'budgets': [
          for (final b in budgetStatuses(l, Period.month(clock().year, clock().month), today: clock()))
            {
              'category': b.category?.name,
              'monthly_amount': _num(b.amount),
              'spent_this_month': _num(b.spent),
              'remaining': _num(b.remaining),
            },
        ],
      if (l.recurrings.isNotEmpty)
        'recurring': [
          for (final r in l.recurrings)
            {
              'kind': r.template.kind.name,
              'category': r.template.categoryId == null ? null : l.category(r.template.categoryId!)?.name,
              'account': l.account(r.template.accountId!)?.name,
              if (r.template.toAccountId != null) 'to_account': l.account(r.template.toAccountId!)?.name,
              'amount': _num(r.template.baseAmount),
              'note': ?r.template.note,
              'repeats': describeRepeat(r),
              'next': r.next == null ? null : _fmtDate(r.next!),
            },
        ],
      'needs_review_count': all.where((t) => t.needsReview).length,
      'invoice_items_available': ctx.shareInvoiceItems,
    };
  }
}

class _AggregateTool extends AuraTool {
  _AggregateTool(this.ctx);
  final _Ctx ctx;

  static const _groupings = [
    'main_category', 'subcategory', 'account', 'project', 'seller', //
    'year', 'month', 'week', 'day',
  ];

  @override
  final spec = const ToolSpec(
    name: 'aggregate_transactions',
    description:
        'Sums income or expenses in the base currency, grouped by one '
        'dimension. Transfers between accounts are excluded. Use for any '
        'total, trend or ranking question.',
    parameters: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': ['expense', 'income'],
          'description': 'Default expense',
        },
        'group_by': {'type': 'string', 'enum': _groupings},
        'top_n': {
          'type': 'integer',
          'description': 'Max groups for non-time groupings (default 20)',
        },
        ..._filterProps,
      },
      'required': ['group_by'],
    },
  );

  @override
  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final kind = switch (args['kind'] ?? 'expense') {
      'expense' => TxnKind.expense,
      'income' => TxnKind.income,
      final k => throw ToolArgumentException('kind must be expense or income, got $k'),
    };
    final groupBy = args['group_by'];
    if (groupBy is! String || !_groupings.contains(groupBy)) {
      throw ToolArgumentException('group_by must be one of ${_groupings.join(', ')}');
    }
    final txns = ctx.ledger.transactions(ctx.filter(args, kinds: {kind}));
    final groups = <String, (Decimal, int)>{};
    var total = Decimal.zero;
    for (final t in txns) {
      final key = ctx.groupKey(t, groupBy);
      final (sum, n) = groups[key] ?? (Decimal.zero, 0);
      groups[key] = (sum + t.baseAmount, n + 1);
      total += t.baseAmount;
    }
    final isTime = const ['year', 'month', 'week', 'day'].contains(groupBy);
    final entries = groups.entries.toList()
      ..sort(
        isTime
            ? (a, b) => a.key.compareTo(b.key)
            : (a, b) => b.value.$1.compareTo(a.value.$1),
      );
    final topN = isTime ? 400 : _int(args['top_n'], 20, max: 100);
    return {
      ...ctx.echoFilter(args),
      'kind': kind.name,
      'group_by': groupBy,
      'currency': baseCurrency,
      'total': _num(total),
      'count': txns.length,
      'group_count': entries.length,
      'groups': [
        for (final e in entries.take(topN))
          {
            'key': e.key,
            'total': _num(e.value.$1),
            'count': e.value.$2,
            if (total != Decimal.zero)
              'share': _num(_div(e.value.$1 * Decimal.fromInt(100), total)),
          },
      ],
    };
  }
}

class _SearchTool extends AuraTool {
  _SearchTool(this.ctx);
  final _Ctx ctx;

  @override
  final spec = const ToolSpec(
    name: 'search_transactions',
    description:
        'Lists individual transactions matching filters, with notes and '
        '(if shared) invoice line items. Use to inspect details or find '
        'specific purchases.',
    parameters: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': ['expense', 'income', 'transfer', 'any'],
          'description': 'Default any',
        },
        'min_amount': {'type': 'number', 'description': 'In base currency'},
        'max_amount': {'type': 'number', 'description': 'In base currency'},
        'sort': {
          'type': 'string',
          'enum': ['date_desc', 'date_asc', 'amount_desc'],
        },
        'limit': {'type': 'integer', 'description': 'Default 30, max 100'},
        ..._filterProps,
      },
    },
  );

  @override
  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final kinds = switch (args['kind'] ?? 'any') {
      'any' => null,
      'expense' => {TxnKind.expense},
      'income' => {TxnKind.income},
      'transfer' => {TxnKind.transfer},
      final k => throw ToolArgumentException('unknown kind $k'),
    };
    final min = _decimalArg(args['min_amount']);
    final max = _decimalArg(args['max_amount']);
    var txns = ctx.ledger
        .transactions(ctx.filter(args, kinds: kinds))
        .where(
          (t) =>
              (min == null || t.baseAmount >= min) &&
              (max == null || t.baseAmount <= max),
        )
        .toList();
    switch (args['sort'] ?? 'date_desc') {
      case 'date_asc':
        txns = txns.reversed.toList();
      case 'amount_desc':
        txns.sort((a, b) => b.baseAmount.compareTo(a.baseAmount));
      case 'date_desc':
        break;
      default:
        throw ToolArgumentException('unknown sort ${args['sort']}');
    }
    final limit = _int(args['limit'], 30, max: 100);
    return {
      ...ctx.echoFilter(args),
      'matched': txns.length,
      'returned': txns.length < limit ? txns.length : limit,
      'transactions': [for (final t in txns.take(limit)) ctx.describe(t)],
    };
  }
}

class _InvoiceItemsTool extends AuraTool {
  _InvoiceItemsTool(this.ctx);
  final _Ctx ctx;

  @override
  final spec = const ToolSpec(
    name: 'search_invoice_items',
    description:
        'Finds e-invoice line items (products) whose name contains a '
        'keyword, e.g. how often and how much the user bought coffee.',
    parameters: {
      'type': 'object',
      'properties': {
        'keyword': {'type': 'string'},
        'date_from': _dateProp,
        'date_to': _dateProp,
        'limit': {'type': 'integer', 'description': 'Items to list, default 50'},
      },
      'required': ['keyword'],
    },
  );

  @override
  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final keyword = (args['keyword'] as String? ?? '').trim().toLowerCase();
    if (keyword.isEmpty) throw ToolArgumentException('keyword is required');
    final txns = ctx.ledger.transactions(
      TxnFilter(
        from: _dateArg(args['date_from']),
        to: _dateArg(args['date_to']),
        kinds: const {TxnKind.expense},
      ),
    );
    final hits = <Map<String, Object?>>[];
    var total = Decimal.zero, qty = Decimal.zero;
    for (final t in txns) {
      for (final item in t.invoice?.items ?? const <InvoiceItem>[]) {
        if (!item.name.toLowerCase().contains(keyword)) continue;
        total += item.amount;
        qty += item.quantity;
        hits.add({
          'date': _fmtDate(t.date),
          'seller': t.invoice!.sellerName,
          'name': item.name,
          'quantity': _num(item.quantity),
          'amount': _num(item.amount),
          'category': ctx.categoryPath(t),
        });
      }
    }
    return {
      'keyword': args['keyword'],
      'matched_items': hits.length,
      'total_amount': _num(total),
      'total_quantity': _num(qty),
      'items': hits.take(_int(args['limit'], 50, max: 200)).toList(),
    };
  }
}

/// Shared lookups and formatting.
class _Ctx {
  _Ctx(this.ledger, this.shareInvoiceItems);
  final LedgerReader ledger;
  final bool shareInvoiceItems;

  TxnFilter filter(Map<String, Object?> args, {Set<TxnKind>? kinds}) {
    Set<String>? ids<T>(String arg, List<T> items, String Function(T) name, String Function(T) id) {
      final value = args[arg];
      if (value == null || (value is String && value.trim().isEmpty)) return null;
      final wanted = '$value'.trim().toLowerCase();
      final found = {
        for (final i in items)
          if (name(i).toLowerCase() == wanted) id(i),
      };
      if (found.isEmpty) {
        throw ToolArgumentException(
          'unknown $arg "$value"; call get_ledger_overview for valid names',
        );
      }
      return found;
    }

    return TxnFilter(
      from: _dateArg(args['date_from']),
      to: _dateArg(args['date_to']),
      kinds: kinds,
      categoryIds: ids(
        'category',
        ledger.categories.where((c) => kinds == null || kinds.contains(c.kind)).toList(),
        (c) => c.name,
        (c) => c.id,
      ),
      accountIds: ids('account', ledger.accounts, (a) => a.name, (a) => a.id),
      projectIds: ids('project', ledger.projects, (p) => p.name, (p) => p.id),
      keyword: args['keyword'] as String?,
      // Without shared items, a keyword must not reveal what was bought.
      searchInvoiceItems: shareInvoiceItems,
    );
  }

  Map<String, Object?> echoFilter(Map<String, Object?> args) => {
    for (final k in _filterProps.keys)
      if (args[k] != null) k: args[k],
  };

  String categoryPath(Txn t) {
    final leaf = t.categoryId == null ? null : ledger.category(t.categoryId!);
    if (leaf == null) return '(未分類)';
    final parent = leaf.parentId == null ? null : ledger.category(leaf.parentId!);
    return parent == null ? leaf.name : '${parent.name}/${leaf.name}';
  }

  String groupKey(Txn t, String groupBy) => switch (groupBy) {
    'main_category' => categoryPath(t).split('/').first,
    'subcategory' => categoryPath(t),
    'account' => _accountName(t.accountId) ?? '(未知帳戶)',
    'project' => t.projectId == null ? '(無專案)' : ledger.project(t.projectId!)!.name,
    'seller' => t.invoice?.sellerName ?? t.place ?? '(無商家資訊)',
    'year' => '${t.date.year}',
    'month' => _fmtDate(t.date).substring(0, 7),
    'week' => _fmtDate(t.date.subtract(Duration(days: t.date.weekday - 1))),
    _ => _fmtDate(t.date),
  };

  String? _accountName(String? id) => id == null ? null : ledger.account(id)?.name;

  Map<String, Object?> describe(Txn t) {
    final account = t.accountId == null ? null : ledger.account(t.accountId!);
    final foreign = account != null && account.currency != baseCurrency;
    final items = t.invoice?.items ?? const <InvoiceItem>[];
    return {
      'date': _fmtDate(t.date),
      'kind': t.kind.name,
      'amount_base': _num(t.baseAmount),
      if (foreign) 'amount': _num(t.amount),
      if (foreign) 'currency': account.currency,
      if (t.kind != TxnKind.transfer) 'category': categoryPath(t),
      'account': ?_accountName(t.accountId),
      'to_account': ?_accountName(t.toAccountId),
      if (t.projectId != null) 'project': ledger.project(t.projectId!)!.name,
      if (t.note != null) 'note': redact(t.note!),
      if (t.place != null) 'place': redact(t.place!),
      if (t.invoice?.sellerName != null) 'seller': t.invoice!.sellerName,
      if (shareInvoiceItems && items.isNotEmpty)
        'invoice_items': [
          for (final i in items)
            {'name': i.name, 'quantity': _num(i.quantity), 'amount': _num(i.amount)},
        ],
      if (t.needsReview) 'needs_review': true,
    };
  }
}

final _longNumber = RegExp(r'\d[\d\- ]{8,}\d');

/// Masks long digit runs (card or account numbers) in free text, keeping
/// the last four digits.
String redact(String text) => text.replaceAllMapped(_longNumber, (m) {
  final digits = m[0]!.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 10) return m[0]!;
  return '****${digits.substring(digits.length - 4)}';
});

DateTime? _dateArg(Object? v) {
  if (v == null || (v is String && v.trim().isEmpty)) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch('$v'.trim());
  if (m == null) throw ToolArgumentException('dates must be YYYY-MM-DD, got "$v"');
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

Decimal? _decimalArg(Object? v) {
  if (v == null) return null;
  final d = Decimal.tryParse('$v');
  if (d == null) throw ToolArgumentException('expected a number, got "$v"');
  return d;
}

int _int(Object? v, int fallback, {required int max}) {
  final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
  return n < 1 ? 1 : (n > max ? max : n);
}

Decimal _div(Decimal a, Decimal b) =>
    (a / b).toDecimal(scaleOnInfinitePrecision: 4);

/// JSON number with at most two decimals.
num _num(Decimal d) {
  final r = d.round(scale: 2);
  return r.isInteger ? r.toBigInt().toInt() : r.toDouble();
}

String _fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
