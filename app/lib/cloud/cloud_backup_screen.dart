import 'dart:typed_data';

import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../screens/dialogs.dart';
import 'cloud_backup.dart';
import 'cloud_target.dart';
import 'webdav.dart';

String _time(DateTime t) =>
    '${formatDate(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "aura-20260929-213000.aura" → its time, for listing cloud backups.
DateTime? _stampOf(String name) {
  final m = RegExp(r'aura-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})?').firstMatch(name);
  if (m == null) return null;
  int n(int i) => int.parse(m[i] ?? '0');
  return DateTime(n(1), n(2), n(3), n(4), n(5), n(6));
}

String _size(int? bytes) => bytes == null
    ? ''
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

class CloudBackupScreen extends StatefulWidget {
  const CloudBackupScreen({super.key, required this.app});

  final AppState app;

  @override
  State<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

class _CloudBackupScreenState extends State<CloudBackupScreen> {
  Future<List<CloudFile>>? _files;

  AppState get _app => widget.app;
  CloudBackup get _cloud => _app.cloud;

  @override
  void initState() {
    super.initState();
    if (_cloud.enabled) _reload();
  }

  void _reload() => setState(() {
    _files = _cloud.list();
  });

  /// Runs [work] behind a progress dialog; shows [CloudException]s.
  Future<T?> _busy<T>(String label, Future<T> Function() work) async {
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [const CircularProgressIndicator(), const SizedBox(width: 20), Expanded(child: Text(label))],
          ),
        ),
      ),
    );
    var open = true;
    void close() {
      if (open) navigator.pop();
      open = false;
    }

    try {
      return await work();
    } on CloudException catch (e) {
      close();
      if (mounted) await _tell('沒有成功', e.message);
      return null;
    } finally {
      close();
    }
  }

  Future<void> _tell(String title, String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
    ),
  );

  Future<void> _setUpGoogle() async {
    final email = await _busy('登入 Google…', () => _app.lock.whileAway(_cloud.google.connect));
    if (email == null || !mounted) return;
    await _finishSetup(CloudConfig(kind: CloudKind.googleDrive, account: email));
  }

  Future<void> _setUpWebDav() async {
    final result = await Navigator.push<(CloudConfig, String)>(
      context,
      MaterialPageRoute(builder: (_) => const WebDavSetupScreen()),
    );
    if (result == null || !mounted) return;
    await _finishSetup(result.$1, webdavPassword: result.$2);
  }

  Future<void> _finishSetup(CloudConfig target, {String? webdavPassword}) async {
    final password = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BackupPasswordScreen()),
    );
    if (password == null || !mounted) return;
    final ok = await _busy('檢查連線…', () async {
      await _cloud.enable(target, webdavPassword: webdavPassword, backupPassword: password);
      return true;
    });
    if (ok != true || !mounted) return;
    _reload();
    // A new phone: offer the old phone's data before backing up over it.
    final newer = await _busy('查看雲端上的備份…', () => _cloud.newerInCloud(_app.ledger.count()));
    if (!mounted) return;
    if (newer != null) {
      final (file, bytes, info) = newer;
      final restore = await confirm(
        context,
        title: '雲端上有比較多的資料',
        message:
            '${_time(_stampOf(file.name) ?? info.createdAt)} 的備份有 ${info.transactions} 筆紀錄，'
            '這支手機有 ${_app.ledger.count()} 筆。要用雲端的備份取代這支手機的資料嗎？',
        action: '還原',
      );
      if (restore && mounted) {
        await _restoreBytes(bytes, info, confirmFirst: false);
        return;
      }
    }
    if (mounted && _app.ledger.count() > 0) await _backupNow();
  }

  Future<void> _backupNow() async {
    final name = await _busy('備份到雲端…', _cloud.backupNow);
    if (name == null || !mounted) return;
    _reload();
    showMessage(context, '已備份 $name');
  }

  Future<void> _restore(CloudFile file) async {
    final bytes = await _busy('下載備份…', () => _cloud.download(file));
    if (bytes == null || !mounted) return;
    final BackupInfo info;
    try {
      info = readBackupInfo(bytes);
    } on BackupException catch (e) {
      await _tell('無法還原', e.message);
      return;
    }
    await _restoreBytes(bytes, info);
  }

  Future<void> _restoreBytes(Uint8List bytes, BackupInfo info, {bool confirmFirst = true}) async {
    if (confirmFirst &&
        !await confirm(
          context,
          title: '從雲端還原？',
          message:
              '這份備份有 ${info.transactions} 筆紀錄，會取代這支手機上目前的 ${_app.ledger.count()} 筆。'
              '還原前會自動在手機上保留一份快照。',
          action: '還原',
        )) {
      return;
    }
    String? password;
    while (mounted) {
      try {
        final restored = await _busy('還原中…', () => _cloud.restore(bytes, password: password));
        if (restored != null && mounted) showMessage(context, '已還原 ${restored.transactions} 筆紀錄');
        return;
      } on BackupException catch (e) {
        if (!mounted) return;
        // A backup made before the password was changed.
        password = await askText(
          context,
          title: '需要這份備份的密碼',
          label: '備份密碼',
          obscure: true,
          message: e.message,
        );
        if (password == null) return;
      }
    }
  }

  Future<void> _disable() async {
    if (!await confirm(
      context,
      title: '停用雲端備份？',
      message: '之後不會再自動備份，這支手機也會忘記密碼。雲端上已經有的備份會留著。',
      action: '停用',
    )) {
      return;
    }
    await _cloud.disable();
    setState(() => _files = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_cloud, _app]),
    builder: (context, _) =>
        Scaffold(appBar: AppBar(title: const Text('雲端備份')), body: _cloud.enabled ? _status(context) : _setup(context)),
  );

  Widget _setup(BuildContext context) {
    final theme = Theme.of(context);
    final google = _cloud.google.available;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '每天（或每週）打開 App 時，自動把加密過的備份存到你自己的雲端。'
          'Aura 沒有伺服器，資料只會在這支手機和你選的雲端之間。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Card.outlined(
          child: ListTile(
            key: const Key('cloudGoogle'),
            leading: const Icon(Icons.add_to_drive),
            title: const Text('Google 雲端硬碟'),
            subtitle: Text(
              google ? '存在「Aura 記帳備份」資料夾，App 只能看到自己建立的檔案' : '這個版本還沒有設定 Google 登入',
            ),
            enabled: google,
            trailing: const Icon(Icons.chevron_right),
            onTap: google ? _setUpGoogle : null,
          ),
        ),
        Card.outlined(
          child: ListTile(
            key: const Key('cloudWebdav'),
            leading: const Icon(Icons.dns_outlined),
            title: const Text('WebDAV'),
            subtitle: const Text('Nextcloud、Synology／QNAP NAS、Koofr、InfiniCloud 等'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _setUpWebDav,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'iCloud：可以在「備份與還原 → 建立備份檔」時選擇 iCloud Drive。',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final c = _cloud.config;
    final provider = c.kind == CloudKind.googleDrive ? 'Google 雲端硬碟' : 'WebDAV';
    final error = c.lastError;
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$provider・${c.account ?? ''}', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        error != null ? Icons.error_outline : Icons.cloud_done_outlined,
                        size: 20,
                        color: error != null ? theme.colorScheme.error : null,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error != null
                              ? '${_time(c.lastAttempt!)} 備份失敗：$error'
                              : c.lastSuccess == null
                              ? '還沒有備份過'
                              : '上次備份：${_time(c.lastSuccess!)}',
                          key: const Key('cloudStatus'),
                          style: error != null ? TextStyle(color: theme.colorScheme.error) : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('cloudBackupNow'),
            onPressed: _cloud.busy || _app.ledger.count() == 0 ? null : _backupNow,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(_cloud.busy ? '備份中…' : '立即備份'),
          ),
          const SizedBox(height: 24),
          Text('自動備份', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<CloudFrequency>(
            segments: [for (final f in CloudFrequency.values) ButtonSegment(value: f, label: Text(f.label))],
            selected: {c.frequency},
            onSelectionChanged: (s) => _cloud.setFrequency(s.single),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const Key('cloudKeep'),
            initialValue: c.keep,
            decoration: const InputDecoration(labelText: '雲端保留幾份', border: OutlineInputBorder()),
            items: [for (final n in const [5, 10, 20, 30]) DropdownMenuItem(value: n, child: Text('最近 $n 份'))],
            onChanged: (n) => _cloud.setKeep(n!),
          ),
          const SizedBox(height: 8),
          Text(
            '打開 App 或切回 App 時，如果到了該備份的時間就會自動備份。只會刪除 App 自己建立的舊備份。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Text('雲端上的備份', style: theme.textTheme.titleSmall),
          FutureBuilder<List<CloudFile>>(
            future: _files,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
              }
              if (snap.error case final CloudException e) {
                return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(e.message));
              }
              final files = snap.data ?? const <CloudFile>[];
              if (files.isEmpty) {
                return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('雲端上還沒有備份。'));
              }
              return Column(
                children: [
                  for (final f in files)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_outlined),
                      title: Text(switch (_stampOf(f.name)) {
                        final t? => _time(t),
                        _ => f.name,
                      }),
                      subtitle: Text(_size(f.size)),
                      trailing: TextButton(
                        key: Key('cloudRestore-${f.name}'),
                        onPressed: () => _restore(f),
                        child: const Text('還原'),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          OutlinedButton(key: const Key('cloudDisable'), onPressed: _disable, child: const Text('停用雲端備份')),
        ],
      ),
    );
  }
}

