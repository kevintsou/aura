part of 'importer.dart';

/// What [exportCwmoneyCsv] produced.
class CwmExportResult {
  CwmExportResult(
    this.bytes, {
    required this.records,
    required this.rows,
    required this.unchanged,
    required this.replacedCharacters,
  });

  /// The file: Big5-HKSCS, CRLF records, like CWMoney's own export.
  final Uint8List bytes;

  /// Aura records exported, and CSV rows written (a transfer is two).
  final int records;
  final int rows;

  /// Imported records written back exactly as they were read.
  final int unchanged;

  /// Characters Big5-HKSCS cannot hold (e.g. emoji), written as `?`.
  final int replacedCharacters;
}

/// Writes the ledger (or [from]–[to]) as a CWMoney classic CSV export,
/// newest first, which CWMoney and Excel can read.
///
/// Records imported from CWMoney keep their original fields wherever
/// Aura has not changed them, so an import followed by an export gives
/// back the same file. The e-invoice carrier number is masked unless
/// [includeCarrier] is set.
CwmExportResult exportCwmoneyCsv(
  LedgerReader ledger, {
  DateTime? from,
  DateTime? to,
  bool includeCarrier = false,
}) {
  final exporter = _Exporter(ledger, includeCarrier);
  final out = StringBuffer()..write(_line(cwmColumns));
  final txns = ledger.transactions(TxnFilter(from: from, to: to));
  var rows = 0;
  for (final t in txns) {
    for (final row in exporter.rows(t)) {
      out.write(_line(row));
      rows++;
    }
  }
  var replaced = 0;
  final bytes = encodeBig5Hkscs(out.toString(), unmappable: (_) => replaced++);
  return CwmExportResult(
    bytes,
    records: txns.length,
    rows: rows,
    unchanged: exporter.unchanged,
    replacedCharacters: replaced,
  );
}

String _line(List<String> fields) => '"${fields.join('","')}"\r\n';

String _two(int n) => n.toString().padLeft(2, '0');
String _cwmDate(DateTime d) => '${d.year}/${_two(d.month)}/${_two(d.day)}';
String _cwmDateTime(DateTime? d) =>
    d == null ? '' : '${_cwmDate(d)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// Fields other than the note must not contain what separates fields or
