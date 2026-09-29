import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'category_picker.dart';
import 'dialogs.dart';

/// Records a new expense, income or transfer, or edits an existing one.
class TxnEditScreen extends StatefulWidget {
  const TxnEditScreen({super.key, required this.app, this.txn});

  final AppState app;

  /// Null for a new record.
  final Txn? txn;

  @override
  State<TxnEditScreen> createState() => _TxnEditScreenState();
}

class _TxnEditScreenState extends State<TxnEditScreen> {
  final _amount = TextEditingController();
  final _toAmount = TextEditingController();
  final _rate = TextEditingController();
  final _note = TextEditingController();
  late TxnKind _kind;
  String? _categoryId;
  String? _accountId;
  String? _toAccountId;
  String? _projectId;
  late DateTime _date;
  String? _error;

  AppState get _app => widget.app;
  LedgerStore get _ledger => _app.ledger;
  Txn? get _old => widget.txn;
  bool get _isNew => _old == null;

  @override
  void initState() {
    super.initState();
    final t = _old;
    if (t == null) {
      _kind = TxnKind.expense;
      final active = _app.activeAccounts;
      _accountId = active.any((a) => a.id == _app.lastAccountId)
          ? _app.lastAccountId
          : active.firstOrNull?.id;
      _categoryId = defaultCategoryId(_ledger, _kind, _app.lastCategoryId(_kind));
      _date = dateOnly(_app.clock());
    } else {
      _kind = t.kind;
      _categoryId = t.categoryId;
      _accountId = t.accountId;
      _toAccountId = t.toAccountId;
      _projectId = t.projectId;
      _date = t.date;
      _amount.text = t.amount.toString();
      _toAmount.text = t.toAmount?.toString() ?? '';
      _rate.text = t.fxRateDisplay ?? '';
      _note.text = t.note ?? '';
    }
    if (_rate.text.isEmpty) _rate.text = _lastRate(_accountId) ?? '';
    for (final c in [_amount, _toAmount, _rate, _note]) {
      c.addListener(() => setState(() => _error = null));
    }
  }

