import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_lock.dart';

/// Wraps the whole app (above the navigator): shows the lock screen while
/// locked, and a plain cover while the app is not in front, so the
/// app switcher does not show amounts.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.lock, required this.child});

  final AppLock lock;
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  late final AppLifecycleListener _lifecycle;
  var _covered = false;
  var _wasHidden = false;
  bool? _secure;

  AppLock get _lock => widget.lock;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onInactive: () => setState(() => _covered = true),
      onHide: () {
        _wasHidden = true;
        _lock.backgrounded();
      },
      onResume: () {
        _lock.resumed();
        setState(() => _covered = false);
        // Only after real backgrounding: a cancelled Face ID prompt also
        // passes through inactive, and must not bring the prompt back.
        if (_wasHidden && _lock.locked) _lock.unlockWithBiometrics();
        _wasHidden = false;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _lock,
    builder: (context, _) {
      if (_secure != _lock.enabled) {
        _secure = _lock.enabled;
        unawaited(setSecureWindow(_lock.enabled));
      }
      final locked = _lock.locked;
      return Stack(
        fit: StackFit.expand,
        children: [
          // While locked, nothing underneath may be reached by keyboard
          // focus, screen readers or taps.
          ExcludeFocus(
            excluding: locked,
            child: ExcludeSemantics(
              excluding: locked,
              child: IgnorePointer(ignoring: locked, child: widget.child),
            ),
          ),
          if (_lock.locked) LockScreen(lock: _lock) else if (_covered && _lock.enabled) const _PrivacyCover(),
        ],
      );
    },
  );
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(child: Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );
}

