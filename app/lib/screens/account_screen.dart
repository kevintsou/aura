import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'account_fields.dart';
import 'dialogs.dart';

enum _Mode { today, opening, onDate }

/// One account: rename it, correct its type and currency (the importer
/// guesses them from the name), archive or delete it, and set its real
/// balance: today's, the opening one, or the one on a chosen day.
/// Derived figures are previewed live.
class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.app,
    required this.accountId,
  });

  final AppState app;
  final String accountId;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _amount = TextEditingController();
  final _name = TextEditingController();
  late AccountType _type;
  String? _currency;
  String? _error;
  var _mode = _Mode.today;
  late DateTime _date;
  late final List<AccountFlow> _flows;

  AppState get _app => widget.app;
  AccountBalance get _saved => _app.balances[widget.accountId]!;
  Account get _account => _saved.account;
  DateTime get _today => dateOnly(_app.clock());

  @override
  void initState() {
    super.initState();
    _flows = _app.ledger
        .accountFlows()
        .where((f) => f.accountId == widget.accountId)
        .toList();
    _date = _saved.anchor?.date ?? _today;
    if (_saved.isSet) _amount.text = _saved.current.toString();
    _amount.addListener(() => setState(() {}));
    _name
      ..text = _account.name
      ..addListener(() => setState(() => _error = null));
    _type = _account.type;
    _currency = _account.currency == unknownCurrency ? null : _account.currency;
  }

  @override
  void dispose() {
    _amount.dispose();
    _name.dispose();
    super.dispose();
  }

  String get _newName => _name.text.trim();

  bool get _detailsChanged =>
      _newName != _account.name ||
      _type != _account.type ||
      _currency != _account.currency;

  /// Whether saving would change the account's balances.
  bool get _balanceChanged {
    final p = _preview;
    return p != null &&
        (!_saved.isSet || p.current != _saved.current || p.opening != _saved.opening);
  }

  bool get _canSave =>
      _currency != null &&
      _newName.isNotEmpty &&
      (_amount.text.trim().isEmpty || _entered != null) &&
      (_detailsChanged || _balanceChanged);

  Decimal? get _entered =>
      Decimal.tryParse(_amount.text.replaceAll(RegExp(r'[,\s]|NT\$'), ''));

  BalanceAnchor? get _candidate {
    final amount = _entered;
    if (amount == null) return null;
    return switch (_mode) {
      _Mode.today => BalanceAnchor(amount: amount, date: _today),
      _Mode.opening => _saved.openingAnchor(amount, today: _today),
      _Mode.onDate => BalanceAnchor(amount: amount, date: _date),
    };
  }

  AccountBalance? get _preview {
    final c = _candidate;
    return c == null
        ? null
        : balanceOf(_account, _flows, today: _today, anchor: c);
  }

  String get _amountLabel => switch (_mode) {
    _Mode.today => '今天結束時的實際餘額',
    _Mode.opening => '第一筆紀錄之前的餘額（期初餘額）',
    _Mode.onDate => '${formatDate(_date)} 結束時的實際餘額',
  };

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1990),
      lastDate: _today,
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _save() {
    if (!_canSave) return;
    // Read before any write: writes recompute the saved balance.
    final anchor = _balanceChanged ? _candidate : null;
    if (_detailsChanged) {
      final error = _app.write(
        (l) => l.updateAccount(
          widget.accountId,
          name: _newName,
          type: _type,
          currency: _currency,
        ),
      );
      if (error != null) {
        setState(() => _error = error);
        return;
      }
    }
    if (anchor != null) _app.setBalanceAnchor(widget.accountId, anchor);
    Navigator.pop(context);
  }

  void _toggleArchived() {
    _app.updateAccount(widget.accountId, archived: !_account.archived);
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    if (!await confirm(context, title: '刪除「${_account.name}」？', action: '刪除') ||
        !mounted) {
      return;
    }
    final error = _app.write((l) => l.deleteAccount(widget.accountId));
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.pop(context);
    }
  }

  void _clear() {
    _app.setBalanceAnchor(widget.accountId, null);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = _account;
    final preview = _preview;
    final isCredit = _type == AccountType.credit;
    final currency = _currency ?? a.currency;
    String money(Decimal d) => formatMoney(d, currency: currency);
    return Scaffold(
      appBar: AppBar(
        title: Text(a.name),
        actions: [
          TextButton(
            key: const Key('saveAccount'),
            onPressed: _canSave ? _save : null,
            child: const Text('儲存'),
          ),
          PopupMenuButton<VoidCallback>(
            key: const Key('accountMenu'),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _toggleArchived,
                child: Text(a.archived ? '取消封存' : '封存帳戶'),
              ),
              PopupMenuItem(
                value: _delete,
                enabled: _saved.flowCount == 0,
                child: Text(
                  _saved.flowCount == 0 ? '刪除帳戶' : '刪除帳戶（有紀錄，請改用封存）',
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${_saved.flowCount} 筆紀錄'
            '${_saved.firstDate == null ? '' : '（${formatDate(_saved.firstDate!)} – ${formatDate(_saved.lastDate!)}）'}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('accountName'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名稱',
              helperText: '重新匯入 CSV 時，會用名稱對應帳戶',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AccountTypeField(
                  value: _type,
                  onChanged: (t) => setState(() => _type = t),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CurrencyField(
                  initial: a.currency,
                  onChanged: (c) => setState(() => _currency = c),
                ),
              ),
            ],
          ),
          if (a.archived)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('已封存：記帳時不會出現在帳戶選單。', style: theme.textTheme.bodySmall),
            ),
          SwitchListTile(
            key: const Key('accountHidden'),
            contentPadding: EdgeInsets.zero,
            title: const Text('隱藏這個帳戶'),
            subtitle: const Text('帳戶和它的紀錄不會出現在紀錄、報表、預算和 AI 助理；在「帳戶」可以暫時顯示'),
            value: a.hidden,
            onChanged: (v) => setState(() => _app.updateAccount(widget.accountId, hidden: v)),
          ),
          if (_currency != null && _currency != a.currency)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '只會更改幣別標示，金額數字不會換算。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 24),
          Text('餘額', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(value: _Mode.today, label: Text('今天')),
              ButtonSegment(value: _Mode.opening, label: Text('期初')),
              ButtonSegment(value: _Mode.onDate, label: Text('指定日期')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.single),
          ),
          if (_mode == _Mode.onDate)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: const Text('日期'),
              trailing: Text(formatDate(_date)),
              onTap: _pickDate,
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('balanceAmount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            decoration: InputDecoration(
              labelText: _amountLabel,
              prefixText: currency == baseCurrency ? 'NT\$ ' : '$currency ',
              helperText: isCredit
                  ? '信用卡欠款請輸入負數，例如 -12000'
                  : '例如網銀或存摺上顯示的金額',
              errorText: _amount.text.isNotEmpty && _entered == null
                  ? '請輸入數字'
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Card.outlined(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview == null ? '目前' : '儲存後',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  _Row('期初餘額', money((preview ?? _saved).opening)),
                  _Row(
                    '今天的餘額',
                    money((preview ?? _saved).current),
                    key: const Key('previewCurrent'),
                  ),
                  if (preview == null && !_saved.isSet)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '尚未設定，期初餘額暫時當作 0。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_saved.isSet) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _clear,
              icon: const Icon(Icons.restart_alt),
              label: const Text('清除餘額設定'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}