  @override
  void dispose() {
    for (final c in [_amount, _toAmount, _rate, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Most recent exchange rate recorded for [accountId].
  String? _lastRate(String? accountId) {
    if (accountId == null || _currencyOf(accountId) == baseCurrency) return null;
    return _ledger
        .transactions(TxnFilter(accountIds: {accountId}), 0, 50)
        .map((t) => t.fxRateDisplay)
        .whereType<String>()
        .firstOrNull;
  }

  String _currencyOf(String? accountId) =>
      accountId == null ? baseCurrency : _ledger.account(accountId)?.currency ?? baseCurrency;

  String get _fromCurrency => _currencyOf(_accountId);
  String get _toCurrency => _currencyOf(_toAccountId);
  bool get _isTransfer => _kind == TxnKind.transfer;
  bool get _crossCurrency => _isTransfer && _toAccountId != null && _toCurrency != _fromCurrency;

  /// A rate is needed to value foreign money in the base currency, unless
  /// a transfer's receiving side already is in it.
  bool get _needsRate =>
      _fromCurrency != baseCurrency && !(_crossCurrency && _toCurrency == baseCurrency);

  static Decimal? _parse(TextEditingController c) =>
      Decimal.tryParse(c.text.replaceAll(RegExp(r'[,\s]'), ''));

  void _setKind(TxnKind kind) => setState(() {
    _kind = kind;
    _error = null;
    if (kind == TxnKind.transfer) {
      _categoryId = null;
    } else if (_categoryId == null || _ledger.category(_categoryId!)?.kind != kind) {
      _categoryId = defaultCategoryId(_ledger, kind, _app.lastCategoryId(kind));
    }
  });

  Future<void> _chooseCategory() async {
    final id = await pickCategory(
      context,
      ledger: _ledger,
      kind: _kind,
      selectedId: _categoryId,
    );
    if (id != null) setState(() => _categoryId = id);
  }

  Future<void> _chooseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _newProject() async {
    final name = await askText(context, title: '新增專案', label: '專案名稱');
    if (name == null) return;
    final project = Project(id: newId('p'), name: name);
    final error = _app.write((l) => l.addProject(project));
    if (error != null) {
      setState(() => _error = error);
    } else {
      setState(() => _projectId = project.id);
    }
  }

  /// The record to save, or an error message.
  (Txn?, String?) _build() {
    final amount = _parse(_amount);
    if (amount == null || amount <= Decimal.zero) return (null, '請輸入大於 0 的金額');
    if (_accountId == null) return (null, _isTransfer ? '請選擇轉出帳戶' : '請選擇帳戶');
    if (_isTransfer) {
      if (_toAccountId == null) return (null, '請選擇轉入帳戶');
      if (_toAccountId == _accountId) return (null, '轉出和轉入不能是同一個帳戶');
    } else if (_categoryId == null) {
      return (null, '請選擇分類');
    }
    final toAmount = _crossCurrency ? _parse(_toAmount) : null;
    if (_crossCurrency && (toAmount == null || toAmount <= Decimal.zero)) {
      return (null, '請輸入轉入金額（$_toCurrency）');
    }
    final rate = _needsRate ? _parse(_rate) : null;
    if (_needsRate && (rate == null || rate <= Decimal.zero)) {
      return (null, '請輸入 $_fromCurrency 對新台幣的匯率');
    }
    final old = _old;
    final Decimal base;
    if (old != null &&
        amount == old.amount &&
        (_rate.text.trim() == (old.fxRateDisplay ?? '') || !_needsRate) &&
        toAmount == old.toAmount &&
        _accountId == old.accountId) {
      base = old.baseAmount; // unchanged: keep the imported subtotal exactly
    } else if (_fromCurrency == baseCurrency) {
      base = amount;
    } else if (_crossCurrency && _toCurrency == baseCurrency) {
      base = toAmount!;
    } else {
      base = (amount * rate!).round(scale: 2);
    }
    final note = _note.text.trim();
    return (
      Txn(
        id: old?.id ?? newId('t'),
        kind: _kind,
        date: _date,
        accountId: _accountId,
        toAccountId: _isTransfer ? _toAccountId : null,
        amount: amount,
        toAmount: toAmount,
        baseAmount: base,
        fxRateDisplay: _needsRate ? _rate.text.trim() : null,
        categoryId: _isTransfer ? null : _categoryId,
        projectId: _projectId,
        note: note.isEmpty ? null : note,
        place: old?.place,
        invoice: old?.invoice,
        createdAt: old?.createdAt ?? _app.clock(),
        feeOfTxnId: old?.feeOfTxnId,
        legacyRows: old?.legacyRows ?? const [],
      ),
      null,
    );
  }

  void _save() {
    final (txn, problem) = _build();
    final error = problem ?? _app.saveTxn(txn!, isNew: _isNew);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    if (!await confirm(context, title: '刪除這筆紀錄？', action: '刪除') || !mounted) {
      return;
    }
    final error = _app.write((l) => l.deleteTxn(_old!.id));
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.pop(context, true);
    }
  }

  Widget _accountPicker({
    required Key key,
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    final accounts = [
      for (final a in _ledger.accounts)
        if (!a.archived || a.id == value) a,
    ];
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [
        for (final a in accounts)
          DropdownMenuItem(
            value: a.id,
            child: Text(a.currency == baseCurrency ? a.name : '${a.name}（${a.currency}）'),
          ),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invoice = _old?.invoice;
    final amountPrefix = _fromCurrency == baseCurrency ? 'NT\$ ' : '$_fromCurrency ';
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '記一筆' : '編輯紀錄'),
        actions: [
          if (!_isNew)
            IconButton(
              key: const Key('deleteTxn'),
              tooltip: '刪除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          TextButton(key: const Key('saveTxn'), onPressed: _save, child: const Text('儲存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<TxnKind>(
            segments: const [
              ButtonSegment(value: TxnKind.expense, label: Text('支出')),
              ButtonSegment(value: TxnKind.income, label: Text('收入')),
              ButtonSegment(value: TxnKind.transfer, label: Text('轉帳')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => _setKind(s.single),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('txnAmount'),
            controller: _amount,
            autofocus: _isNew,
            style: theme.textTheme.headlineSmall,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _isTransfer ? '轉出金額' : '金額',
              prefixText: amountPrefix,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          if (!_isTransfer) ...[
            ListTile(
              key: const Key('txnCategory'),
              shape: RoundedRectangleBorder(
                side: BorderSide(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(4),
              ),
              leading: const Icon(Icons.category_outlined),
              title: Text(categoryLabel(_ledger, _categoryId)),
              trailing: const Icon(Icons.expand_more),
              onTap: _chooseCategory,
            ),
            const SizedBox(height: 16),
            _accountPicker(
              key: const Key('txnAccount'),
              label: '帳戶',
              value: _accountId,
              onChanged: (v) => setState(() {
                _accountId = v;
                _rate.text = _lastRate(v) ?? '';
              }),
            ),
          ] else ...[
            _accountPicker(
              key: const Key('txnFrom'),
              label: '轉出帳戶',
              value: _accountId,
              onChanged: (v) => setState(() {
                _accountId = v;
                _rate.text = _lastRate(v) ?? '';
              }),
            ),
            const SizedBox(height: 16),
            _accountPicker(
              key: const Key('txnTo'),
              label: '轉入帳戶',
              value: _toAccountId,
              onChanged: (v) => setState(() => _toAccountId = v),
            ),
          ],
          if (_crossCurrency) ...[
            const SizedBox(height: 16),
            TextField(
              key: const Key('txnToAmount'),
              controller: _toAmount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '轉入金額',
                prefixText: _toCurrency == baseCurrency ? 'NT\$ ' : '$_toCurrency ',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          if (_needsRate) ...[
            const SizedBox(height: 16),
            TextField(
              key: const Key('txnRate'),
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '匯率（1 $_fromCurrency = ? 新台幣）',
                helperText: _ratePreview(),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: const Text('日期'),
            trailing: Text(formatDate(_date)),
            onTap: _chooseDate,
          ),
          DropdownButtonFormField<String?>(
            // Rebuilt when a project is added, so it shows the new one.
            key: ValueKey('txnProject-$_projectId-${_ledger.projects.length}'),
            initialValue: _projectId,
            decoration: const InputDecoration(labelText: '專案', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('無')),
              for (final p in _ledger.projects)
                DropdownMenuItem<String?>(value: p.id, child: Text(p.name)),
              const DropdownMenuItem<String?>(value: '__new', child: Text('新增專案…')),
            ],
            onChanged: (v) {
              if (v == '__new') {
                _newProject();
              } else {
                setState(() => _projectId = v);
              }
            },
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('txnNote'),
            controller: _note,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(labelText: '備註', border: OutlineInputBorder()),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, key: const Key('txnError'), style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (invoice != null) ...[
            const SizedBox(height: 16),
            _InvoiceCard(invoice: invoice),
          ],
          if (_old?.needsReview ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '這筆轉帳在匯入時只找到一邊。補上另一個帳戶並儲存後，就不再標記待確認。',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  String? _ratePreview() {
    final amount = _parse(_amount), rate = _parse(_rate);
    if (amount == null || rate == null) return null;
    return '約 ${formatMoney((amount * rate).round(scale: 2))}';
  }
}

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({required this.invoice});
  final Invoice invoice;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '發票 ${invoice.number}${invoice.sellerName == null ? '' : '・${invoice.sellerName}'}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          for (final i in invoice.items)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(child: Text('${i.name} ×${i.quantity}')),
                  Text(formatMoney(i.amount)),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
