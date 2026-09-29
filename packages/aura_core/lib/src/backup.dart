import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:decimal/decimal.dart';

import 'balance.dart';
import 'ledger.dart';
import 'model.dart';
import 'recurring.dart';

/// Aura backup files (`.aura`): gzip-compressed JSON holding the whole
/// ledger, optionally encrypted with a password (PBKDF2-HMAC-SHA256 →
/// AES-256-GCM). The format does not depend on the database schema, so
/// any version of the app, and any store, can restore it.
///
/// Layout (after gunzip):
/// ```json
/// {"format": "aura-backup", "version": 1, "info": {...},
///  "data": {...}}                                  // plain
/// {"format": "aura-backup", "version": 1, "info": {...},
///  "encryption": {"kdf": ..., "cipher": ...}, "payload": "base64"}
/// ```
/// An encrypted payload is AES-GCM over the gzip of the `data` JSON.
/// `info` (creation time and counts) stays readable without the password
/// so a restore can be previewed; everything else is in `data`.
const backupFormat = 'aura-backup';
const backupVersion = 1;
const backupExtension = 'aura';

/// PBKDF2 rounds for new backups. Stored in each file, so it can grow
/// without breaking old backups.
const backupKdfIterations = 300000;

class BackupException implements Exception {
  BackupException(this.message);

  /// Shown to users.
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

class BackupInfo {
  const BackupInfo({
    required this.createdAt,
    required this.accounts,
    required this.transactions,
    required this.encrypted,
    this.firstDate,
    this.lastDate,
  });

  final DateTime createdAt;
  final int accounts;
  final int transactions;
  final bool encrypted;
  final DateTime? firstDate;
  final DateTime? lastDate;
}

class BackupContents {
  const BackupContents(this.info, this.ledger, this.meta);
  final BackupInfo info;
  final InMemoryLedger ledger;
  final Map<String, String> meta;
}

/// Serializes [ledger] (and [meta]) into backup bytes.
Future<Uint8List> encodeBackup(
  LedgerReader ledger, {
  required DateTime createdAt,
  Map<String, String> meta = const {},
  String? password,
  int iterations = backupKdfIterations,
}) async {
  final txns = ledger.transactions();
  final info = {
    'createdAt': createdAt.toIso8601String(),
    'accounts': ledger.accounts.length,
    'transactions': txns.length,
    if (txns.isNotEmpty) 'firstDate': _date(txns.last.date),
    if (txns.isNotEmpty) 'lastDate': _date(txns.first.date),
  };
  final data = {
    'accounts': [for (final a in ledger.accounts) _accountToJson(a)],
    'categories': [for (final c in ledger.categories) _categoryToJson(c)],
    'projects': [for (final p in ledger.projects) {'id': p.id, 'name': p.name}],
    'budgets': [
      for (final b in ledger.budgets)
        {'id': b.id, if (b.categoryId != null) 'categoryId': b.categoryId, 'amount': '${b.amount}'},
    ],
    'recurring': [
      for (final r in ledger.recurrings)
        {
          'id': r.id,
          'template': _txnToJson(r.template),
          'unit': r.unit.name,
          'every': r.every,
          'until': ?(r.until == null ? null : _date(r.until!)),
          'times': ?r.times,
          'next': ?(r.next == null ? null : _date(r.next!)),
        },
    ],
    'transactions': [for (final t in txns) _txnToJson(t)],
    'meta': meta,
  };
  final Map<String, Object?> envelope;
  if (password == null || password.isEmpty) {
    envelope = {
      'format': backupFormat,
      'version': backupVersion,
      'info': info,
      'data': data,
    };
  } else {
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(password, salt, iterations);
    // Compress first: ciphertext does not compress.
    final box = await AesGcm.with256bits().encrypt(
      const GZipEncoder().encodeBytes(utf8.encode(jsonEncode(data))),
      secretKey: key,
      nonce: nonce,
    );
    envelope = {
      'format': backupFormat,
      'version': backupVersion,
      'info': info,
      'encryption': {
        'kdf': {
          'name': 'pbkdf2-hmac-sha256',
          'iterations': iterations,
          'salt': base64.encode(salt),
        },
        'cipher': {'name': 'aes-256-gcm', 'nonce': base64.encode(nonce)},
      },
      'payload': base64.encode(box.concatenation(nonce: false)),
    };
  }
  return Uint8List.fromList(
    const GZipEncoder().encodeBytes(utf8.encode(jsonEncode(envelope))),
  );
}

/// Reads the unencrypted summary of a backup without the password.
BackupInfo readBackupInfo(List<int> bytes) => _info(_envelope(bytes));

/// Decodes a backup. Throws [BackupException] for a wrong password or a
/// damaged or unsupported file.
Future<BackupContents> decodeBackup(List<int> bytes, {String? password}) async {
  final envelope = _envelope(bytes);
  final info = _info(envelope);
  final Object? data;
  if (!info.encrypted) {
    data = envelope['data'];
  } else {
    if (password == null || password.isEmpty) {
      throw BackupException('這個備份檔有密碼保護，請輸入密碼');
    }
    try {
      final enc = envelope['encryption'] as Map<String, Object?>;
      final kdf = enc['kdf'] as Map<String, Object?>;
      final cipher = enc['cipher'] as Map<String, Object?>;
      final key = await _deriveKey(
        password,
        base64.decode(kdf['salt'] as String),
        kdf['iterations'] as int,
      );
      final nonce = base64.decode(cipher['nonce'] as String);
      final box = SecretBox.fromConcatenation(
        [...nonce, ...base64.decode(envelope['payload'] as String)],
        nonceLength: nonce.length,
        macLength: AesGcm.aesGcmMac.macLength,
      );
      data = jsonDecode(
        utf8.decode(
          const GZipDecoder().decodeBytes(
            await AesGcm.with256bits().decrypt(box, secretKey: key),
          ),
        ),
      );
    } on SecretBoxAuthenticationError {
      throw BackupException('密碼錯誤');
    } on BackupException {
      rethrow;
    } catch (_) {
      throw BackupException('備份檔已損毀，無法解密');
    }
  }
  try {
    final (ledger, meta) = _ledgerFromJson(data as Map<String, Object?>);
    return BackupContents(info, ledger, meta);
  } on BackupException {
    rethrow;
  } catch (_) {
    throw BackupException('備份檔的內容不完整或已損毀');
  }
}

Future<SecretKey> _deriveKey(String password, List<int> salt, int iterations) =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

List<int> _randomBytes(int n) => SecretKeyData.random(length: n).bytes;

Map<String, Object?> _envelope(List<int> bytes) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(const GZipDecoder().decodeBytes(bytes)));
  } catch (_) {
    throw BackupException('這不是 Aura 的備份檔');
  }
  if (json is! Map<String, Object?> || json['format'] != backupFormat) {
    throw BackupException('這不是 Aura 的備份檔');
  }
  final version = json['version'];
  if (version is! int || version > backupVersion) {
    throw BackupException('這個備份檔來自比較新的 Aura 版本，請先更新 App');
  }
  return json;
}

