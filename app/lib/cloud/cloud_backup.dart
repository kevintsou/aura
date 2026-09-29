import 'dart:convert';

import 'package:aura_core/aura_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_target.dart';
import 'google_drive.dart';
import 'webdav.dart';

enum CloudKind { googleDrive, webdav }

enum CloudFrequency {
  daily(Duration(days: 1), '每天'),
  weekly(Duration(days: 7), '每週');

  const CloudFrequency(this.every, this.label);
  final Duration every;
  final String label;
}

/// Where and how often to back up, and how the last attempt went. Kept
/// per device (not in backups). Passwords live in the keystore.
class CloudConfig {
  const CloudConfig({
    this.kind,
    this.account,
    this.webdavUrl = '',
    this.webdavUser = '',
    this.webdavFolder = 'Aura',
    this.frequency = CloudFrequency.daily,
    this.keep = 10,
    this.lastSuccess,
    this.lastFile,
    this.lastAttempt,
    this.lastError,
  });

  factory CloudConfig.fromJson(Map<String, Object?> j) => CloudConfig(
    kind: CloudKind.values.asNameMap()[j['kind']],
    account: j['account'] as String?,
    webdavUrl: j['webdavUrl'] as String? ?? '',
    webdavUser: j['webdavUser'] as String? ?? '',
    webdavFolder: j['webdavFolder'] as String? ?? 'Aura',
    frequency: CloudFrequency.values.asNameMap()[j['frequency']] ?? CloudFrequency.daily,
    keep: j['keep'] as int? ?? 10,
    lastSuccess: _time(j['lastSuccess']),
    lastFile: j['lastFile'] as String?,
    lastAttempt: _time(j['lastAttempt']),
    lastError: j['lastError'] as String?,
  );

  /// Null when cloud backup is off.
  final CloudKind? kind;

  /// Shown to the user: the Google email, or user@host.
  final String? account;
  final String webdavUrl;
  final String webdavUser;
  final String webdavFolder;
  final CloudFrequency frequency;

  /// How many of the app's own backups to keep in the cloud.
  final int keep;
  final DateTime? lastSuccess;
  final String? lastFile;
  final DateTime? lastAttempt;

  /// Why the last attempt failed; null after a success.
  final String? lastError;

  Map<String, Object?> toJson() => {
    'kind': kind?.name,
    'account': account,
    'webdavUrl': webdavUrl,
    'webdavUser': webdavUser,
    'webdavFolder': webdavFolder,
    'frequency': frequency.name,
    'keep': keep,
    'lastSuccess': lastSuccess?.toIso8601String(),
    'lastFile': lastFile,
    'lastAttempt': lastAttempt?.toIso8601String(),
    'lastError': lastError,
  };

  CloudConfig copyWith({
    CloudFrequency? frequency,
    int? keep,
    DateTime? lastSuccess,
    String? lastFile,
    DateTime? lastAttempt,
    Object? lastError = _keep,
  }) => CloudConfig(
    kind: kind,
    account: account,
    webdavUrl: webdavUrl,
    webdavUser: webdavUser,
    webdavFolder: webdavFolder,
    frequency: frequency ?? this.frequency,
    keep: keep ?? this.keep,
    lastSuccess: lastSuccess ?? this.lastSuccess,
    lastFile: lastFile ?? this.lastFile,
    lastAttempt: lastAttempt ?? this.lastAttempt,
    lastError: identical(lastError, _keep) ? this.lastError : lastError as String?,
  );
}

const _keep = Object();

DateTime? _time(Object? s) => s is String ? DateTime.tryParse(s) : null;

abstract interface class CloudSettingsStore {
  Future<CloudConfig> load();
  Future<void> save(CloudConfig config);
  Future<String?> secret(String key);

  /// Null deletes.
  Future<void> setSecret(String key, String? value);
}

class DeviceCloudSettingsStore implements CloudSettingsStore {
  static const _key = 'cloud_backup';
  final _secure = const FlutterSecureStorage();

  @override
  Future<CloudConfig> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const CloudConfig();
    try {
      return CloudConfig.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return const CloudConfig();
    }
  }

  @override
  Future<void> save(CloudConfig config) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(config.toJson()));

  @override
  Future<String?> secret(String key) => _secure.read(key: 'cloud_$key');

  @override
  Future<void> setSecret(String key, String? value) =>
      value == null ? _secure.delete(key: 'cloud_$key') : _secure.write(key: 'cloud_$key', value: value);
}

class MemoryCloudSettingsStore implements CloudSettingsStore {
  CloudConfig config = const CloudConfig();
  final secrets = <String, String>{};

  @override
  Future<CloudConfig> load() async => config;

  @override
  Future<void> save(CloudConfig config) async => this.config = config;

  @override
  Future<String?> secret(String key) async => secrets[key];

  @override
  Future<void> setSecret(String key, String? value) async =>
      value == null ? secrets.remove(key) : secrets[key] = value;
}

typedef CloudTargetFactory = CloudTarget Function(CloudConfig config, {String? webdavPassword});

/// Automatic, encrypted backups to the user's own cloud storage. Runs
/// when the app opens or comes back to the front and a backup is due;
/// there is no background job.
class CloudBackup extends ChangeNotifier {
  CloudBackup({
    required CloudSettingsStore store,
    required Future<Uint8List> Function(String password) encode,
    required Future<BackupInfo> Function(List<int> bytes, String password) restore,
    required bool Function() hasData,
    required DateTime Function() clock,
    GoogleTokens? google,
    CloudTargetFactory? targets,
  }) : _store = store,
       _encode = encode,
       _restore = restore,
       _hasData = hasData,
       _clock = clock,
       google = google ?? DeviceGoogleTokens(),
       _targets = targets;

