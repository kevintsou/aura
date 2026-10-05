import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../lock/lock_settings_screen.dart';
import 'ai_settings_screen.dart';
import 'backup_screen.dart';
import 'budgets_screen.dart';
import 'categories_screen.dart';
import 'dialogs.dart';
import 'export_action.dart';
import 'import_action.dart';
import 'recurring_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([app, app.lock]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('佈景主題'),
            trailing: DropdownButton<ThemeMode>(
              key: const Key('themeMode'),
              value: app.themeMode,
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('跟隨系統')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('淺色')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
              ],
              onChanged: (mode) async {
                if (mode == null) return;
                try {
                  await app.setThemeMode(mode);
                } on Object {
                  if (context.mounted) showMessage(context, '無法儲存佈景主題，請再試一次');
                }
              },
            ),
          ),
          ListTile(
            key: const Key('aiSettings'),
            leading: const Icon(Icons.auto_awesome),
            title: const Text('AI 連線'),
            subtitle: Text(
              app.aiReady
                  ? '${app.aiConfig.preset.label} · ${app.aiConfig.model}'
                  : '尚未設定：接上 OpenAI 或你自己的 Agent',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AiSettingsScreen(app: app)),
            ),
          ),
          ListTile(
            key: const Key('backupSettings'),
            leading: Icon(
              app.backupOverdue ? Icons.warning_amber : Icons.backup_outlined,
              color: app.backupOverdue
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            title: const Text('備份與還原'),
            subtitle: Text(
              app.lastBackupAt == null
                  ? '還沒有備份檔'
                  : '上次備份：${formatDate(app.lastBackupAt!)}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BackupScreen(app: app)),
            ),
          ),
          ListTile(
            key: const Key('appLock'),
            leading: const Icon(Icons.lock_outline),
            title: const Text('App 鎖'),
            subtitle: Text(app.lock.enabled ? '已開啟' : '用 PIN 碼或指紋保護帳本'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LockSettingsScreen(lock: app.lock),
              ),
            ),
          ),
          SwitchListTile(
            key: const Key('recordLocation'),
            secondary: const Icon(Icons.place_outlined),
            title: const Text('記帳時記錄位置'),
            subtitle: const Text('新增的收入和支出記下當時的位置。只存在這台手機和你的備份裡，不會送給 AI'),
            value: app.recordLocation,
            onChanged: (on) async {
              final problem = await app.setRecordLocation(on);
              if (problem != null && context.mounted) {
                showMessage(context, problem);
              }
            },
          ),
          ListTile(
            key: const Key('manageRecurring'),
            leading: const Icon(Icons.event_repeat),
            title: const Text('週期收支'),
            subtitle: Text(
              app.ledger.recurrings.isEmpty
                  ? '房租、薪水、訂閱、分期，到期自動記帳'
                  : '${app.ledger.recurrings.length} 個週期收支',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => RecurringScreen(app: app)),
            ),
          ),
          ListTile(
            key: const Key('manageBudgets'),
            leading: const Icon(Icons.savings_outlined),
            title: const Text('預算'),
            subtitle: Text(
              app.ledger.budgets.isEmpty
                  ? '設定每月總預算或分類預算'
                  : '${app.ledger.budgets.length} 個預算',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BudgetsScreen(app: app)),
            ),
          ),
          ListTile(
            key: const Key('manageCategories'),
            leading: const Icon(Icons.category_outlined),
            title: const Text('分類管理'),
            subtitle: const Text('新增、改名、刪除、調整順序'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => CategoriesScreen(app: app)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('匯入 CSV'),
            subtitle: Text(app.importedFileName ?? '把舊的記帳紀錄搬過來'),
            onTap: () => importCwmoneyFile(context, app),
          ),
          ListTile(
            key: const Key('exportCwmoney'),
            leading: const Icon(Icons.ios_share),
            title: const Text('匯出 CSV'),
            subtitle: const Text('可以用 Excel 開'),
            enabled: app.ledger.count() > 0,
            onTap: () => exportCwmoneyFile(context, app),
          ),
          const Divider(),
          const AboutListTile(
            icon: Icon(Icons.info_outline),
            applicationName: 'Aura 記帳',
            applicationVersion: '0.1.0',
            aboutBoxChildren: [Text('免費的記帳 App。AI 分析使用你自己的 API。')],
          ),
        ],
      ),
    ),
  );
}
