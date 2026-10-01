import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/reminders.dart';
import '../format.dart';
import '../lock/lock_settings_screen.dart';
import 'ai_settings_screen.dart';
import 'backup_screen.dart';
import 'budgets_screen.dart';
import 'categories_screen.dart';
import 'dialogs.dart';
import 'privacy_screen.dart';
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
              color: app.backupOverdue ? Theme.of(context).colorScheme.error : null,
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
              MaterialPageRoute(builder: (_) => LockSettingsScreen(lock: app.lock)),
            ),
          ),
          _ReminderTile(app: app),
          SwitchListTile(
            key: const Key('recordLocation'),
            secondary: const Icon(Icons.place_outlined),
            title: const Text('記帳時記錄位置'),
            subtitle: const Text('新增的收入和支出記下當時的位置。只存在這台手機和你的備份裡，不會送給 AI'),
            value: app.recordLocation,
            onChanged: (on) async {
              final problem = await app.setRecordLocation(on);
              if (problem != null && context.mounted) showMessage(context, problem);
            },
          ),
          ListTile(
            key: const Key('manageRecurring'),
            leading: const Icon(Icons.event_repeat),
            title: const Text('週期收支'),
            subtitle: Text(
              app.ledger.recurrings.isEmpty ? '房租、薪水、訂閱、分期，到期自動記帳' : '${app.ledger.recurrings.length} 個週期收支',
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
              app.ledger.budgets.isEmpty ? '設定每月總預算或分類預算' : '${app.ledger.budgets.length} 個預算',
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
            title: const Text('匯入 CWMoney CSV'),
            subtitle: Text(app.importedFileName ?? 'CWMoney 經典版匯出的 CSV'),
            onTap: () => importCwmoneyFile(context, app),
          ),
          ListTile(
            key: const Key('exportCwmoney'),
            leading: const Icon(Icons.ios_share),
            title: const Text('匯出 CWMoney CSV'),
            subtitle: const Text('CWMoney 經典版的格式，也可以用 Excel 開'),
            enabled: app.ledger.count() > 0,
            onTap: () => exportCwmoneyFile(context, app),
          ),
          const Divider(),
          ListTile(
            key: const Key('privacyPolicy'),
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('隱私權政策'),
            subtitle: const Text('資料存在哪裡、什麼時候會離開手機'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen())),
          ),
          const AboutListTile(
            icon: Icon(Icons.info_outline),
            applicationName: 'Aura 記帳',
            applicationVersion: '0.1.0',
            aboutBoxChildren: [
              Text('免費的記帳 App。相容 CWMoney，AI 分析使用你自己的 API。'),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 每日記帳提醒: on or off, and at what time.
class _ReminderTile extends StatelessWidget {
  const _ReminderTile({required this.app});
  final AppState app;

  static String _label(ReminderTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(BuildContext context, ReminderTime? current) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current?.hour ?? 21, minute: current?.minute ?? 0),
      helpText: '每天幾點提醒',
    );
    if (picked == null || !context.mounted) return;
    final problem = await app.setReminder((hour: picked.hour, minute: picked.minute));
    if (problem != null && context.mounted) showMessage(context, problem);
  }

  @override
  Widget build(BuildContext context) {
    final at = app.reminderTime;
    return ListTile(
      key: const Key('reminder'),
      leading: const Icon(Icons.notifications_outlined),
      title: const Text('每日記帳提醒'),
      subtitle: Text(at == null ? '在你設定的時間提醒記帳' : '每天 ${_label(at)}，當天記過帳就不提醒'),
      onTap: () => _pick(context, at),
      trailing: Switch(
        key: const Key('reminderSwitch'),
        value: at != null,
        onChanged: (on) async {
          if (on) return _pick(context, at);
          await app.setReminder(null);
        },
      ),
    );
  }
}
