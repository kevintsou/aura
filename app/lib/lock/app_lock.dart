import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// How long the app may stay in the background before it locks again.
enum LockTimeout {
  immediately(Duration.zero, '立即'),
  oneMinute(Duration(minutes: 1), '1 分鐘'),
  fiveMinutes(Duration(minutes: 5), '5 分鐘'),
  fifteenMinutes(Duration(minutes: 15), '15 分鐘');

  const LockTimeout(this.after, this.label);
  final Duration after;
  final String label;
}

/// Where the lock settings live: the platform keystore on devices.
abstract interface class LockStore {
  Future<String?> read();

  /// Null deletes.
  Future<void> write(String? value);
}

class DeviceLockStore implements LockStore {
  static const _key = 'app_lock';
  final _secure = const FlutterSecureStorage();

  @override
  Future<String?> read() => _secure.read(key: _key);

  @override
  Future<void> write(String? value) =>
      value == null ? _secure.delete(key: _key) : _secure.write(key: _key, value: value);
}

class MemoryLockStore implements LockStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? value) async => this.value = value;
}

/// Fingerprint / face unlock.
abstract interface class Biometrics {
  Future<bool> available();

  /// False when the user cancelled or it did not match.
  Future<bool> authenticate(String reason);
}

class DeviceBiometrics implements Biometrics {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    if (kIsWeb) return false;
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } on Object {
      return false; // locked out, not enrolled, cancelled: fall back to the PIN
    }
  }
}

class NoBiometrics implements Biometrics {
  const NoBiometrics();

  @override
  Future<bool> available() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

sealed class UnlockResult {
  const UnlockResult();
}

class Unlocked extends UnlockResult {
  const Unlocked();
}

class WrongPin extends UnlockResult {
  const WrongPin(this.triesBeforeWait);

  /// Wrong PINs left before a wait is imposed; 0 once waits apply.
  final int triesBeforeWait;
}

class MustWait extends UnlockResult {
  const MustWait(this.until);
  final DateTime until;
}

/// The app lock: a PIN (stored only as a salted PBKDF2 hash) and,
/// optionally, biometrics. It keeps people who pick up the phone out of
/// the app; it does not encrypt the ledger.
///
/// Wrong PINs are counted across restarts: after [freeTries], each wrong
/// try imposes a growing wait.
class AppLock extends ChangeNotifier {
  AppLock({
    required LockStore store,
    Biometrics biometrics = const NoBiometrics(),
    DateTime Function()? clock,
    this.iterations = 100000,
  }) : _store = store,
       _biometrics = biometrics,
       _clock = clock ?? DateTime.now;

  /// A lock that is off and stays off (tests, previews).
  AppLock.off() : this(store: MemoryLockStore());

  static const freeTries = 5;
  static const minPinLength = 4, maxPinLength = 6;

  final LockStore _store;
  final Biometrics _biometrics;
  final DateTime Function() _clock;

  /// PBKDF2 rounds for new PINs; stored with the hash.
  final int iterations;

  _Settings? _settings;
  bool _locked = false;
  bool _biometricsAvailable = false;
  DateTime? _leftAt;

  bool get enabled => _settings != null;
  bool get locked => _locked;
  int get pinLength => _settings?.pinLength ?? 0;
  bool get biometricsAvailable => _biometricsAvailable;
  bool get biometricsEnabled => _biometricsAvailable && (_settings?.biometrics ?? false);
  LockTimeout get timeout => _settings?.timeout ?? LockTimeout.oneMinute;

  /// Set while wrong PINs impose a wait.
  DateTime? get waitUntil {
    final until = _settings?.blockedUntil;
    return until != null && until.isAfter(_clock()) ? until : null;
  }

  /// Reads the settings; the app starts locked when the lock is on.
  Future<void> load() async {
    final raw = await _store.read();
    _settings = raw == null ? null : _Settings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    _biometricsAvailable = await _biometrics.available();
    _locked = enabled;
    notifyListeners();
  }

  Future<void> _save() async {
    await _store.write(_settings == null ? null : jsonEncode(_settings!.toJson()));
    notifyListeners();
  }

  static bool validPin(String pin) =>
      pin.length >= minPinLength && pin.length <= maxPinLength && RegExp(r'^\d+$').hasMatch(pin);

  /// Turns the lock on, or changes the PIN.
  Future<void> setPin(String pin) async {
    if (!validPin(pin)) throw ArgumentError.value(pin, 'pin', 'PIN 要是 $minPinLength 到 $maxPinLength 位數字');
    final salt = _randomBytes(16);
    _settings = (_settings ?? _Settings(timeout: LockTimeout.oneMinute, biometrics: _biometricsAvailable)).withPin(
      hash: await _hash(pin, salt, iterations),
      salt: salt,
      iterations: iterations,
      pinLength: pin.length,
    );
    _locked = false;
    await _save();
  }

  /// Checks [pin] without unlocking (e.g. before turning the lock off).
  Future<UnlockResult> check(String pin) async {
    final s = _settings;
    if (s == null) return const Unlocked();
    if (waitUntil case final until?) return MustWait(until);
    if (_constantTimeEquals(await _hash(pin, s.salt, s.iterations), s.hash)) {
      if (s.failures > 0 || s.blockedUntil != null) {
        _settings = s.withFailures(0, null);
        await _save();
      }
      return const Unlocked();
    }
    final failures = s.failures + 1;
    final wait = _waitAfter(failures);
    _settings = s.withFailures(failures, wait == null ? null : _clock().add(wait));
    await _save();
    return wait == null ? WrongPin(freeTries - failures) : MustWait(_settings!.blockedUntil!);
  }

