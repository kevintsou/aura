import 'dart:typed_data';

import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../cloud/cloud_backup.dart';
import '../cloud/cloud_backup_screen.dart';
import '../format.dart';
import '../services/snapshot_store.dart';
import 'dialogs.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.app});

  final AppState app;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late Future<List<Snapshot>> _snapshots;

  AppState get _app => widget.app;

  @override
  void initState() {
    super.initState();
    _snapshots = _app.snapshots.list();
  }

  void _reloadSnapshots() => setState(() {
    _snapshots = _app.snapshots.list();
  });

  Future<void> _export() async {
    final password = await showDialog<_PasswordChoice>(
      context: context,
      builder: (_) => const _ExportDialog(),
    );
    if (password == null || !mounted) return;
    final name = await _busy('建立備份中…', () => _app.exportBackup(password: password.value));
    if (!mounted || name == null) return;
    showMessage(context, '已儲存 $name');
  }

  Future<void> _restoreFromFile() async {
    final picked = await _app.lock.whileAway(_app.files.pick);
    if (picked == null || !mounted) return;
    await _restore(picked.bytes, source: picked.name);
  }

  Future<void> _restoreSnapshot(Snapshot s) async {
    final bytes = await _app.snapshots.read(s);
    if (!mounted) return;
    await _restore(bytes, source: '手機上的自動備份（${_formatTime(s.at)}）');
  }

  Future<void> _restore(Uint8List bytes, {required String source}) async {
    final BackupInfo info;
    try {
      info = readBackupInfo(bytes);
    } on BackupException catch (e) {
      showMessage(context, e.message);
      return;
    }
    final password = await showDialog<_PasswordChoice>(
      context: context,
      builder: (_) => _RestoreDialog(info: info, source: source, current: _app.ledger.count()),
    );
    if (password == null || !mounted) return;
    try {
      await _busy('還原中…', () => _app.restoreBackup(bytes, password: password.value));
    } on BackupException catch (e) {
      if (mounted) showMessage(context, e.message);
      return;
    }
    if (!mounted) return;
    _reloadSnapshots();
    showMessage(context, '已還原 ${info.transactions} 筆紀錄');
  }

  /// Runs [work] behind a blocking progress dialog.
  Future<T> _busy<T>(String label, Future<T> Function() work) async {
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Text(label),
            ],
          ),
        ),
      ),
    );
    try {
      return await work();
    } finally {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_app, _app.cloud]),
      builder: (context, _) {
        final last = _app.lastBackupAt;
        return Scaffold(
          appBar: AppBar(title: const Text('備份與還原')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card.outlined(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        _app.backupOverdue ? Icons.warning_amber : Icons.cloud_done_outlined,
                        color: _app.backupOverdue ? theme.colorScheme.error : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          last == null
                              ? '還沒有建立過備份檔。資料只存在這支手機上，換手機或刪除 App 就會不見。'
                              : '上次建立備份檔：${_formatTime(last)}',
                          key: const Key('lastBackup'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('exportBackup'),
                onPressed: _export,
                icon: const Icon(Icons.save_alt),
                label: const Text('建立備份檔'),
              ),
              const SizedBox(height: 8),
              Text(
                '備份檔包含所有帳戶、分類、紀錄和餘額設定（不含 AI 的 API 金鑰）。'
                '建議存到 Google Drive 或 iCloud Drive，換手機時從這裡還原。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('restoreBackup'),
                onPressed: _restoreFromFile,
                icon: const Icon(Icons.settings_backup_restore),
                label: const Text('從備份檔還原'),
              ),
              const SizedBox(height: 24),
              Card.outlined(
                margin: EdgeInsets.zero,
                child: ListTile(
                  key: const Key('openCloudBackup'),
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('雲端備份'),
                  subtitle: Text(switch (_app.cloud.config) {
                    CloudConfig(kind: null) => '自動加密備份到 Google 雲端硬碟或 WebDAV',
                    CloudConfig(lastError: final String e) => '上次備份失敗：$e',
                    CloudConfig(lastSuccess: final DateTime t) => '上次雲端備份：${_formatTime(t)}',
                    _ => '已開啟，還沒有備份過',
                  }),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => CloudBackupScreen(app: _app)),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text('手機上的自動備份', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                '每天第一次打開 App、匯入或還原之前會自動保留一份，最多 ${SnapshotStore.keep} 份。'
                '只存在這支手機，用來救回操作失誤；換手機請用上面的備份檔。',
                style: theme.textTheme.bodySmall,
              ),
              FutureBuilder(
                future: _snapshots,
                builder: (context, snap) {
                  final items = snap.data ?? const <Snapshot>[];
                  if (items.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('目前沒有自動備份。'),
                    );
                  }
                  return Column(
                    children: [
                      for (final s in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history),
                          title: Text(_formatTime(s.at)),
                          subtitle: Text(_reasonLabel(s.reason)),
                          trailing: TextButton(
                            onPressed: () => _restoreSnapshot(s),
                            child: const Text('還原'),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

String _formatTime(DateTime t) =>
    '${formatDate(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _reasonLabel(SnapshotReason r) => switch (r) {
  SnapshotReason.daily => '每日自動備份',
  SnapshotReason.beforeImport => '匯入 CSV 之前',
  SnapshotReason.beforeRestore => '還原備份之前',
};

/// The password chosen in a dialog; null [value] means none.
class _PasswordChoice {
  const _PasswordChoice(this.value);
  final String? value;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  var _protect = true;

  @override
  void initState() {
    super.initState();
    for (final c in [_password, _confirm]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _valid =>
      !_protect || (_password.text.length >= 4 && _password.text == _confirm.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('建立備份檔'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('protectBackup'),
            contentPadding: EdgeInsets.zero,
            title: const Text('用密碼保護'),
            subtitle: const Text('備份檔上傳到雲端時，別人拿到也打不開'),
            value: _protect,
            onChanged: (v) => setState(() => _protect = v),
          ),
          if (_protect) ...[
            TextField(
              key: const Key('backupPassword'),
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密碼（至少 4 個字）'),
            ),
            TextField(
              key: const Key('backupPasswordConfirm'),
              controller: _confirm,
              obscureText: true,
              decoration: InputDecoration(
                labelText: '再輸入一次',
                errorText: _confirm.text.isNotEmpty && _confirm.text != _password.text
                    ? '兩次輸入的密碼不同'
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '忘記密碼就無法還原，Aura 也沒辦法幫你找回。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        key: const Key('confirmExport'),
        onPressed: _valid
            ? () => Navigator.pop(context, _PasswordChoice(_protect ? _password.text : null))
            : null,
        child: const Text('建立'),
      ),
    ],
  );
}

class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog({required this.info, required this.source, required this.current});

  final BackupInfo info;
  final String source;
  final int current;

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final range = i.firstDate == null
        ? ''
        : '\n期間：${formatDate(i.firstDate!)} – ${formatDate(i.lastDate!)}';
    return AlertDialog(
      title: const Text('還原這個備份？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.source}\n\n'
              '建立時間：${_formatTime(i.createdAt)}\n'
              '帳戶 ${i.accounts} 個、紀錄 ${i.transactions} 筆$range',
              key: const Key('restoreSummary'),
            ),
            const SizedBox(height: 12),
            Text(
              '目前的 ${widget.current} 筆紀錄會被取代。還原前會先在手機上自動保留一份，需要時可以救回。',
            ),
            if (i.encrypted) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('restorePassword'),
                controller: _password,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: '備份檔密碼'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          key: const Key('confirmRestore'),
          onPressed: i.encrypted && _password.text.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _PasswordChoice(i.encrypted ? _password.text : null),
                ),
          child: const Text('還原'),
        ),
      ],
    );
  }
}