  static const minPasswordLength = 8;
  static const _webdavPassword = 'webdav_password', _backupPassword = 'backup_password';

  final CloudSettingsStore _store;
  final Future<Uint8List> Function(String password) _encode;
  final Future<BackupInfo> Function(List<int> bytes, String password) _restore;
  final bool Function() _hasData;
  final DateTime Function() _clock;
  final GoogleTokens google;
  final CloudTargetFactory? _targets;

  CloudConfig config = const CloudConfig();
  bool busy = false;

  bool get enabled => config.kind != null;

  Future<void> load() async {
    config = await _store.load();
    notifyListeners();
  }

  Future<void> _save(CloudConfig c) async {
    config = c;
    await _store.save(c);
    notifyListeners();
  }

  CloudTarget _targetFor(CloudConfig c, String? webdavPassword) =>
      _targets?.call(c, webdavPassword: webdavPassword) ??
      switch (c.kind!) {
        CloudKind.googleDrive => GoogleDriveTarget(tokens: google),
        CloudKind.webdav => WebDavTarget(
          url: c.webdavUrl,
          username: c.webdavUser,
          password: webdavPassword ?? '',
          folder: c.webdavFolder,
        ),
      };

  Future<CloudTarget> _target() async => _targetFor(config, await _store.secret(_webdavPassword));

  /// Checks the connection, then turns cloud backup on. Does not upload:
  /// see [newerInCloud] first, so a new phone does not bury the old
  /// phone's backups under empty ones.
  Future<void> enable(CloudConfig target, {String? webdavPassword, required String backupPassword}) async {
    if (backupPassword.length < minPasswordLength) {
      throw const CloudException('密碼至少要 $minPasswordLength 個字');
    }
    await _targetFor(target, webdavPassword).test();
    await _store.setSecret(_webdavPassword, webdavPassword);
    await _store.setSecret(_backupPassword, backupPassword);
    await _save(
      CloudConfig(
        kind: target.kind,
        account: target.account,
        webdavUrl: target.webdavUrl,
        webdavUser: target.webdavUser,
        webdavFolder: target.webdavFolder,
        frequency: target.frequency,
        keep: target.keep,
      ),
    );
  }

  /// Turns cloud backup off and forgets the passwords. Backups already in
  /// the cloud stay there.
  Future<void> disable() async {
    final wasGoogle = config.kind == CloudKind.googleDrive;
    await _store.setSecret(_webdavPassword, null);
    await _store.setSecret(_backupPassword, null);
    await _save(const CloudConfig());
    if (wasGoogle && google.available) {
      try {
        await google.disconnect();
      } on Object {
        // Already signed out.
      }
    }
  }

  Future<void> setFrequency(CloudFrequency f) => _save(config.copyWith(frequency: f));
  Future<void> setKeep(int keep) => _save(config.copyWith(keep: keep));

  bool get due {
    final last = config.lastSuccess;
    return enabled && (last == null || _clock().difference(last) >= config.frequency.every);
  }

  /// Backs up if one is due. Failures are recorded, not thrown; after a
  /// failure it waits an hour before trying again on its own.
  Future<void> runIfDue() async {
    if (!due || busy || !_hasData()) return;
    final tried = config.lastAttempt;
    if (config.lastError != null && tried != null && _clock().difference(tried) < const Duration(hours: 1)) return;
    try {
      await backupNow();
    } on CloudException {
      // Recorded in config.lastError and shown on the backup screen.
    }
  }

  /// Uploads an encrypted backup now and removes the app's own backups
  /// beyond [CloudConfig.keep]. Returns the file name.
  Future<String> backupNow() async {
    if (!enabled) throw const CloudException('還沒有設定雲端備份');
    if (!_hasData()) throw const CloudException('帳本是空的，沒有東西要備份');
    busy = true;
    notifyListeners();
    final now = _clock();
    try {
      final password = await _store.secret(_backupPassword);
      if (password == null) throw const CloudException('找不到備份密碼，請重新設定雲端備份');
      final bytes = await _encode(password);
      final name = 'aura-${_stamp(now)}.aura';
      final target = await _target();
      await target.upload(name, bytes);
      final ours = [
        for (final f in await target.list())
          if (backupNamePattern.hasMatch(f.name)) f,
      ]..sort((a, b) => b.name.compareTo(a.name));
      for (final old in ours.skip(config.keep)) {
        await target.delete(old);
      }
      await _save(config.copyWith(lastSuccess: now, lastFile: name, lastAttempt: now, lastError: null));
      return name;
    } on CloudException catch (e) {
      await _save(config.copyWith(lastAttempt: now, lastError: e.message));
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<List<CloudFile>> list() async => (await _target()).list();

  Future<Uint8List> download(CloudFile file) async => (await _target()).download(file);

  /// The newest backup in the cloud and what it holds, when it has more
  /// records than the phone: after setting up on a new phone, offer to
  /// restore it before backing up over it.
  Future<(CloudFile, Uint8List, BackupInfo)?> newerInCloud(int localRecords) async {
    final newest = (await list()).firstOrNull;
    if (newest == null) return null;
    final bytes = await download(newest);
    final BackupInfo info;
    try {
      info = readBackupInfo(bytes);
    } on BackupException {
      return null;
    }
    return info.transactions > localRecords ? (newest, bytes, info) : null;
  }

  /// Restores [bytes] with the saved password, or [password] (a backup
  /// made before the password was changed). Throws [BackupException].
  Future<BackupInfo> restore(Uint8List bytes, {String? password}) async {
    final saved = await _store.secret(_backupPassword);
    return _restore(bytes, password ?? saved ?? '');
  }
}

String _stamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
