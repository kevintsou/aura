import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'screens/accounts_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/transactions_screen.dart';
import 'services/ai_settings_store.dart';
import 'services/ledger_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState(
    ledger: await openLedgerStore(),
    settings: DeviceAiSettingsStore(),
  );
  await app.load();
  runApp(AuraApp(app: app));
}

class AuraApp extends StatelessWidget {
  const AuraApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3B6E8F),
        brightness: b,
      ),
    );
    return MaterialApp(
      title: 'Aura 記帳',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: HomeShell(app: app),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app});

  final AppState app;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _tab,
      children: [
        TransactionsScreen(app: widget.app),
        AccountsScreen(app: widget.app),
        AssistantScreen(app: widget.app),
        SettingsScreen(app: widget.app),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: '紀錄'),
        NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: '帳戶'),
        NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'AI 助理'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: '設定'),
      ],
    ),
  );
}
