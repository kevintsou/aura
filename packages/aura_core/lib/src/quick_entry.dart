import 'package:decimal/decimal.dart';

import 'ledger.dart';
import 'model.dart';

/// What a note usually comes with: the category and account used most
/// often with it lately, and the latest amount.
class UsualEntry {
  const UsualEntry({
    required this.note,
    required this.kind,
    required this.categoryId,
    required this.accountId,
    required this.amount,
    required this.times,
  });

  final String note;
  final TxnKind kind;
  final String? categoryId;
  final String? accountId;

  /// The latest amount, in the account's currency.
  final Decimal amount;

  /// How many recent records had this note.
  final int times;
}

/// Records looked at for suggestions: recent ones are what people repeat.
const _recent = 1000;

String _key(String s) => s.trim().toLowerCase();

/// The usual entry for [note] among the latest records of [kind] (any
/// income or expense when null), or null when it was never used.
UsualEntry? usualFor(LedgerReader ledger, String note, {TxnKind? kind}) {
  final k = _key(note);
  if (k.isEmpty) return null;
  final kinds = kind == null ? const {TxnKind.expense, TxnKind.income} : {kind};
  final same = [
    for (final t in ledger.transactions(TxnFilter(keyword: note.trim(), kinds: kinds, searchInvoiceItems: false), 0, 200))
      if (t.note != null && _key(t.note!) == k) t,
  ].take(20).toList();
  if (same.isEmpty) return null;
  // Newest first, so on a tie the more recent one wins.
  T? mostCommon<T>(Iterable<T?> xs) {
    final counts = <T, int>{};
    for (final x in xs) {
      if (x != null) counts[x] = (counts[x] ?? 0) + 1;
    }
    T? best;
    for (final x in xs) {
      if (x != null && (best == null || counts[x]! > counts[best]!)) best = x;
    }
    return best;
  }

  final latest = same.first;
  final kindUsed = mostCommon(same.map((t) => t.kind))!;
  final ofKind = [for (final t in same) if (t.kind == kindUsed) t];
  return UsualEntry(
    note: latest.note!.trim(),
    kind: kindUsed,
    categoryId: mostCommon(ofKind.map((t) => t.categoryId)),
    accountId: mostCommon(ofKind.map((t) => t.accountId)),
    amount: ofKind.first.amount,
    times: same.length,
  );
}

/// Notes used lately that contain [typed], most used first: for
/// completing what the user starts typing.
List<String> recentNotes(LedgerReader ledger, String typed, {TxnKind? kind, int limit = 5}) {
  final k = _key(typed);
  if (k.isEmpty) return const [];
  final counts = <String, int>{};
  final order = <String, int>{};
  final kinds = kind == null ? const {TxnKind.expense, TxnKind.income} : {kind};
  for (final (i, t) in ledger.transactions(TxnFilter(kinds: kinds), 0, _recent).indexed) {
    final note = t.note?.trim();
    if (note == null || note.isEmpty || note.contains('\n')) continue;
    counts[note] = (counts[note] ?? 0) + 1;
    order.putIfAbsent(note, () => i);
  }
  final matches = [
    for (final n in counts.keys)
      if (n.toLowerCase().contains(k) && n.toLowerCase() != k) n,
  ]..sort((a, b) {
      // Starting with what was typed first, then the most used, then the newest.
      final starts = (b.toLowerCase().startsWith(k) ? 1 : 0) - (a.toLowerCase().startsWith(k) ? 1 : 0);
      if (starts != 0) return starts;
      final c = counts[b]! - counts[a]!;
      return c != 0 ? c : order[a]! - order[b]!;
    });
  return matches.take(limit).toList();
}

/// A new record like [t], for today: same kind, accounts, amounts,
/// category, project and note; not its invoice, photos, place, position
/// or source rows.
Txn copyOfTxn(Txn t, {required String id, required DateTime date, required DateTime createdAt}) => Txn(
  id: id,
  kind: t.kind,
  date: DateTime(date.year, date.month, date.day),
  accountId: t.accountId,
  toAccountId: t.toAccountId,
  amount: t.amount,
  toAmount: t.toAmount,
  baseAmount: t.baseAmount,
  fxRateDisplay: t.fxRateDisplay,
  categoryId: t.categoryId,
  projectId: t.projectId,
  note: t.note,
  createdAt: createdAt,
);