  Future<UnlockResult> unlock(String pin) async {
    final result = await check(pin);
    if (result is Unlocked && _locked) {
      _locked = false;
      notifyListeners();
    }
    return result;
  }

  /// Asks for a fingerprint or face; true when it unlocked.
  Future<bool> unlockWithBiometrics() async {
    if (!biometricsEnabled || !_locked) return false;
    if (!await _biometrics.authenticate('解開 Aura 記帳')) return false;
    _locked = false;
    notifyListeners();
    return true;
  }

  /// Turns the lock off. Needs the PIN.
  Future<UnlockResult> disable(String pin) async {
    final result = await check(pin);
    if (result is Unlocked) {
      _settings = null;
      _locked = false;
      await _save();
    }
    return result;
  }

  Future<void> setBiometrics(bool on) async {
    if (_settings == null) return;
    _settings = _settings!.copyWith(biometrics: on);
    await _save();
  }

  Future<void> setTimeout(LockTimeout timeout) async {
    if (_settings == null) return;
    _settings = _settings!.copyWith(timeout: timeout);
    await _save();
  }

  /// Runs [task] (a file picker, a share sheet) without locking when it
  /// takes the user out of the app: they left on purpose, from inside.
  Future<T> whileAway<T>(Future<T> Function() task) async {
    _away++;
    try {
      return await task();
    } finally {
      _away--;
    }
  }

  var _away = 0;

  /// The app went to the background.
  void backgrounded() {
    if (_away == 0) _leftAt ??= _clock();
  }

  /// The app is back: lock again if it was away long enough.
  void resumed() {
    final left = _leftAt;
    _leftAt = null;
    if (!enabled || _locked || left == null) return;
    if (_clock().difference(left) >= timeout.after) {
      _locked = true;
      notifyListeners();
    }
  }

  /// No wait for the first [freeTries] wrong PINs, then 30 s, 1 min,
  /// 5 min, and 15 min for each one after that.
  static Duration? _waitAfter(int failures) => switch (failures - freeTries) {
    < 0 => null,
    0 => const Duration(seconds: 30),
    1 => const Duration(minutes: 1),
    2 => const Duration(minutes: 5),
    _ => const Duration(minutes: 15),
  };

  static Future<List<int>> _hash(String pin, List<int> salt, int iterations) async {
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256).deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return key.extractBytes();
  }
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

final _random = Random.secure();
List<int> _randomBytes(int n) => List.generate(n, (_) => _random.nextInt(256));

class _Settings {
  const _Settings({
    required this.timeout,
    required this.biometrics,
    this.hash = const [],
    this.salt = const [],
    this.iterations = 0,
    this.pinLength = 0,
    this.failures = 0,
    this.blockedUntil,
  });

  factory _Settings.fromJson(Map<String, Object?> j) => _Settings(
    hash: base64.decode(j['hash'] as String),
    salt: base64.decode(j['salt'] as String),
    iterations: j['iterations'] as int,
    pinLength: j['pinLength'] as int,
    biometrics: j['biometrics'] as bool? ?? false,
    timeout: LockTimeout.values.asNameMap()[j['timeout']] ?? LockTimeout.oneMinute,
    failures: j['failures'] as int? ?? 0,
    blockedUntil: switch (j['blockedUntil']) {
      final String s => DateTime.parse(s),
      _ => null,
    },
  );

  final List<int> hash;
  final List<int> salt;
  final int iterations;
  final int pinLength;
  final bool biometrics;
  final LockTimeout timeout;
  final int failures;
  final DateTime? blockedUntil;

  Map<String, Object?> toJson() => {
    'hash': base64.encode(hash),
    'salt': base64.encode(salt),
    'iterations': iterations,
    'pinLength': pinLength,
    'biometrics': biometrics,
    'timeout': timeout.name,
    'failures': failures,
    'blockedUntil': ?blockedUntil?.toIso8601String(),
  };

  _Settings copyWith({bool? biometrics, LockTimeout? timeout}) => _Settings(
    hash: hash,
    salt: salt,
    iterations: iterations,
    pinLength: pinLength,
    biometrics: biometrics ?? this.biometrics,
    timeout: timeout ?? this.timeout,
    failures: failures,
    blockedUntil: blockedUntil,
  );

  _Settings withPin({required List<int> hash, required List<int> salt, required int iterations, required int pinLength}) =>
      _Settings(
        hash: hash,
        salt: salt,
        iterations: iterations,
        pinLength: pinLength,
        biometrics: biometrics,
        timeout: timeout,
      );

  _Settings withFailures(int failures, DateTime? blockedUntil) => _Settings(
    hash: hash,
    salt: salt,
    iterations: iterations,
    pinLength: pinLength,
    biometrics: biometrics,
    timeout: timeout,
    failures: failures,
    blockedUntil: blockedUntil,
  );
}

/// Keeps the screen out of Android's recent-apps preview and screenshots
/// while the lock is on. Other platforms rely on the privacy cover.
Future<void> setSecureWindow(bool secure) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel('app.aura/window').invokeMethod<void>('setSecure', secure);
  } on MissingPluginException {
    // Not wired up (tests).
  }
}
