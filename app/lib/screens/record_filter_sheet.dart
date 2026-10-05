import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import '../format.dart';

enum _PeriodChoice { all, thisMonth, lastMonth, custom }

class RecordFilterSheet extends StatefulWidget {
  const RecordFilterSheet({super.key, required this.initial, required this.accounts, required this.today});
  final TxnFilter initial;
  final List<Account> accounts;
  final DateTime today;
  @override
  State<RecordFilterSheet> createState() => _RecordFilterSheetState();
}

class _RecordFilterSheetState extends State<RecordFilterSheet> {
  late final TextEditingController _keyword;
  late _PeriodChoice _period;
  DateTimeRange? _range;
  String _account = '';
  TxnKind? _kind;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _keyword = TextEditingController(text: f.keyword);
    _kind = f.kinds?.firstOrNull;
    _account = f.accountIds?.firstOrNull ?? '';
    if (!widget.accounts.any((a) => a.id == _account)) _account = '';
    _period = f.from == null ? _PeriodChoice.all : _PeriodChoice.custom;
    final today = widget.today;
    if (f.from == DateTime(today.year, today.month) && f.to == DateTime(today.year, today.month + 1, 0)) {
      _period = _PeriodChoice.thisMonth;
    } else if (f.from == DateTime(today.year, today.month - 1) && f.to == DateTime(today.year, today.month, 0)) {
      _period = _PeriodChoice.lastMonth;
    }
    if (f.from != null && f.to != null) _range = DateTimeRange(start: f.from!, end: f.to!);
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange: _range,
      currentDate: widget.today,
      helpText: '選擇紀錄日期區間',
      saveText: '套用',
    );
    if (range != null && mounted) {
      setState(() {
        _period = _PeriodChoice.custom;
        _range = range;
      });
    }
  }

  void _apply() {
    if (_period == _PeriodChoice.custom && _range == null) return;
    final today = widget.today;
    final range = switch (_period) {
      _PeriodChoice.all => null,
      _PeriodChoice.thisMonth => DateTimeRange(
        start: DateTime(today.year, today.month),
        end: DateTime(today.year, today.month + 1, 0),
      ),
      _PeriodChoice.lastMonth => DateTimeRange(
        start: DateTime(today.year, today.month - 1),
        end: DateTime(today.year, today.month, 0),
      ),
      _PeriodChoice.custom => _range,
    };
    Navigator.pop(
      context,
      TxnFilter(
        from: range?.start,
        to: range?.end,
        accountIds: _account.isEmpty ? null : {_account},
        kinds: _kind == null ? null : {_kind!},
        keyword: _keyword.text.trim().isEmpty ? null : _keyword.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('篩選紀錄', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            DropdownButtonFormField<_PeriodChoice>(
              key: const Key('recordsPeriod'),
              initialValue: _period,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '日期區間', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: _PeriodChoice.all, child: Text('全部日期')),
                DropdownMenuItem(value: _PeriodChoice.thisMonth, child: Text('本月')),
                DropdownMenuItem(value: _PeriodChoice.lastMonth, child: Text('上月')),
                DropdownMenuItem(value: _PeriodChoice.custom, child: Text('自訂日期')),
              ],
              onChanged: (value) async {
                if (value == null) return;
                setState(() => _period = value);
                if (value == _PeriodChoice.custom) await _pickDates();
              },
            ),
            if (_period == _PeriodChoice.custom)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.date_range),
                title: Text(_range == null ? '選擇起訖日期' : '${formatDate(_range!.start)} ～ ${formatDate(_range!.end)}'),
                onTap: _pickDates,
              ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const Key('recordsAccount'),
              initialValue: _account,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '帳戶', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: '', child: Text('全部帳戶')),
                for (final a in widget.accounts)
                  DropdownMenuItem(value: a.id, child: Text(a.archived ? '${a.name}（已封存）' : a.name)),
              ],
              onChanged: (value) => setState(() => _account = value ?? ''),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const Key('recordsKind'),
              initialValue: _kind?.name ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '類型', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: '', child: Text('全部類型')),
                DropdownMenuItem(value: 'income', child: Text('收入')),
                DropdownMenuItem(value: 'expense', child: Text('支出')),
                DropdownMenuItem(value: 'transfer', child: Text('轉帳')),
              ],
              onChanged: (value) => setState(() => _kind = TxnKind.values.where((k) => k.name == value).firstOrNull),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('recordsKeyword'),
              controller: _keyword,
              decoration: const InputDecoration(
                labelText: '關鍵字',
                hintText: '備註、商家、地點或發票品項',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _apply(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('applyRecordsFilter'),
              onPressed: _period == _PeriodChoice.custom && _range == null ? null : _apply,
              child: const Text('套用篩選'),
            ),
            TextButton(onPressed: () => Navigator.pop(context, const TxnFilter()), child: const Text('清除所有篩選')),
          ],
        ),
      ),
    ),
  );
}