/// Server, account and folder for WebDAV. Pops (config, password).
class WebDavSetupScreen extends StatefulWidget {
  const WebDavSetupScreen({super.key});

  @override
  State<WebDavSetupScreen> createState() => _WebDavSetupScreenState();
}

class _WebDavSetupScreenState extends State<WebDavSetupScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: 'Aura');
  String? _error;

  @override
  void dispose() {
    for (final c in [_url, _user, _password, _folder]) {
      c.dispose();
    }
    super.dispose();
  }

  void _next() {
    final problem = WebDavTarget.checkUrl(_url.text) ??
        (_user.text.trim().isEmpty || _password.text.isEmpty ? '請輸入帳號和密碼' : null);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final url = _url.text.trim();
    Navigator.pop(context, (
      CloudConfig(
        kind: CloudKind.webdav,
        account: '${_user.text.trim()}@${Uri.parse(url).host}',
        webdavUrl: url,
        webdavUser: _user.text.trim(),
        webdavFolder: _folder.text.trim().isEmpty ? 'Aura' : _folder.text.trim(),
      ),
      _password.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('webdavUrl'),
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'WebDAV 網址', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Text(
            '例如：\n'
            'Nextcloud：https://你的網域/remote.php/dav/files/帳號\n'
            'Synology NAS：https://NAS 位址:5006\n'
            'Koofr：https://app.koofr.net/dav/Koofr\n'
            'InfiniCloud：https://（你的伺服器）.teracloud.jp/dav/',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('webdavUser'),
            controller: _user,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '帳號', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('webdavPassword'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密碼',
              helperText: '建議用服務提供的「應用程式密碼」，不要用主要密碼',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('webdavFolder'),
            controller: _folder,
            decoration: const InputDecoration(labelText: '資料夾', border: OutlineInputBorder()),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, key: const Key('webdavError'), style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton(key: const Key('webdavNext'), onPressed: _next, child: const Text('下一步')),
        ],
      ),
    );
  }
}

