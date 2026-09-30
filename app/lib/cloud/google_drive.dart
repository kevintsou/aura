import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'cloud_target.dart';

/// Gives out Google access tokens for Drive.
abstract interface class GoogleTokens {
  /// Whether this build can sign in to Google on this platform.
  bool get available;

  /// Signs in (may show Google's screens); returns the account email.
  Future<String> connect();

  /// A token without user interaction; throws [CloudException] when the
  /// user has to sign in again.
  Future<String> token();

  /// Tells the source a token was refused, so the next one is fresh.
  Future<void> discard(String token);

  Future<void> disconnect();
}

/// Google sign-in on Android and iOS. The OAuth client ids come from the
/// build (`--dart-define`), since they belong to whoever publishes the
/// app; see docs/cloud-backup.md.
class DeviceGoogleTokens implements GoogleTokens {
  static const scopes = ['https://www.googleapis.com/auth/drive.file'];
  static const _serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
  static const _iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  Future<void>? _init;

  @override
  bool get available =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.android => _serverClientId.isNotEmpty,
        TargetPlatform.iOS => _iosClientId.isNotEmpty,
        _ => false,
      };

  Future<void> _ready() => _init ??= GoogleSignIn.instance.initialize(
    clientId: _iosClientId.isEmpty ? null : _iosClientId,
    serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
  );

  @override
  Future<String> connect() async {
    try {
      await _ready();
      final account = await GoogleSignIn.instance.authenticate(scopeHint: scopes);
      await account.authorizationClient.authorizeScopes(scopes);
      return account.email;
    } on GoogleSignInException catch (e) {
      throw CloudException(
        e.code == GoogleSignInExceptionCode.canceled ? '已取消登入 Google' : '登入 Google 失敗：${e.description ?? e.code.name}',
      );
    }
  }

  @override
  Future<String> token() async {
    await _ready();
    final auth = await GoogleSignIn.instance.authorizationClient.authorizationForScopes(scopes);
    if (auth == null) throw const CloudException('Google 的授權過期了，請到「雲端備份」重新連結');
    return auth.accessToken;
  }

  @override
  Future<void> discard(String token) async {
    await _ready();
    await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(accessToken: token);
  }

  @override
  Future<void> disconnect() async {
    await _ready();
    await GoogleSignIn.instance.disconnect();
  }
}

/// A visible "Aura 記帳備份" folder in the user's Google Drive. With the
/// drive.file scope the app sees only files it created itself.
class GoogleDriveTarget implements CloudTarget {
  GoogleDriveTarget({required this.tokens, http.Client? client}) : _client = client ?? http.Client();

  final GoogleTokens tokens;
  final http.Client _client;
  String? _folderId;

  static const folderName = 'Aura 記帳備份';
  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _folderType = 'application/vnd.google-apps.folder';

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
    bool retried = false,
  }) async {
    final token = await tokens.token();
    final request = http.Request(method, uri)
      ..headers.addAll({'Authorization': 'Bearer $token', ...?headers});
    if (body != null) request.bodyBytes = body;
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 60)));
    } on TimeoutException {
      throw const CloudException('連線逾時，請檢查網路');
    } on http.ClientException catch (e) {
      throw CloudException('連不上 Google 雲端硬碟：${e.message}');
    } on Exception catch (e) {
      // TLS certificate problems and the like.
      throw CloudException('連不上 Google 雲端硬碟：$e');
    }
    if (r.statusCode == 401 && !retried) {
      await tokens.discard(token);
      return _send(method, uri, headers: headers, body: body, retried: true);
    }
    return r;
  }

  Map<String, Object?> _json(http.Response r, String doing) {
    // UTF-8 whatever the headers say: folder and file names are Chinese.
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return text.isEmpty ? const {} : jsonDecode(text) as Map<String, Object?>;
    }
    final reason = switch (text.isEmpty ? const {} : jsonDecode(text)) {
      {'error': {'errors': [{'reason': final String reason}, ...]}} => reason,
      _ => '',
    };
    throw CloudException(switch ((r.statusCode, reason)) {
      (401, _) => 'Google 的授權過期了，請到「雲端備份」重新連結',
      (403, 'storageQuotaExceeded') => 'Google 雲端硬碟的空間不夠了',
      (403, _) => 'Google 拒絕$doing（$reason）',
      _ => '$doing失敗（HTTP ${r.statusCode}）',
    });
  }

  Future<String> _folder() async {
    if (_folderId case final id?) return id;
    final found = _json(
      await _send(
        'GET',
        Uri.parse(_api).replace(
          path: '/drive/v3/files',
          queryParameters: {
            'q': "name = '$folderName' and mimeType = '$_folderType' and trashed = false",
            'fields': 'files(id)',
            'spaces': 'drive',
          },
        ),
      ),
      '尋找備份資料夾',
    );
    final files = found['files'] as List? ?? const [];
    if (files.isNotEmpty) return _folderId = (files.first as Map)['id'] as String;
    final made = _json(
      await _send(
        'POST',
        Uri.parse('$_api/files?fields=id'),
        headers: {'Content-Type': 'application/json'},
        body: utf8.encode(jsonEncode({'name': folderName, 'mimeType': _folderType})),
      ),
      '建立備份資料夾',
    );
    return _folderId = made['id'] as String;
  }

  @override
  Future<void> test() async {
    await _folder();
  }

  @override
  Future<List<CloudFile>> list() async {
    final folder = await _folder();
    final r = _json(
      await _send(
        'GET',
        Uri.parse(_api).replace(
          path: '/drive/v3/files',
          queryParameters: {
            'q': "'$folder' in parents and trashed = false",
            'fields': 'files(id,name,size,modifiedTime)',
            'orderBy': 'name desc',
            'pageSize': '200',
          },
        ),
      ),
      '讀取備份清單',
    );
    return [
      for (final f in (r['files'] as List? ?? const []).cast<Map<String, Object?>>())
        if ((f['name'] as String).endsWith('.aura'))
          CloudFile(
            id: f['id'] as String,
            name: f['name'] as String,
            size: int.tryParse('${f['size']}'),
            modifiedAt: DateTime.tryParse('${f['modifiedTime']}')?.toLocal(),
          ),
    ]..sort((a, b) => b.name.compareTo(a.name));
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    final folder = await _folder();
    const boundary = 'aura-backup-boundary';
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'))
      ..add(utf8.encode(jsonEncode({'name': name, 'parents': [folder]})))
      ..add(utf8.encode('\r\n--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    _json(
      await _send(
        'POST',
        Uri.parse('$_upload?uploadType=multipart&fields=id'),
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
        body: body.takeBytes(),
      ),
      '上傳備份',
    );
  }

  Future<String> _idOf(CloudFile file) async =>
      file.id ??
      (await list()).where((f) => f.name == file.name).firstOrNull?.id ??
      (throw CloudException('雲端上找不到 ${file.name}'));

  @override
  Future<Uint8List> download(CloudFile file) async {
    final r = await _send('GET', Uri.parse('$_api/files/${await _idOf(file)}?alt=media'));
    if (r.statusCode != 200) _json(r, '下載備份');
    return r.bodyBytes;
  }

  @override
  Future<void> delete(CloudFile file) async {
    final r = await _send('DELETE', Uri.parse('$_api/files/${await _idOf(file)}'));
    if (r.statusCode != 404) _json(r, '刪除舊備份');
  }
}
