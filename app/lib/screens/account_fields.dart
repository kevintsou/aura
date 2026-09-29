import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

const accountTypeLabels = {
  AccountType.cash: '現金',
  AccountType.bank: '銀行',
  AccountType.credit: '信用卡',
  AccountType.epay: '電子支付',
  AccountType.securities: '證券',
  AccountType.other: '其他',
};

/// Currencies offered in the picker; any ISO code can be typed instead.
const commonCurrencies = {
  'TWD': '新台幣',
  'USD': '美元',
  'JPY': '日圓',
  'EUR': '歐元',
  'CNY': '人民幣',
  'HKD': '港幣',
  'GBP': '英鎊',
  'AUD': '澳幣',
  'CAD': '加幣',
  'SGD': '新加坡幣',
  'KRW': '韓元',
  'THB': '泰銖',
  'CHF': '瑞士法郎',
  'NZD': '紐西蘭幣',
};

class AccountTypeField extends StatelessWidget {
  const AccountTypeField({super.key, required this.value, required this.onChanged});

  final AccountType value;
  final ValueChanged<AccountType> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<AccountType>(
    key: const Key('accountType'),
    initialValue: value,
    decoration: const InputDecoration(labelText: '類型', border: OutlineInputBorder()),
    items: [
      for (final t in AccountType.values)
        DropdownMenuItem(value: t, child: Text(accountTypeLabels[t]!)),
    ],
    onChanged: (t) => onChanged(t!),
  );
}

const _other = '__other';

/// Picks a currency from [commonCurrencies] or lets the user type an ISO
/// code. Reports null while nothing valid is chosen (including an
/// [unknownCurrency] start value, which must be replaced).
class CurrencyField extends StatefulWidget {
  const CurrencyField({super.key, required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String?> onChanged;

  @override
  State<CurrencyField> createState() => _CurrencyFieldState();
}

class _CurrencyFieldState extends State<CurrencyField> {
  final _custom = TextEditingController();
  late String _choice;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _choice = c == unknownCurrency || commonCurrencies.containsKey(c) ? c : _other;
    if (_choice == _other) _custom.text = c;
    _custom.addListener(() {
      setState(() {});
      widget.onChanged(_code);
    });
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String? get _code {
    if (_choice == unknownCurrency) return null;
    if (_choice != _other) return _choice;
    final code = _custom.text.trim().toUpperCase();
    return isCurrencyCode(code) ? code : null;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        key: const Key('accountCurrency'),
        initialValue: _choice,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: '幣別',
          border: const OutlineInputBorder(),
          errorText: _choice == unknownCurrency ? '請選擇幣別' : null,
        ),
        items: [
          if (_choice == unknownCurrency)
            const DropdownMenuItem(value: unknownCurrency, child: Text('未知')),
          for (final e in commonCurrencies.entries)
            DropdownMenuItem(value: e.key, child: Text('${e.key} ${e.value}')),
          const DropdownMenuItem(value: _other, child: Text('其他…')),
        ],
        onChanged: (c) {
          setState(() => _choice = c!);
          widget.onChanged(_code);
        },
      ),
      if (_choice == _other) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('customCurrency'),
          controller: _custom,
          textCapitalization: TextCapitalization.characters,
          maxLength: 3,
          decoration: InputDecoration(
            labelText: '幣別代碼（ISO 4217）',
            hintText: '例如 MYR',
            errorText: _custom.text.isNotEmpty && _code == null ? '請輸入三個英文字母' : null,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    ],
  );
}
