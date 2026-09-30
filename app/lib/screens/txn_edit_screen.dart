import 'dart:typed_data';

import 'package:aura_core/aura_core.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import 'category_picker.dart';
import 'dialogs.dart';

/// Records a new expense, income or transfer, or edits an existing one.
/// Also adds and edits recurring items: a new record with a repeat rule
/// becomes one.
class TxnEditScreen extends StatefulWidget {
  const TxnEditScreen({
    super.key,
    required this.app,
    this.txn,
    this.recurring,
    this.repeat = false,
    this.draft,
    this.categoryGuessed = true,
  });

  final AppState app;

  /// Null for a new record.
  final Txn? txn;

  /// The recurring item to edit.
  final Recurring? recurring;

  /// Start a new record as a monthly recurring item.
  final bool repeat;

  /// A new record filled in already (a scanned invoice), to check and save.
  final Txn? draft;

  /// The draft's category came from the user's own history; when not,
  /// the AI can be asked for one.
  final bool categoryGuessed;

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
  RepeatUnit? _unit;
  final _every = TextEditingController(text: '1');
  final _times = TextEditingController(text: '12');
  var _end = _End.never;
  DateTime? _until;

  /// Photo changes, applied on save.
  final _newPhotos = <Uint8List>[];
  final _removedPhotos = <String>{};

  /// Where the record was made; looked up for new records when the user
  /// turned that on.
  GeoPoint? _location;
  var _locating = false;

  /// Asking the AI for the scanned invoice's category, or done asking.
  var _askingAi = false, _aiPicked = false;

  bool get _offerAiCategory =>
      !widget.categoryGuessed &&
      !_aiPicked &&
      !_isTransfer &&
      widget.draft?.invoice != null &&
      _app.canAskAiCategory(widget.draft!.invoice!);

  Future<void> _askAiCategory() async {
    setState(() {
      _askingAi = true;
      _error = null;
    });
    final (id, problem) = await _app.aiCategoryFor(widget.draft!.invoice!);
    if (!mounted) return;
    setState(() {
      _askingAi = false;
      if (id != null && _ledger.category(id)?.kind == _kind) {
        _categoryId = id;
        _aiPicked = true;
      } else {
        _error = problem ?? 'AI 選的分類不能用在這裡';
      }
    });
  }

  AppState get _app => widget.app;
  LedgerStore get _ledger => _app.ledger;
  Txn? get _old => widget.txn;

  /// What the form starts from: the record, or the recurring template.
  Txn? get _source => widget.txn ?? widget.recurring?.template ?? widget.draft;
  bool get _isNew => widget.txn == null && widget.recurring == null;
  bool get _editingRecurring => widget.recurring != null;

  /// A repeat rule can be set on new records and recurring items, not on
  /// a record that already exists.
  bool get _canRepeat => widget.txn == null;

  @override
  void initState() {
    super.initState();
    final t = _source;
    if (widget.recurring case final r?) {
      _unit = r.unit;
      _every.text = '${r.every}';
      if (r.until != null) {
        _end = _End.until;
        _until = r.until;
      }
      if (r.times != null) {
        _end = _End.times;
        _times.text = '${r.times}';
      }
    } else if (widget.repeat) {
      _unit = RepeatUnit.month;
    }
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
    _location = widget.txn?.location;
    if (widget.txn == null && widget.recurring == null && !widget.repeat && _app.recordLocation) {
      _locating = true;
      _locate();
    }
    for (final c in [_amount, _toAmount, _rate, _note, _every, _times]) {
      c.addListener(() => setState(() => _error = null));
    }
  }

  @override
  void dispose() {
    for (final c in [_amount, _toAmount, _rate, _note, _every, _times]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _locate() async {
    final here = await _app.locationSource.current();
    // Unless the user said not to while it was looking.
    if (!mounted || !_locating) return;
    setState(() {
      _location = here;
      _locating = false;
    });
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
    final old = _source;
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
        id: _old?.id ?? newId('t'),
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
        place: _old?.place,
        location: _isTransfer || _unit != null ? null : _location,
        invoice: (_old ?? widget.draft)?.invoice,
        createdAt: _old?.createdAt ?? _app.clock(),
        feeOfTxnId: _old?.feeOfTxnId,
        recurringId: _old?.recurringId,
        legacyRows: _old?.legacyRows ?? const [],
      ),
      null,
    );
  }