/// Asks for the PIN (or a fingerprint/face) before showing the app.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock});

  final AppLock lock;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  var _showHelp = false;

  @override
  void initState() {
    super.initState();
    // Offer biometrics straight away when the lock screen first appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.lock.unlockWithBiometrics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lock = widget.lock;
    return Material(
      key: const Key('lockScreen'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 40, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('Aura 記帳', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 24),
                  PinEntry(
                    title: '輸入 PIN 碼',
                    length: lock.pinLength,
                    waitUntil: () => lock.waitUntil,
                    onSubmit: (pin) async => switch (await lock.unlock(pin)) {
                      Unlocked() => null,
                      WrongPin(:final triesBeforeWait) =>
                        triesBeforeWait > 0 ? 'PIN 碼不對，還可以再試 $triesBeforeWait 次' : 'PIN 碼不對',
                      MustWait() => 'PIN 碼不對',
                    },
                    extra: lock.biometricsEnabled
                        ? PinPadButton(
                            key: const Key('unlockBiometrics'),
                            label: '用指紋或臉部解鎖',
                            onPressed: lock.unlockWithBiometrics,
                            child: const Icon(Icons.fingerprint, size: 32),
                          )
                        : null,
                  ),
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => setState(() => _showHelp = !_showHelp), child: const Text('忘記 PIN 碼？')),
                  if (_showHelp)
                    Text(
                      'PIN 碼沒有辦法找回，App 裡也不能跳過。'
                      '可以移除 App 後重新安裝，再用備份檔（.aura）還原資料。'
                      '所以開啟 App 鎖時，記得定期備份。',
                      key: const Key('forgotPinHelp'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dots, a message line and a number pad. With [length], submits as soon
/// as that many digits are in; without, the user confirms 4–6 digits.
/// [onSubmit] returns an error to show, or null when accepted.
class PinEntry extends StatefulWidget {
  const PinEntry({
    super.key,
    required this.title,
    required this.onSubmit,
    this.length,
    this.subtitle,
    this.extra,
    this.waitUntil,
  });

  final String title;
  final String? subtitle;
  final int? length;
  final Future<String?> Function(String pin) onSubmit;

  /// Shown in the pad's bottom-left corner (e.g. biometrics).
  final Widget? extra;

  /// While this returns a future time, input is disabled with a countdown.
  final DateTime? Function()? waitUntil;

  @override
  State<PinEntry> createState() => _PinEntryState();
}

class _PinEntryState extends State<PinEntry> {
  var _pin = '';
  String? _error;
  var _busy = false;
  var _keys = false;
  Timer? _ticker;
  final _focus = FocusNode();

  int get _slots => widget.length ?? AppLock.maxPinLength;
  DateTime? get _waitUntil => widget.waitUntil?.call();

  @override
  void initState() {
    super.initState();
    _tickIfWaiting();
    // Keyboard input only after the first frame: on the web, the page
    // gaining focus before the first layout makes focus traversal read
    // sizes that do not exist yet when the app opens locked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _keys = true);
      _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(PinEntry old) {
    super.didUpdateWidget(old);
    if (old.title != widget.title) {
      _pin = '';
      _error = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _tickIfWaiting() {
    _ticker?.cancel();
    if (_waitUntil == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {});
      if (_waitUntil == null) t.cancel();
    });
  }

  bool get _disabled => _busy || _waitUntil != null;

  void _digit(String d) {
    if (_disabled || _pin.length >= _slots) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (widget.length != null && _pin.length == widget.length) _submit();
  }

  void _backspace() {
    if (_disabled || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    String? error;
    try {
      error = await widget.onSubmit(_pin);
    } finally {
      // Never leave the keypad dead, whatever happened.
      if (mounted) {
        setState(() {
          _busy = false;
          _pin = '';
          _error = error;
        });
        _tickIfWaiting();
      }
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ch = e.character;
    if (ch != null && RegExp(r'^\d$').hasMatch(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter && !_disabled && widget.length == null && AppLock.validPin(_pin)) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wait = _waitUntil;
    final message = wait != null ? '錯太多次了，請在 ${_countdown(wait)} 後再試' : _error ?? widget.subtitle ?? '';
    final pad = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 16),
        Semantics(
          label: '已輸入 ${_pin.length} 位',
          child: Row(
            key: const Key('pinDots'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _slots; i++)
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? theme.colorScheme.primary : null,
                    border: Border.all(color: theme.colorScheme.outline, width: 1.5),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: Text(
            message,
            key: const Key('pinMessage'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _error != null || wait != null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) _key(d)]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 88, height: 72, child: Center(child: widget.extra)),
            _key('0'),
            PinPadButton(
              key: const Key('pinBackspace'),
              label: '刪除',
              onPressed: _backspace,
              child: const Icon(Icons.backspace_outlined),
            ),
          ],
        ),
        if (widget.length == null) ...[
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('pinNext'),
            onPressed: !_disabled && AppLock.validPin(_pin) ? _submit : null,
            child: const Text('下一步'),
          ),
        ],
      ],
    );
    return _keys ? Focus(focusNode: _focus, onKeyEvent: _onKey, child: pad) : pad;
  }

  Widget _key(String d) => PinPadButton(
    key: Key('pin$d'),
    label: d,
    onPressed: () => _digit(d),
    child: Text(d, style: Theme.of(context).textTheme.headlineSmall),
  );
}

String _countdown(DateTime until) {
  final s = until.difference(DateTime.now()).inSeconds.clamp(0, 99999) + 1;
  return s >= 60 ? '${s ~/ 60} 分 ${s % 60} 秒' : '$s 秒';
}

/// A round pad key. No tooltip: the lock screen sits above the app's
/// navigator, where there is no overlay to show one in.
class PinPadButton extends StatelessWidget {
  const PinPadButton({super.key, required this.label, required this.onPressed, required this.child});

  final String label;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: SizedBox(
      width: 88,
      height: 72,
      child: Center(
        child: InkResponse(
          onTap: onPressed,
          radius: 34,
          child: SizedBox(width: 64, height: 64, child: Center(child: child)),
        ),
      ),
    ),
  );
}
