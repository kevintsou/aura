import 'package:flutter/material.dart';

import '../app_state.dart';
import 'ai_settings_screen.dart';
import 'categories_screen.dart';
import 'import_action.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
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
          const Divider(),
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
