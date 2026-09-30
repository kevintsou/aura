import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aura/cloud/cloud_target.dart';
import 'package:aura/cloud/google_drive.dart';
import 'package:aura/cloud/webdav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Just enough of a WebDAV server: folders, files, Basic auth.
class _FakeDav {
  final folders = <String>{'/dav/me/'};
  final files = <String, List<int>>{};
  final methods = <String>[];

  MockClient get client => MockClient((req) async {
    methods.add(req.method);
    if (req.headers['Authorization'] != 'Basic ${base64.encode(utf8.encode('me:secret'))}') {
      return http.Response('', 401);
    }
    final path = Uri.decodeFull(req.url.path);
    String parent(String p) => '${p.substring(0, p.lastIndexOf('/', p.length - 2))}/';
    switch (req.method) {
      case 'PROPFIND':
        if (!folders.contains(path)) return http.Response('', 404);
        if (req.headers['Depth'] == '0') return http.Response('<multistatus xmlns="DAV:"/>', 207);
        final entries = [
          '<d:response><d:href>${Uri.encodeFull(path)}</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>',
          for (final f in folders.where((f) => f != path && parent(f) == path))
            '<d:response><d:href>${Uri.encodeFull(f)}</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>',
          for (final e in files.entries.where((e) => parent(e.key) == path))
            '<d:response><d:href>${Uri.encodeFull(e.key)}</d:href><d:propstat><d:prop>'
                '<d:getcontentlength>${e.value.length}</d:getcontentlength>'
                '<d:getlastmodified>Tue, 29 Sep 2026 13:30:00 GMT</d:getlastmodified>'
                '<d:resourcetype/></d:prop></d:propstat></d:response>',
        ];
        return http.Response.bytes(
          utf8.encode('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>'),
          207,
        );
      case 'MKCOL':
        if (folders.contains(path)) return http.Response('', 405);
        folders.add(path);
        return http.Response('', 201);
      case 'PUT':
        if (!folders.contains(parent(path))) return http.Response('', 409);
        files[path] = req.bodyBytes;
        return http.Response('', 201);
      case 'GET':
        final f = files[path];
        return f == null ? http.Response('', 404) : http.Response.bytes(f, 200);
      case 'DELETE':
        return http.Response('', files.remove(path) == null ? 404 : 204);
    }
    return http.Response('', 405);
  });
}

class _FakeTokens implements GoogleTokens {
  var _n = 0;
  final discarded = <String>[];

  @override
  bool get available => true;

  @override
  Future<String> connect() async => 'me@example.com';

  @override
  Future<String> token() async => 'token-${_n++}';

  @override
  Future<void> discard(String token) async => discarded.add(token);

  @override
  Future<void> disconnect() async {}
}

/// Just enough of the Drive v3 API.
class _FakeDrive {
  final items = <String, Map<String, Object?>>{};
  final bytes = <String, List<int>>{};
  var _id = 0;

  /// Refuse the first token, as an expired one would be.
  var refuseFirst = true;

