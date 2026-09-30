import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'account_fields.dart';

/// Creates an account, optionally with today's real balance.
class NewAccountScreen extends StatefulWidget {
  const NewAccountScreen({super.key, required this.app});

  final AppState app;

  @override
  State<NewAccountScreen> createState() => _NewAccountScreenState();
}

class _NewAccountScreenState extends State<NewAccountScreen> {
  final _name = TextEditingController();
  final _balance = TextEditingController();
  var _type = AccountType.bank;
  String? _currency = baseCurrency;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _balance]) {
      c.addListener(() => setState(() => _error = null));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  Decimal? get _amount =>
      Decimal.tryParse(_balance.text.replaceAll(RegExp(r'[,\s]'), ''));

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _currency != null &&
      (_balance.text.trim().isEmpty || _amount != null);

  void _save() {
    final amount = _amount;
    final account = Account(
      id: newId('a'),
      name: _name.text.trim(),
      type: _type,
      currency: _currency!,
      // End of yesterday: the balance before anything recorded from today
      // on. Back-dated records count as already reflected in it.
      anchor: amount == null
          ? null
          : BalanceAnchor(
              amount: amount,
              date: DateTime(widget.app.clock().year, widget.app.clock().month, widget.app.clock().day - 1),
            ),
    );
    final error = widget.app.write((l) => l.addAccount(account));
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('新增帳戶'),
        actions: [
          TextButton(
            key: const Key('saveNewAccount'),
            onPressed: _valid ? _save : null,
            child: const Text('儲存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('newAccountName'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '名稱',
              hintText: '例如 台新銀行、LINE Pay',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          AccountTypeField(value: _type, onChanged: (t) => setState(() => _type = t)),
          const SizedBox(height: 16),
          CurrencyField(
            initial: baseCurrency,
            onChanged: (c) => setState(() => _currency = c),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('newAccountBalance'),
            controller: _balance,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            decoration: InputDecoration(
              labelText: '目前的餘額（選填）',
              helperText: _type == AccountType.credit
                  ? '信用卡欠款請輸入負數'
                  : '不填的話從 0 開始，之後可以在帳戶裡設定',
              errorText: _balance.text.isNotEmpty && _amount == null ? '請輸入數字' : null,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