/// records (CWMoney does not escape quotes).
String _field(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll('","', '"，"');

class _Exporter {
  _Exporter(this.ledger, this.includeCarrier);

  final LedgerReader ledger;
  final bool includeCarrier;
  var unchanged = 0;

  String _account(String? id) {
    final name = id == null ? '' : ledger.account(id)?.name ?? '';
    return name == unnamedAccount ? '' : _field(name);
  }

  String _currency(String? id) => id == null ? baseCurrency : ledger.account(id)?.currency ?? baseCurrency;

  /// The rate CWMoney shows for [amount] in an account of [currency].
  String _rate(String currency, Decimal amount, Decimal base) {
    if (currency == baseCurrency || amount == Decimal.zero) return '1';
    final r = (base / amount).toDecimal(scaleOnInfinitePrecision: 4);
    return r.toString();
  }

  List<List<String>> rows(Txn t) {
    final generated = _generate(t);
    final legacy = [...t.legacyRows];
    final out = <List<String>>[];
    for (final g in generated) {
      // Match by 收入／支出, so each side of a transfer finds its own row.
      final i = legacy.indexWhere((l) => l.length == 15 && l[1] == g[1]);
      // The receiving row of a paired transfer: Aura keeps only the
      // sending side's rate and subtotal, so CWMoney's own values for
      // this row stay as long as its amount does.
      final receiving = g[13] == '1' && g[1] == '收入' && t.accountId != null;
      out.add(i < 0 ? g : _merge(legacy.removeAt(i), g, receiving: receiving));
    }
    if (legacy.isEmpty && t.legacyRows.isNotEmpty) {
      final same = out.length == t.legacyRows.length &&
          [for (final (i, row) in out.indexed) row.join('\u0000') == t.legacyRows[i].join('\u0000')].every((s) => s);
      if (same) unchanged++;
    }
    return [
      for (final row in out) [...row.take(14), _maskCarrier(row[14])],
    ];
  }

  String _maskCarrier(String note) => includeCarrier || !note.contains('[')
      ? note
      : [
          for (final line in note.split('\n'))
            switch (_carrierRe.firstMatch(line)) {
              final m? => '[${m[1]},******]',
              _ => line,
            },
        ].join('\n');

  List<List<String>> _generate(Txn t) {
    final project = t.projectId == null ? _noProject : _field(ledger.project(t.projectId!)?.name ?? _noProject);
    final created = _cwmDateTime(t.createdAt);
    final date = _cwmDate(t.date);
    final base = '${t.baseAmount}';
    if (t.kind == TxnKind.transfer) {
      final note = t.note ?? _transferNote;
      final toAmount = t.toAmount ?? t.amount;
      return [
        if (t.toAccountId != null)
          [
            date, '收入', '', '', _account(t.toAccountId), project, '$toAmount', //
            t.accountId == null
                ? t.fxRateDisplay ?? _rate(_currency(t.toAccountId), toAmount, t.baseAmount)
                : _rate(_currency(t.toAccountId), toAmount, t.baseAmount),
            base, created, '', ' ', '', '1', note,
          ],
        if (t.accountId != null)
          [
            date, '支出', '', '', _account(t.accountId), project, '${t.amount}', //
            t.fxRateDisplay ?? _rate(_currency(t.accountId), t.amount, t.baseAmount), base, created, '', ' ', '', '1',
            note,
          ],
      ];
    }
    final leaf = t.categoryId == null ? null : ledger.category(t.categoryId!);
    final parent = leaf?.parentId == null ? null : ledger.category(leaf!.parentId!);
    final isFee = t.feeOfTxnId != null;
    final invoice = t.invoice;
    // A fee shares its transfer's creation time; that is how CWMoney ties them.
    final feeOf = isFee ? ledger.txn(t.feeOfTxnId!) : null;
    return [
      [
        date,
        t.kind == TxnKind.income ? '收入' : '支出',
        _field(parent?.name ?? leaf?.name ?? ''),
        _field(parent == null ? '' : leaf!.name),
        _account(t.accountId),
        project,
        '${t.amount}',
        t.fxRateDisplay ?? '1',
        base,
        feeOf == null ? created : _cwmDateTime(feeOf.createdAt ?? t.createdAt),
        switch (t.location) {
          final p? => '${p.lat} : ${p.lng}',
          null => invoice == null ? '' : '0.0 : 0.0',
        },
        invoice == null
            ? _field(t.place ?? ' ')
            : _field('(${invoice.sellerName ?? ''}${invoice.sellerAddress == null ? '' : ',${invoice.sellerAddress}'})'),
        invoice?.number ?? '',
        isFee ? '2' : '0',
        invoice != null ? _invoiceNote(t, invoice) : t.note ?? (isFee ? _feeNote : ''),
      ],
    ];
  }

  /// Items, seller and carrier lines as CWMoney writes them, then the
  /// user's own note; imported lines are reused as they were.
  String _invoiceNote(Txn t, Invoice invoice) {
    final legacy = t.legacyRows.firstOrNull;
    final generatedLines = legacy != null && legacy.length == 15
        ? [
            for (final line in legacy[14].split('\n'))
              if (_itemRe.hasMatch(line) || _sellerRe.hasMatch(line) || _carrierRe.hasMatch(line)) line,
          ]
        : [
            for (final i in invoice.items) '${i.name}x${i.quantity}=${i.amount}',
            if (invoice.sellerTaxId != null) '(${invoice.sellerTaxId},${invoice.sellerName ?? ''})',
            if (invoice.carrier != null) '[手機條碼,${invoice.carrier}]',
          ];
    return [...generatedLines, ?t.note].join('\n');
  }

  /// [legacy] with only the fields that differ in meaning from
  /// [generated] replaced, so untouched fields keep CWMoney's formatting.
  List<String> _merge(List<String> legacy, List<String> generated, {bool receiving = false}) {
    String? note(List<String> row) => row[12].isNotEmpty
        ? _invoiceUserNote(row[14])
        : switch (_clean(row[14])) {
            _transferNote when row[13] == '1' => null,
            _feeNote when row[13] == '2' => null,
            final n => n,
          };
    String account(String s) => s.trim().isEmpty ? unnamedAccount : s;
    String project(String s) => s.isEmpty ? _noProject : s;
    bool same(int i) {
      final l = legacy[i], g = generated[i];
      return switch (i) {
        0 => _parseDate(l) == _parseDate(g),
        4 => account(l) == account(g),
        5 => project(l) == project(g),
        7 || 8 when receiving && same(6) && same(4) => true,
        6 || 8 => Decimal.tryParse(l) == Decimal.tryParse(g),
        // The two rows of a transfer can be created a second or two apart.
        9 when legacy[13] == '1' => switch ((_parseDateTime(l), _parseDateTime(g))) {
          (final a?, final b?) => a.difference(b).abs() <= fuzzyWindow,
          (final a, final b) => a == b,
        },
        9 => _parseDateTime(l) == _parseDateTime(g),
        10 => GeoPoint.tryParse(l) == GeoPoint.tryParse(g), // "0:0" and "" both mean none
        11 => legacy[12].isNotEmpty || _clean(l) == _clean(g), // invoices cannot be edited
        13 => l == g || (l == '2' && g == '0'), // a fee whose transfer was not found
        14 => note(legacy) == note(generated),
        _ => l == g,
      };
    }

    return [for (var i = 0; i < 15; i++) same(i) ? legacy[i] : generated[i]];
  }
}
