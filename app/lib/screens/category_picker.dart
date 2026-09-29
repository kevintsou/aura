import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

/// Picks a category of [kind]: every main category is a heading with its
/// subcategories as chips, so any choice is one tap away. A main category
/// without subcategories is itself selectable; with [mainsSelectable],
/// every main category is (for choices that cover its subcategories).
/// [disabledIds] are shown but cannot be picked.
Future<String?> pickCategory(
  BuildContext context, {
  required LedgerReader ledger,
  required TxnKind kind,
  String? selectedId,
  bool mainsSelectable = false,
  Set<String> disabledIds = const {},
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    final mains = ledger.categories
        .where((c) => c.kind == kind && c.parentId == null)
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          if (mains.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('還沒有分類，請到「設定 → 分類管理」新增。'),
            ),
          for (final main in mains) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(main.name, style: Theme.of(context).textTheme.titleSmall),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in [
                  if (mainsSelectable && _hasSubs(ledger, main)) main,
                  ..._selectable(ledger, main),
                ])
                  ChoiceChip(
                    label: Text(c.id == main.id && _hasSubs(ledger, main) ? '整個${c.name}' : c.name),
                    selected: c.id == selectedId,
                    onSelected: disabledIds.contains(c.id) ? null : (_) => Navigator.pop(context, c.id),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  },
);

bool _hasSubs(LedgerReader ledger, Category main) => ledger.categories.any((c) => c.parentId == main.id);

List<Category> _selectable(LedgerReader ledger, Category main) {
  final subs = [for (final c in ledger.categories) if (c.parentId == main.id) c];
  return subs.isEmpty ? [main] : subs;
}

/// `主分類 · 子分類`, or just the name of a main category.
String categoryLabel(LedgerReader ledger, String? id) {
  final leaf = id == null ? null : ledger.category(id);
  if (leaf == null) return '未分類';
  final parent = leaf.parentId == null ? null : ledger.category(leaf.parentId!);
  return parent == null ? leaf.name : '${parent.name} · ${leaf.name}';
}

/// The category a new record of [kind] starts with: the last one used,
/// else the first selectable one.
String? defaultCategoryId(LedgerReader ledger, TxnKind kind, String? lastUsed) {
  if (lastUsed != null && ledger.category(lastUsed)?.kind == kind) {
    return lastUsed;
  }
  for (final main in ledger.categories) {
    if (main.kind == kind && main.parentId == null) {
      return _selectable(ledger, main).first.id;
    }
  }
  return null;
}