  /// The recurring item [txn] repeats, or an error message. Null [txn]
  /// gives a preview while the form is incomplete.
  (Recurring?, String?) _buildRecurring(Txn txn) {
    final every = int.tryParse(_every.text.trim());
    if (every == null || every < 1) return (null, '間隔至少是 1');
    final times = _end == _End.times ? int.tryParse(_times.text.trim()) : null;
    if (_end == _End.times && (times == null || times < 1)) return (null, '次數至少是 1');
    if (_end == _End.until && _until == null) return (null, '請選擇結束日期');
    final id = widget.recurring?.id ?? newId('r');
    final draft = Recurring(
      id: id,
      template: txn.copyWith(id: id, recurringId: null),
      unit: _unit!,
      every: every,
      until: _end == _End.until ? _until : null,
      times: times,
    );
    // Carry on from where the item was, unless nothing was recorded yet.
    final old = widget.recurring;
    final DateTime resume;
    if (old == null || old.next == old.start) {
      resume = draft.start;
    } else {
      resume = old.next ?? dateOnly(_app.clock()).add(const Duration(days: 1));
    }
    return (draft.withNext(draft.firstFrom(resume)), null);
  }

  void _save() {
    final (txn, problem) = _build();
    if (problem != null || _unit == null) {
      final error =
          problem ??
          _app.saveTxn(txn!, isNew: _isNew, addPhotos: _newPhotos, removePhotos: [..._removedPhotos]);
      if (error != null) {
        setState(() => _error = error);
        return;
      }
      Navigator.pop(context, true);
      return;
    }
    final (recurring, invalid) = _buildRecurring(txn!);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final (error, recorded) = _app.saveRecurring(recurring!);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final next = _ledger.recurrings.where((r) => r.id == recurring.id).firstOrNull?.next;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            if (recorded > 0) '已記入 $recorded 筆',
            next == null ? '週期收支已結束' : '下次 ${formatDate(next)}',
          ].join('，'),
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    if (_editingRecurring) {
      if (!await confirm(
            context,
            title: '刪除這個週期收支？',
            message: '之後不會再自動記帳。已經記下的紀錄會保留。',
            action: '刪除',
          ) ||
          !mounted) {
        return;
      }
      _app.deleteRecurring(widget.recurring!.id);
      Navigator.pop(context, true);
      return;
    }
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
        if ((!a.archived && !_app.hiddenAccountIds.contains(a.id)) || a.id == value) a,
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
    final invoice = (_old ?? widget.draft)?.invoice;
    final amountPrefix = _fromCurrency == baseCurrency ? 'NT\$ ' : '$_fromCurrency ';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _editingRecurring
              ? '編輯週期收支'
              : _unit != null
              ? '新增週期收支'
              : _isNew
              ? '記一筆'
              : '編輯紀錄',
        ),
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
              subtitle: _aiPicked ? const Text('AI 建議的分類，點一下可以改') : null,
              trailing: const Icon(Icons.expand_more),
              onTap: _chooseCategory,
            ),
            if (_offerAiCategory)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('aiCategory'),
                  onPressed: _askingAi ? null : _askAiCategory,
                  icon: _askingAi
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_outlined),
                  label: Text(_askingAi ? 'AI 判斷中…' : '以前沒記過這家，讓 AI 選分類'),
                ),
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
            title: Text(_unit == null ? '日期' : '開始日期'),
            trailing: Text(formatDate(_date)),
            onTap: _chooseDate,
          ),
          if (_canRepeat) ..._repeatFields(theme),
          if (_recurringOfOld() case final r?)
            ListTile(
              key: const Key('openRecurring'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.repeat),
              title: const Text('由週期收支自動記入'),
              subtitle: Text('${describeRepeat(r)}。在這裡修改只會改這一筆。'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => TxnEditScreen(app: _app, recurring: r)),
              ),
            ),
          const SizedBox(height: 16),
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
          if (!_isTransfer && _unit == null && (_location != null || _locating))
            ListTile(
              key: const Key('txnLocation'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: const Text('位置'),
              subtitle: Text(_locating ? '正在取得位置…' : _location.toString()),
              trailing: IconButton(
                key: const Key('removeLocation'),
                tooltip: '不記錄位置',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _location = null;
                  _locating = false;
                }),
              ),
            ),
          if (_unit == null) ...[
            const SizedBox(height: 16),
            Text('照片（收據、商品）', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            _photos(theme),
          ],
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

  List<String> get _keptPhotoIds => [
    for (final id in _old == null ? const <String>[] : _ledger.photoIds(_old!.id))
      if (!_removedPhotos.contains(id)) id,
  ];

  Future<void> _addPhoto() async {
    final picker = _app.photoPicker;
    final camera = picker.hasCamera
        ? await showModalBottomSheet<bool>(
            context: context,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    key: const Key('photoCamera'),
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('拍照'),
                    onTap: () => Navigator.pop(context, true),
                  ),
                  ListTile(
                    key: const Key('photoGallery'),
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('從相簿選擇'),
                    onTap: () => Navigator.pop(context, false),
                  ),
                ],
              ),
            ),
          )
        : false;
    if (camera == null || !mounted) return;
    final bytes = await _app.lock.whileAway(() => picker.pick(camera: camera));
    if (bytes != null && mounted) setState(() => _newPhotos.add(bytes));
  }

  /// Full screen, zoomable; true when the user deleted it.
  Future<bool> _viewPhoto(Uint8List bytes) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(bytes))),
              ),
              SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '關閉',
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                    const Spacer(),
                    IconButton(
                      key: const Key('deletePhoto'),
                      tooltip: '刪除照片',
                      color: Colors.white,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ) ??
      false;

  Widget _photos(ThemeData theme) {
    Widget thumb(Uint8List bytes, VoidCallback onDelete, Key key) => InkWell(
      key: key,
      onTap: () async {
        if (await _viewPhoto(bytes)) setState(onDelete);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, width: 72, height: 72, fit: BoxFit.cover, semanticLabel: '照片'),
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final id in _keptPhotoIds)
          if (_ledger.photo(id) case final p?) thumb(p.bytes, () => _removedPhotos.add(id), Key('photo-$id')),
        for (final (i, bytes) in _newPhotos.indexed)
          thumb(bytes, () => _newPhotos.removeAt(i), Key('newPhoto-$i')),
        SizedBox(
          width: 72,
          height: 72,
          child: OutlinedButton(
            key: const Key('addPhoto'),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _addPhoto,
            child: const Tooltip(message: '加照片', child: Icon(Icons.add_a_photo_outlined)),
          ),
        ),
      ],
    );
  }

  Recurring? _recurringOfOld() {
    final id = _old?.recurringId;
    return id == null ? null : _ledger.recurrings.where((r) => r.id == id).firstOrNull;
  }

  static const _unitNames = {
    RepeatUnit.day: '天',
    RepeatUnit.week: '週',
    RepeatUnit.month: '個月',
    RepeatUnit.year: '年',
  };

  List<Widget> _repeatFields(ThemeData theme) {
    final unit = _unit;
    return [
      DropdownButtonFormField<RepeatUnit?>(
        key: const Key('txnRepeat'),
        initialValue: unit,
        decoration: const InputDecoration(labelText: '重複', border: OutlineInputBorder()),
        items: [
          if (!_editingRecurring) const DropdownMenuItem(value: null, child: Text('不重複')),
          const DropdownMenuItem(value: RepeatUnit.day, child: Text('每天')),
          const DropdownMenuItem(value: RepeatUnit.week, child: Text('每週')),
          const DropdownMenuItem(value: RepeatUnit.month, child: Text('每月')),
          const DropdownMenuItem(value: RepeatUnit.year, child: Text('每年')),
        ],
        onChanged: (v) => setState(() => _unit = v),
      ),
      if (unit != null) ...[
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('repeatEvery'),
                controller: _every,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '每幾${_unitNames[unit]}',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<_End>(
                key: const Key('repeatEnd'),
                initialValue: _end,
                decoration: const InputDecoration(labelText: '結束', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: _End.never, child: Text('不結束')),
                  DropdownMenuItem(value: _End.until, child: Text('到某天')),
                  DropdownMenuItem(value: _End.times, child: Text('共幾次')),
                ],
                onChanged: (v) => setState(() => _end = v!),
              ),
            ),
          ],
        ),
        if (_end == _End.until)
          ListTile(
            key: const Key('repeatUntil'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_busy),
            title: const Text('結束日期'),
            trailing: Text(_until == null ? '請選擇' : formatDate(_until!)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _until ?? DateTime(_date.year + 1, _date.month, _date.day),
                firstDate: _date,
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _until = picked);
            },
          ),
        if (_end == _End.times) ...[
          const SizedBox(height: 16),
          TextField(
            key: const Key('repeatTimes'),
            controller: _times,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '共幾次',
              helperText: '例如信用卡分期 12 期',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(_repeatPreview() ?? '', key: const Key('repeatPreview'), style: theme.textTheme.bodySmall),
      ],
    ];
  }

  /// The rule in words and what saving will record now.
  String? _repeatPreview() {
    final (txn, _) = _build();
    final probe =
        txn ??
        Txn(
          id: 'preview',
          kind: TxnKind.expense,
          date: _date,
          accountId: 'preview',
          amount: Decimal.one,
          baseAmount: Decimal.one,
        );
    final (r, problem) = _buildRecurring(probe);
    if (r == null) return problem;
    final today = dateOnly(_app.clock());
    final due = r.next == null ? 0 : r.occurrencesFrom(r.next!).takeWhile((d) => !d.isAfter(today)).length;
    return [
      describeRepeat(r),
      if (r.unit == RepeatUnit.month && r.start.day > 28) '沒有 ${r.start.day} 日的月份記在月底',
      if (due > 0)
        '儲存後會記入到今天為止的 $due 筆'
      else if (r.next != null)
        '下次 ${formatDate(r.next!)} 自動記入'
      else
        '已經沒有下一次',
    ].join('。');
  }

  String? _ratePreview() {
    final amount = _parse(_amount), rate = _parse(_rate);
    if (amount == null || rate == null) return null;
    return '約 ${formatMoney((amount * rate).round(scale: 2))}';
  }
}

enum _End { never, until, times }

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