BackupInfo _info(Map<String, Object?> envelope) {
  try {
    final info = envelope['info'] as Map<String, Object?>;
    return BackupInfo(
      createdAt: DateTime.parse(info['createdAt'] as String),
      accounts: info['accounts'] as int,
      transactions: info['transactions'] as int,
      encrypted: envelope.containsKey('encryption'),
      firstDate: _parseDate(info['firstDate']),
      lastDate: _parseDate(info['lastDate']),
    );
  } catch (_) {
    throw BackupException('備份檔的內容不完整或已損毀');
  }
}

(InMemoryLedger, Map<String, String>) _ledgerFromJson(Map<String, Object?> d) {
  List<Map<String, Object?>> list(String key) =>
      [for (final e in d[key] as List) e as Map<String, Object?>];
  final accounts = [for (final a in list('accounts')) _accountFromJson(a)];
  final categories = [for (final c in list('categories')) _categoryFromJson(c)];
  final projects = [
    for (final p in list('projects'))
      Project(id: p['id'] as String, name: p['name'] as String),
  ];
  final txns = [for (final t in list('transactions')) _txnFromJson(t)];
  // Budgets came later; older backups have none.
  final budgets = [
    for (final b in d['budgets'] as List? ?? const [])
      Budget(
        id: (b as Map)['id'] as String,
        categoryId: b['categoryId'] as String?,
        amount: Decimal.parse(b['amount'] as String),
      ),
  ];
  // So did recurring items.
  final recurrings = [
    for (final r in d['recurring'] as List? ?? const [])
      Recurring(
        id: (r as Map)['id'] as String,
        template: _txnFromJson(r['template'] as Map<String, Object?>),
        unit: RepeatUnit.values.byName(r['unit'] as String),
        every: r['every'] as int,
        until: _parseDate(r['until']),
        times: r['times'] as int?,
        next: _parseDate(r['next']),
      ),
  ];
  final ledger = InMemoryLedger(
    accounts: accounts,
    categories: categories,
    projects: projects,
    transactions: txns,
    budgets: budgets,
    recurrings: recurrings,
  );
  // Check integrity only, not today's naming rules: an old backup must
  // stay restorable even if the app has since become stricter.
  void unique(String what, Iterable<String> ids) {
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) throw BackupException('備份檔的內容不一致：$what重複（$id）');
    }
  }

  unique('帳戶', accounts.map((a) => a.id));
  unique('分類', categories.map((c) => c.id));
  unique('專案', projects.map((p) => p.id));
  unique('紀錄', txns.map((t) => t.id));
  unique('預算', budgets.map((b) => b.id));
  unique('週期收支', recurrings.map((r) => r.id));
  for (final r in recurrings) {
    try {
      checkTxn(ledger, r.template);
    } on ArgumentError catch (e) {
      throw BackupException('備份檔的內容不一致：週期收支${e.message}');
    }
  }
  for (final b in budgets) {
    if (b.categoryId != null && ledger.category(b.categoryId!) == null) {
      throw BackupException('備份檔的內容不一致：預算的分類不存在');
    }
  }
  for (final c in categories) {
    final parent = c.parentId == null ? null : ledger.category(c.parentId!);
    if (c.parentId != null && (parent == null || parent.kind != c.kind)) {
      throw BackupException('備份檔的內容不一致：分類「${c.name}」的主分類不存在');
    }
  }
  for (final t in txns) {
    try {
      checkTxn(ledger, t);
    } on ArgumentError catch (e) {
      throw BackupException('備份檔的內容不一致：${e.message}');
    }
  }
  final meta = {
    for (final e in (d['meta'] as Map? ?? const {}).entries) '${e.key}': '${e.value}',
  };
  return (ledger, meta);
}

