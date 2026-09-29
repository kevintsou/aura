import 'package:flutter/material.dart';

import 'app_lock.dart';
import 'lock_screen.dart';

/// Turn the lock on or off, change the PIN, biometrics and timeout.
class LockSettingsScreen extends StatelessWidget {
  const LockSettingsScreen({super.key, required this.lock});

  final AppLock lock;

  Future<void> _turnOn(BuildContext context) async {
    final pin = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const PinSetupScreen()));
    if (pin != null) await lock.setPin(pin);
  }

  Future<void> _turnOff(BuildContext context) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PinCheckScreen(lock: lock, title: '關閉 App 鎖', check: lock.disable),
      ),
    );
  }

  Future<void> _changePin(BuildContext context) async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PinCheckScreen(lock: lock, title: '變更 PIN 碼', check: lock.check),
      ),
    );
    if (ok != true || !context.mounted) return;
    final pin = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const PinSetupScreen()));
    if (pin != null) await lock.setPin(pin);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: lock,
    builder: (context, _) {
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(title: const Text('App 鎖')),
        body: ListView(
          children: [
            SwitchListTile(
              key: const Key('lockSwitch'),
              title: const Text('開啟 App 鎖'),
              subtitle: const Text('打開 App 時要輸入 PIN 碼'),
              value: lock.enabled,
              onChanged: (on) => on ? _turnOn(context) : _turnOff(context),
            ),
            if (lock.enabled) ...[
              ListTile(
                key: const Key('changePin'),
                title: const Text('變更 PIN 碼'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _changePin(context),
              ),
              if (lock.biometricsAvailable)
                SwitchListTile(
                  key: const Key('biometricsSwitch'),
                  title: const Text('用指紋或臉部解鎖'),
                  subtitle: const Text('不方便時一樣可以輸入 PIN 碼'),
                  value: lock.biometricsEnabled,
                  onChanged: lock.setBiometrics,
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('離開 App 多久後要重新解鎖', style: theme.textTheme.titleSmall),
              ),
              RadioGroup<LockTimeout>(
                groupValue: lock.timeout,
                onChanged: (t) => lock.setTimeout(t!),
                child: Column(
                  children: [
                    for (final t in LockTimeout.values)
                      RadioListTile<LockTimeout>(key: Key('timeout-${t.name}'), title: Text(t.label), value: t),
                  ],
                ),
              ),
            ],
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'App 鎖可以擋住拿到你手機的人打開 Aura 看帳。開著時，切換 App 的畫面也不會露出金額。\n\n'
                'PIN 碼只以加密雜湊存在手機的安全儲存區，連續輸錯 ${AppLock.freeTries} 次後要等一段時間才能再試。'
                'PIN 碼忘記了沒辦法找回，只能重新安裝 App 再用備份檔還原，所以請定期備份。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Picks a new PIN: enter it, then once more to confirm. Pops the PIN.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String? _first;
  String? _problem;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('設定 PIN 碼')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PinEntry(
          title: _first == null ? '輸入 ${AppLock.minPinLength} 到 ${AppLock.maxPinLength} 位數字' : '再輸入一次',
          subtitle: _problem,
          length: _first?.length,
          onSubmit: (pin) async {
            if (_first == null) {
              setState(() {
                _first = pin;
                _problem = null;
              });
              return null;
            }
            if (pin != _first) {
              setState(() {
                _first = null;
                _problem = '兩次輸入不一樣，請重新設定';
              });
              return null;
            }
            Navigator.pop(context, pin);
            return null;
          },
        ),
      ),
    ),
  );
}

/// Asks for the current PIN and runs [check] with it; pops true once it
/// passes.
class PinCheckScreen extends StatelessWidget {
  const PinCheckScreen({super.key, required this.lock, required this.title, required this.check});

  final AppLock lock;
  final String title;
  final Future<UnlockResult> Function(String pin) check;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PinEntry(
          title: '輸入目前的 PIN 碼',
          length: lock.pinLength,
          waitUntil: () => lock.waitUntil,
          onSubmit: (pin) async {
            final result = await check(pin);
            if (result is Unlocked) {
              if (context.mounted) Navigator.pop(context, true);
              return null;
            }
            return result is WrongPin && result.triesBeforeWait > 0
                ? 'PIN 碼不對，還可以再試 ${result.triesBeforeWait} 次'
                : 'PIN 碼不對';
          },
        ),
      ),
    ),
  );
}