  http.Response _ok(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

  MockClient get client => MockClient((req) async {
    final auth = req.headers['Authorization'];
    if (auth == null || (refuseFirst && auth == 'Bearer token-0')) {
      return http.Response('{"error":{"code":401}}', 401);
    }
    final path = req.url.path;
    if (req.method == 'GET' && path == '/drive/v3/files') {
      final q = req.url.queryParameters['q']!;
      final parent = RegExp(r"'([^']+)' in parents").firstMatch(q)?[1];
      final name = RegExp(r"name = '([^']+)'").firstMatch(q)?[1];
      return _ok({
        'files': [
          for (final e in items.entries)
            if ((parent == null || (e.value['parents'] as List).contains(parent)) &&
                (name == null || e.value['name'] == name))
              {'id': e.key, ...e.value, 'size': '${bytes[e.key]?.length ?? 0}', 'modifiedTime': '2026-09-29T13:30:00Z'},
        ],
      });
    }
    if (req.method == 'POST' && path == '/drive/v3/files') {
      final id = 'f${_id++}';
      items[id] = {...jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>, 'parents': <String>[]};
      return _ok({'id': id});
    }
    if (req.method == 'POST' && path == '/upload/drive/v3/files') {
      expect(req.url.queryParameters['uploadType'], 'multipart');
      final boundary = req.headers['Content-Type']!.split('boundary=').last;
      final parts = latin1.decode(req.bodyBytes).split('--$boundary');
      final meta = jsonDecode(utf8.decode(latin1.encode(parts[1].split('\r\n\r\n')[1].trim())));
      final content = parts[2].substring(parts[2].indexOf('\r\n\r\n') + 4, parts[2].length - 2);
      final id = 'f${_id++}';
      items[id] = {'name': meta['name'], 'parents': meta['parents']};
      bytes[id] = latin1.encode(content);
      return _ok({'id': id});
    }
    final id = path.split('/').last;
    if (req.method == 'GET' && req.url.queryParameters['alt'] == 'media') {
      return bytes[id] == null ? http.Response('', 404) : http.Response.bytes(bytes[id]!, 200);
    }
    if (req.method == 'DELETE') {
      return http.Response('', items.remove(id) == null ? 404 : 204);
    }
    return http.Response('{}', 400);
  });
}

final _payload = Uint8List.fromList([0, 1, 2, 250, 13, 10, 45, 45, 255]);

void main() {
  group('WebDAV', () {
    WebDavTarget target(_FakeDav server, {String password = 'secret'}) => WebDavTarget(
      url: 'https://cloud.example.com/dav/me',
      username: 'me',
      password: password,
      folder: 'Aura 記帳',
      client: server.client,
    );

    test('creates its folder, uploads, lists newest first, downloads and deletes', () async {
      final server = _FakeDav();
      final t = target(server);
      await t.test();
      expect(server.folders, contains('/dav/me/Aura 記帳/'));
      expect(server.files, isEmpty, reason: 'the test file is removed');

      await t.upload('aura-20260928-080000.aura', _payload);
      await t.upload('aura-20260929-080000.aura', _payload);
      server.files['/dav/me/Aura 記帳/notes.txt'] = [1];
      server.folders.add('/dav/me/Aura 記帳/old/');

      final files = await t.list();
      expect([for (final f in files) f.name], ['aura-20260929-080000.aura', 'aura-20260928-080000.aura']);
      expect(files.first.size, _payload.length);
      expect(files.first.modifiedAt, DateTime.utc(2026, 9, 29, 13, 30).toLocal());
      expect(await t.download(files.first), _payload);

      await t.delete(files.last);
      expect((await t.list()).single.name, 'aura-20260929-080000.aura');
    });

    test('explains failures in words', () async {
      final server = _FakeDav();
      await expectLater(
        target(server, password: 'wrong').test(),
        throwsA(isA<CloudException>().having((e) => e.message, 'message', contains('帳號或密碼不對'))),
      );
      expect(WebDavTarget.checkUrl('http://cloud.example.com/dav'), contains('https'));
      expect(WebDavTarget.checkUrl('http://192.168.1.20:5005/dav'), isNull, reason: 'a NAS at home');
      expect(WebDavTarget.checkUrl('cloud.example.com'), isNotNull);
      expect(WebDavTarget.checkUrl('https://cloud.example.com/remote.php/dav/files/me'), isNull);
    });

    test('a TLS error becomes a message too', () async {
      final t = WebDavTarget(
        url: 'https://cloud.example.com/dav/me',
        username: 'me',
        password: 'secret',
        folder: 'Aura',
        client: MockClient((_) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED')),
      );
      await expectLater(
        t.list(),
        throwsA(isA<CloudException>().having((e) => e.message, 'message', contains('連不上伺服器'))),
      );
    });
  });

  group('Google Drive', () {
    test('keeps backups in its own folder, retrying once with a fresh token', () async {
      final server = _FakeDrive();
      final tokens = _FakeTokens();
      final t = GoogleDriveTarget(tokens: tokens, client: server.client);
      await t.test();
      expect(tokens.discarded, ['token-0']);
      final folder = server.items.entries.single;
      expect(folder.value['name'], 'Aura 記帳備份');

      await t.upload('aura-20260928-080000.aura', _payload);
      await t.upload('aura-20260929-080000.aura', _payload);
      // A second app session finds the same folder instead of making one.
      final again = GoogleDriveTarget(tokens: tokens, client: server.client);
      final files = await again.list();
      expect([for (final f in files) f.name], ['aura-20260929-080000.aura', 'aura-20260928-080000.aura']);
      expect(server.items.values.where((i) => i['mimeType'] != null), hasLength(1));
      expect(await again.download(files.first), _payload);

      await again.delete(files.last);
      expect((await again.list()).single.name, 'aura-20260929-080000.aura');
    });
  });
}