Map<String, Object?> _accountToJson(Account a) => {
  'id': a.id,
  'name': a.name,
  'type': a.type.name,
  'currency': a.currency,
  if (a.archived) 'archived': true,
  if (a.hidden) 'hidden': true,
  if (a.anchor != null)
    'anchor': {'amount': a.anchor!.amount.toString(), 'date': _date(a.anchor!.date)},
};

Account _accountFromJson(Map<String, Object?> j) {
  final anchor = j['anchor'] as Map<String, Object?>?;
  return Account(
    id: j['id'] as String,
    name: j['name'] as String,
    type: AccountType.values.byName(j['type'] as String),
    currency: j['currency'] as String,
    archived: j['archived'] as bool? ?? false,
    hidden: j['hidden'] as bool? ?? false,
    anchor: anchor == null
        ? null
        : BalanceAnchor(
            amount: Decimal.parse(anchor['amount'] as String),
            date: _parseDate(anchor['date'])!,
          ),
  );
}

Map<String, Object?> _categoryToJson(Category c) => {
  'id': c.id,
  'kind': c.kind.name,
  'name': c.name,
  if (c.parentId != null) 'parentId': c.parentId,
};

Category _categoryFromJson(Map<String, Object?> j) => Category(
  id: j['id'] as String,
  kind: TxnKind.values.byName(j['kind'] as String),
  name: j['name'] as String,
  parentId: j['parentId'] as String?,
);

Map<String, Object?> _txnToJson(Txn t) => {
  'id': t.id,
  'kind': t.kind.name,
  'date': _date(t.date),
  'amount': t.amount.toString(),
  'baseAmount': t.baseAmount.toString(),
  'accountId': ?t.accountId,
  'toAccountId': ?t.toAccountId,
  'toAmount': ?t.toAmount?.toString(),
  'fxRate': ?t.fxRateDisplay,
  'categoryId': ?t.categoryId,
  'projectId': ?t.projectId,
  'note': ?t.note,
  'place': ?t.place,
  'createdAt': ?t.createdAt?.toIso8601String(),
  'feeOf': ?t.feeOfTxnId,
  'recurringId': ?t.recurringId,
  if (t.needsReview) 'needsReview': true,
  if (t.legacyRows.isNotEmpty) 'legacyRows': t.legacyRows,
  if (t.invoice case final i?)
    'invoice': {
      'number': i.number,
      'sellerTaxId': ?i.sellerTaxId,
      'sellerName': ?i.sellerName,
      'sellerAddress': ?i.sellerAddress,
      'carrier': ?i.carrier,
      'items': [
        for (final it in i.items)
          [it.name, it.quantity.toString(), it.amount.toString()],
      ],
    },
};

Txn _txnFromJson(Map<String, Object?> j) {
  Decimal? dec(String key) =>
      j[key] == null ? null : Decimal.parse(j[key] as String);
  final inv = j['invoice'] as Map<String, Object?>?;
  return Txn(
    id: j['id'] as String,
    kind: TxnKind.values.byName(j['kind'] as String),
    date: _parseDate(j['date'])!,
    amount: dec('amount')!,
    baseAmount: dec('baseAmount')!,
    accountId: j['accountId'] as String?,
    toAccountId: j['toAccountId'] as String?,
    toAmount: dec('toAmount'),
    fxRateDisplay: j['fxRate'] as String?,
    categoryId: j['categoryId'] as String?,
    projectId: j['projectId'] as String?,
    note: j['note'] as String?,
    place: j['place'] as String?,
    createdAt: j['createdAt'] == null ? null : DateTime.parse(j['createdAt'] as String),
    feeOfTxnId: j['feeOf'] as String?,
    recurringId: j['recurringId'] as String?,
    needsReview: j['needsReview'] as bool? ?? false,
    legacyRows: [
      for (final row in j['legacyRows'] as List? ?? const [])
        [for (final f in row as List) f as String],
    ],
    invoice: inv == null
        ? null
        : Invoice(
            number: inv['number'] as String,
            sellerTaxId: inv['sellerTaxId'] as String?,
            sellerName: inv['sellerName'] as String?,
            sellerAddress: inv['sellerAddress'] as String?,
            carrier: inv['carrier'] as String?,
            items: [
              for (final it in inv['items'] as List)
                InvoiceItem(
                  name: (it as List)[0] as String,
                  quantity: Decimal.parse(it[1] as String),
                  amount: Decimal.parse(it[2] as String),
                ),
            ],
          ),
  );
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _parseDate(Object? s) {
  if (s is! String) return null;
  final p = s.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}
