import 'dart:async';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'category_picker.dart';
import 'transactions_screen.dart';

/// Finds records by words (note, place, seller, invoice items) and by
/// date, account, category, type and amount.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.app});

  final AppState app;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _page = 100;

  /// Totals are worked out up to this many matches.
  static const _sumLimit = 3000;

  final _keyword = TextEditingController();
  Timer? _debounce;
  String _words = '';
  TxnKind? _kind;
  DateTimeRange? _range;
  Set<String> _accounts = {};
  String? _categoryId;
  Decimal? _min, _max;
  var _shown = _page;

  AppState get _app => widget.app;

  @override
  void initState() {
    super.initState();
    _keyword.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _words = _keyword.text.trim();
            _shown = _page;
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _keyword.dispose();
    super.dispose();
  }

  bool get _hasCriteria =>
      _words.isNotEmpty ||
      _kind != null ||
      _range != null ||
      _accounts.isNotEmpty ||
      _categoryId != null ||
      _min != null ||
      _max != null;

  TxnFilter get _filter => TxnFilter(
    keyword: _words.isEmpty ? null : _words,
    kinds: _kind == null ? null : {_kind!},
    from: _range?.start,
    to: _range?.end,
    accountIds: _accounts.isEmpty ? null : _accounts,
    categoryIds: _categoryId == null ? null : {_categoryId!},
    minAmount: _min,
    maxAmount: _max,
  );

  void _set(VoidCallback change) => setState(() {
    change();
    _shown = _page;
  });

  Future<void> _pickRange() async {
    final now = _app.clock();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range ?? DateTimeRange(start: DateTime(now.year, now.month), end: dateOnly(now)),
    );
    if (picked != null) _set(() => _range = picked);
  }

  Future<void> _pickAccounts() async {
    final chosen = {..._accounts};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('帳戶'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final a in _app.view.accounts)
                  CheckboxListTile(
                    key: Key('searchAccount-${a.id}'),
                    contentPadding: EdgeInsets.zero,
                    value: chosen.contains(a.id),
                    title: Text(a.name),
                    onChanged: (v) => setDialog(() => v! ? chosen.add(a.id) : chosen.remove(a.id)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(key: const Key('searchAccountsOk'), onPressed: () => Navigator.pop(context, true), child: const Text('確定')),
          ],
        ),
      ),
    );
    if (ok ?? false) _set(() => _accounts = chosen);
  }

  Future<void> _pickCategory() async {
    final kind = _kind == TxnKind.income ? TxnKind.income : TxnKind.expense;
    final id = await pickCategory(
      context,
      ledger: _app.view,
      kind: kind,
      selectedId: _categoryId,
      mainsSelectable: true,
    );
    if (id != null) {
      _set(() {
        _categoryId = id;
        _kind ??= kind;
      });
    }
  }

  Future<void> _pickAmount() async {
    final picked = await showDialog<(Decimal?, Decimal?)>(
      context: context,
      builder: (_) => _AmountDialog(min: _min, max: _max),
    );
    if (picked == null) return;
    final (lo, hi) = picked;
    // Typed the wrong way round: swap rather than find nothing.
    final swap = lo != null && hi != null && lo > hi;
    _set(() {
      _min = swap ? hi : lo;
      _max = swap ? lo : hi;
    });
  }

  String? get _amountLabel => switch ((_min, _max)) {
    (null, null) => null,
    (final a?, null) => '${formatMoney(a)} 以上',
    (null, final b?) => '${formatMoney(b)} 以下',
    (final a?, final b?) => '${formatMoney(a)}–${formatMoney(b)}',
  };

  Widget _chip({
    required Key key,
    required String label,
    String? value,
    required VoidCallback onTap,
    required VoidCallback onClear,
  }) => InputChip(
    key: key,
    label: Text(value ?? label),
    selected: value != null,
    showCheckmark: false,
    onPressed: onTap,
    onDeleted: value == null ? null : onClear,
    deleteButtonTooltipMessage: '清除$label',
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _app,
    builder: (context, _) {
      final theme = Theme.of(context);
      final l = _app.view;
      final filter = _filter;
      final count = _hasCriteria ? l.count(filter) : 0;
      final results = _hasCriteria ? l.transactions(filter, 0, _shown) : const <Txn>[];
      Decimal? spent, earned;
      if (_hasCriteria && count <= _sumLimit) {
        spent = Decimal.zero;
        earned = Decimal.zero;
        for (final t in count <= _shown ? results : l.transactions(filter)) {
          if (t.kind == TxnKind.expense) spent = spent! + t.baseAmount;
          if (t.kind == TxnKind.income) earned = earned! + t.baseAmount;
        }
      }
      final range = _range;
      return Scaffold(
        appBar: AppBar(
          title: TextField(
            key: const Key('searchField'),
            controller: _keyword,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(hintText: '搜尋備註、地點、商家、發票品項', border: InputBorder.none),
          ),
          actions: [
            if (_keyword.text.isNotEmpty)
              IconButton(tooltip: '清除', icon: const Icon(Icons.close), onPressed: _keyword.clear),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: SegmentedButton<TxnKind?>(
                key: const Key('searchKind'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: null, label: Text('全部')),
                  ButtonSegment(value: TxnKind.expense, label: Text('支出')),
                  ButtonSegment(value: TxnKind.income, label: Text('收入')),
                  ButtonSegment(value: TxnKind.transfer, label: Text('轉帳')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => _set(() {
                  _kind = s.single;
                  // A category belongs to one kind.
                  final c = _categoryId == null ? null : l.category(_categoryId!);
                  if (c != null && c.kind != _kind) _categoryId = null;
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _chip(
                    key: const Key('searchDate'),
                    label: '日期',
                    value: range == null ? null : '${formatDate(range.start)}–${formatDate(range.end)}',
                    onTap: _pickRange,
                    onClear: () => _set(() => _range = null),
                  ),
                  _chip(
                    key: const Key('searchAccounts'),
                    label: '帳戶',
                    value: _accounts.isEmpty
                        ? null
                        : _accounts.length == 1
                        ? l.account(_accounts.single)?.name ?? '帳戶'
                        : '${_accounts.length} 個帳戶',
                    onTap: _pickAccounts,
                    onClear: () => _set(() => _accounts = {}),
                  ),
                  if (_kind != TxnKind.transfer)
                    _chip(
                      key: const Key('searchCategory'),
                      label: '分類',
                      value: _categoryId == null ? null : categoryLabel(l, _categoryId),
                      onTap: _pickCategory,
                      onClear: () => _set(() => _categoryId = null),
                    ),
                  _chip(
                    key: const Key('searchAmount'),
                    label: '金額',
                    value: _amountLabel,
                    onTap: _pickAmount,
                    onClear: () => _set(() => _min = _max = null),
                  ),
                ],
              ),
            ),
            if (_hasCriteria)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  [
                    '$count 筆',
                    if (spent != null && spent != Decimal.zero) '支出 ${formatMoney(spent)}',
                    if (earned != null && earned != Decimal.zero) '收入 ${formatMoney(earned)}',
                  ].join('・'),
                  key: const Key('searchSummary'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: !_hasCriteria
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('輸入關鍵字，或選擇日期、帳戶、分類、金額', style: theme.textTheme.bodyMedium),
                      ),
                    )
                  : count == 0
                  ? const Center(child: Text('找不到符合的紀錄'))
                  : ListView.separated(
                      itemCount: results.length + (count > results.length ? 1 : 0),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => i < results.length
                          ? TxnTile(app: _app, txn: results[i])
                          : Padding(
                              padding: const EdgeInsets.all(12),
                              child: Center(
                                child: TextButton(
                                  key: const Key('searchMore'),
                                  onPressed: () => setState(() => _shown += _page),
                                  child: Text('再顯示 ${count - results.length < _page ? count - results.length : _page} 筆'),
                                ),
                              ),
                            ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}

/// Lowest and highest amount; it owns its fields so they outlive the
/// closing animation.
class _AmountDialog extends StatefulWidget {
  const _AmountDialog({this.min, this.max});

  final Decimal? min, max;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _min = TextEditingController(text: widget.min?.toString() ?? '');
  late final _max = TextEditingController(text: widget.max?.toString() ?? '');

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  static Decimal? _parse(TextEditingController c) => Decimal.tryParse(c.text.trim().replaceAll(',', ''));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('金額（新台幣）'),
    content: Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('searchMin'),
            controller: _min,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: '最少'),
          ),
        ),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('–')),
        Expanded(
          child: TextField(
            key: const Key('searchMax'),
            controller: _max,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: '最多'),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        key: const Key('searchAmountOk'),
        onPressed: () => Navigator.pop(context, (_parse(_min), _parse(_max))),
        child: const Text('確定'),
      ),
    ],
  );
}
