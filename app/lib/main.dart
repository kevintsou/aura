import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'cloud/cloud_backup.dart';
import 'lock/app_lock.dart';
import 'lock/lock_screen.dart';
import 'screens/accounts_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/transactions_screen.dart';
import 'services/ai_settings_store.dart';
import 'services/ledger_store.dart';
import 'services/snapshot_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final lock = AppLock(store: DeviceLockStore(), biometrics: DeviceBiometrics());
  // Before the first frame, so a locked app never shows its data.
  await lock.load();
  final app = AppState(
    ledger: await openLedgerStore(),
    settings: DeviceAiSettingsStore(),
    snapshots: await openSnapshotStore(),
    lock: lock,
    cloudStore: DeviceCloudSettingsStore(),
  );
  await app.load();
  // In the background: a slow snapshot must not delay the first frame.
  unawaited(app.dailySnapshot());
  runApp(AuraApp(app: app));
}

class AuraApp extends StatelessWidget {
  const AuraApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6E8F), brightness: b),
    );
    return MaterialApp(
      title: 'Aura 記帳',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => LockGate(lock: app.lock, child: child!),
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
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Record what came due while the app was closed or in the background,
    // and back up to the cloud when a backup is due.
    _lifecycle = AppLifecycleListener(onResume: _onForeground);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onForeground());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _onForeground() {
    if (!mounted) return;
    unawaited(widget.app.cloud.runIfDue());
    final run = widget.app.runRecurring();
    final messages = [
      if (run.recorded.isNotEmpty) '已自動記入 ${run.recorded.length} 筆週期收支',
      if (run.problems.isNotEmpty) '有 ${run.problems.length} 個週期收支無法記帳，請到「設定 → 週期收支」檢查',
    ];
    if (messages.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(messages.join('\n'))));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.app.tab,
    builder: (context, tab, _) => Scaffold(
      body: IndexedStack(
        index: tab,
        children: [
          TransactionsScreen(app: widget.app),
          ReportsScreen(app: widget.app),
          AccountsScreen(app: widget.app),
          AssistantScreen(app: widget.app),
          SettingsScreen(app: widget.app),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => widget.app.tab.value = i,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: '紀錄'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), label: '報表'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: '帳戶'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'AI 助理'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '設定'),
        ],
      ),
    ),
  );
}