/// The password that encrypts cloud backups. Pops it.
class BackupPasswordScreen extends StatefulWidget {
  const BackupPasswordScreen({super.key});

  @override
  State<BackupPasswordScreen> createState() => _BackupPasswordScreenState();
}

class _BackupPasswordScreenState extends State<BackupPasswordScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

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

  bool get _ok => _password.text.length >= CloudBackup.minPasswordLength && _password.text == _confirm.text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('備份密碼')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '雲端上的備份一律用這個密碼加密（AES-256），雲端服務看不到內容。\n\n'
            '密碼會存在這支手機的安全儲存區，自動備份時不用再輸入。'
            '換手機要從雲端還原時，需要輸入同一個密碼，請記在安全的地方；忘記了就打不開這些備份。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('cloudPassword'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密碼（至少 ${CloudBackup.minPasswordLength} 個字）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('cloudPasswordConfirm'),
            controller: _confirm,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '再輸入一次',
              border: const OutlineInputBorder(),
              errorText: _confirm.text.isNotEmpty && _confirm.text != _password.text ? '兩次輸入的密碼不同' : null,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('cloudEnable'),
            onPressed: _ok ? () => Navigator.pop(context, _password.text) : null,
            child: const Text('開始使用'),
          ),
        ],
      ),
    );
  }
}
