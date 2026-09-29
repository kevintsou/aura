import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'dialogs.dart';

/// Main categories of one kind: add, reorder by dragging, open to edit.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key, required this.app});

  final AppState app;

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  var _kind = TxnKind.expense;

  AppState get _app => widget.app;

  List<Category> _children(String? parentId) => [
    for (final c in _app.ledger.categories)
      if (c.kind == _kind && c.parentId == parentId) c,
  ];

  Future<void> _add() async {
    final name = await askText(context, title: '新增主分類', label: '名稱');
    if (name == null || !mounted) return;
    final error = _app.write(
      (l) => l.addCategory(Category(id: newId('c'), kind: _kind, name: name)),
    );
    if (error != null) showMessage(context, error);
  }

  void _reorder(List<Category> mains, int from, int to) {
    final ids = [for (final c in mains) c.id];
    ids.insert(to, ids.removeAt(from));
    _app.write((l) => l.reorderCategories(ids));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _app,
    builder: (context, _) {
      final mains = _children(null);
      return Scaffold(
        appBar: AppBar(title: const Text('分類管理')),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null, // several screens have one; skip the hero animation
          key: const Key('addMainCategory'),
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('新增主分類'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SegmentedButton<TxnKind>(
                segments: const [
                  ButtonSegment(value: TxnKind.expense, label: Text('支出')),
                  ButtonSegment(value: TxnKind.income, label: Text('收入')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.single),
              ),
            ),
            Expanded(
              child: ReorderableListView(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 80),
                onReorderItem: (from, to) => _reorder(mains, from, to),
                children: [
                  for (final (i, c) in mains.indexed)
                    ListTile(
                      key: ValueKey(c.id),
                      title: Text(c.name),
                      subtitle: Text(_children(c.id).map((s) => s.name).join('、')),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Icon(Icons.drag_handle),
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CategoryDetailScreen(app: _app, mainId: c.id),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// One main category: rename or delete it, and manage its subcategories.
class CategoryDetailScreen extends StatelessWidget {
  const CategoryDetailScreen({super.key, required this.app, required this.mainId});

  final AppState app;
  final String mainId;

  Future<void> _rename(BuildContext context, Category c) async {
    final name = await askText(context, title: '重新命名', label: '名稱', initial: c.name);
    if (name == null || name == c.name || !context.mounted) return;
    final error = app.write((l) => l.renameCategory(c.id, name));
    if (error != null) showMessage(context, error);
  }

  Future<void> _delete(BuildContext context, Category c, {bool isMain = false}) async {
    final ok = await confirm(
      context,
      title: '刪除「${c.name}」？',
      message: isMain ? '底下的子分類也會一起刪除。' : null,
      action: '刪除',
    );
    if (!ok || !context.mounted) return;
    final error = app.write((l) => l.deleteCategory(c.id));
    if (error != null) {
      showMessage(context, error);
    } else if (isMain) {
      Navigator.pop(context);
    }
  }

  Future<void> _addSub(BuildContext context, Category main) async {
    final name = await askText(context, title: '新增子分類', label: '名稱');
    if (name == null || !context.mounted) return;
    final error = app.write(
      (l) => l.addCategory(
        Category(id: newId('c'), kind: main.kind, name: name, parentId: main.id),
      ),
    );
    if (error != null) showMessage(context, error);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final main = app.ledger.category(mainId);
      if (main == null) return const Scaffold();
      final subs = [for (final c in app.ledger.categories) if (c.parentId == mainId) c];
      return Scaffold(
        appBar: AppBar(
          title: Text(main.name),
          actions: [
            IconButton(
              key: const Key('renameMain'),
              tooltip: '重新命名',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(context, main),
            ),
            IconButton(
              key: const Key('deleteMain'),
              tooltip: '刪除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, main, isMain: true),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: null, // several screens have one; skip the hero animation
          key: const Key('addSubCategory'),
          onPressed: () => _addSub(context, main),
          icon: const Icon(Icons.add),
          label: const Text('新增子分類'),
        ),
        body: subs.isEmpty
            ? const Center(child: Text('沒有子分類；記帳時會直接選這個主分類。'))
            : ReorderableListView(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 80),
                onReorderItem: (from, to) {
                  final ids = [for (final c in subs) c.id];
                  ids.insert(to, ids.removeAt(from));
                  app.write((l) => l.reorderCategories(ids));
                },
                children: [
                  for (final (i, c) in subs.indexed)
                    ListTile(
                      key: ValueKey(c.id),
                      title: Text(c.name),
                      onTap: () => _rename(context, c),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '刪除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, c),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_handle),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      );
    },
  );
}
