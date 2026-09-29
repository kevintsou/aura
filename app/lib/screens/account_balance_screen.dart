import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'accounts_screen.dart';

enum _Mode { today, opening, onDate }

/// Sets an account's real balance: today's, the opening one, or the one
/// on a chosen day. The other figures are derived and previewed live.
class AccountBalanceScreen extends StatefulWidget {
  const AccountBalanceScreen({
    super.key,
    required this.app,
    required this.accountId,
  });

  final AppState app;
  final String accountId;

  @override
  State<AccountBalanceScreen> createState() => _AccountBalanceScreenState();
}

class _AccountBalanceScreenState extends State<AccountBalanceScreen> {
  final _amount = TextEditingController();
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
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

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
    final c = _candidate;
    if (c == null) return;
    _app.setBalanceAnchor(widget.accountId, c);
    Navigator.pop(context);
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
    final isCredit = a.type == AccountType.credit;
    String money(Decimal d) => formatMoney(d, currency: a.currency);
    return Scaffold(
      appBar: AppBar(
        title: Text(a.name),
        actions: [
          TextButton(
            key: const Key('saveBalance'),
            onPressed: _candidate == null ? null : _save,
            child: const Text('儲存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${accountTypeLabels[a.type]} · ${a.currency} · ${_saved.flowCount} 筆紀錄'
            '${_saved.firstDate == null ? '' : '（${formatDate(_saved.firstDate!)} – ${formatDate(_saved.lastDate!)}）'}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
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
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            decoration: InputDecoration(
              labelText: _amountLabel,
              prefixText: a.currency == baseCurrency ? 'NT\$ ' : '${a.currency} ',
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
