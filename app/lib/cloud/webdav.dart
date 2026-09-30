import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'cloud_target.dart';

/// A folder on a WebDAV server: Nextcloud, ownCloud, Synology / QNAP,
/// Koofr, InfiniCloud and most NAS boxes speak it.
class WebDavTarget implements CloudTarget {
  WebDavTarget({
    required String url,
    required this.username,
    required this.password,
    String folder = 'Aura',
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _folder = _folderUri(url, folder);

  final String username;
  final String password;
  final http.Client _client;
  final Uri _folder;

  static const _timeout = Duration(seconds: 60);

  /// `https://host/remote.php/dav/files/me` + `Aura` → `…/me/Aura/`.
  static Uri _folderUri(String url, String folder) {
    final base = Uri.parse(url.trim());
    final segments = [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...folder.split('/').where((s) => s.trim().isNotEmpty).map((s) => s.trim()),
    ];
    return base.replace(pathSegments: [...segments, '']);
  }

  /// Plain http is only for servers on the local network.
  static String? checkUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasAuthority || !(u.scheme == 'https' || u.scheme == 'http')) {
      return '請輸入完整的網址，例如 https://cloud.example.com/remote.php/dav/files/帳號';
    }
    final host = u.host;
    final local = host == 'localhost' ||
        host.endsWith('.local') ||
        RegExp(r'^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(host);
    if (u.scheme == 'http' && !local) return '網路上的伺服器請用 https，密碼和備份才不會被看到';
    return null;
  }

  Map<String, String> get _auth => {
    'Authorization': 'Basic ${base64.encode(utf8.encode('$username:$password'))}',
  };

  Uri _file(String name) => _folder.replace(pathSegments: [..._folder.pathSegments.where((s) => s.isNotEmpty), name]);

  Future<http.Response> _send(String method, Uri uri, {Map<String, String>? headers, List<int>? body}) async {
    final request = http.Request(method, uri)..headers.addAll({..._auth, ...?headers});
    if (body != null) request.bodyBytes = body;
    try {
      return await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const CloudException('連線逾時，請檢查網路或伺服器網址');
    } on http.ClientException catch (e) {
      throw CloudException('連不上伺服器：${e.message}');
    } on Exception catch (e) {
      // TLS certificate problems and the like.
      throw CloudException('連不上伺服器：$e');
    }
  }

  void _check(http.Response r, String doing) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw CloudException(switch (r.statusCode) {
      401 => '帳號或密碼不對（有些服務要用「應用程式密碼」）',
      403 => '伺服器拒絕$doing，請檢查這個帳號的權限',
      404 => '找不到這個網址，請檢查 WebDAV 網址',
      405 || 501 => '這個網址不是 WebDAV 位址',
      507 => '雲端空間不夠了',
      _ => '$doing失敗（HTTP ${r.statusCode}）',
    });
  }

  Future<void> _ensureFolder() async {
    final probe = await _send('PROPFIND', _folder, headers: {'Depth': '0'});
    if (probe.statusCode == 207 || probe.statusCode == 200) return;
    if (probe.statusCode != 404) _check(probe, '讀取資料夾');
    final made = await _send('MKCOL', _folder);
    if (made.statusCode != 201 && made.statusCode != 405) _check(made, '建立資料夾');
  }

  @override
  Future<void> test() async {
    await _ensureFolder();
    final name = '.aura-test';
    _check(await _send('PUT', _file(name), body: utf8.encode('ok')), '寫入');
    await _send('DELETE', _file(name));
  }

  @override
  Future<List<CloudFile>> list() async {
    final r = await _send(
      'PROPFIND',
      _folder,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:getcontentlength/><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>',
      ),
    );
    if (r.statusCode == 404) return const [];
    _check(r, '讀取備份清單');
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(r.bodyBytes, allowMalformed: true));
    } on XmlException {
      throw const CloudException('伺服器的回應看不懂，這個網址可能不是 WebDAV 位址');
    }
    final files = <CloudFile>[];
    for (final response in doc.findAllElements('response', namespaceUri: 'DAV:')) {
      final href = response.getElement('href', namespaceUri: 'DAV:')?.innerText ?? '';
      final name = Uri.decodeComponent(href.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '');
      final isFolder = response.findAllElements('collection', namespaceUri: 'DAV:').isNotEmpty;
      if (isFolder || !name.endsWith('.aura')) continue;
      String? prop(String local) => response.findAllElements(local, namespaceUri: 'DAV:').firstOrNull?.innerText;
      files.add(
        CloudFile(
          name: name,
          size: int.tryParse(prop('getcontentlength') ?? ''),
          modifiedAt: _httpDate(prop('getlastmodified')),
        ),
      );
    }
    return files..sort((a, b) => b.name.compareTo(a.name));
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    await _ensureFolder();
    _check(
      await _send('PUT', _file(name), headers: {'Content-Type': 'application/octet-stream'}, body: bytes),
      '上傳備份',
    );
  }

  @override
  Future<Uint8List> download(CloudFile file) async {
    final r = await _send('GET', _file(file.name));
    _check(r, '下載備份');
    return r.bodyBytes;
  }

  @override
  Future<void> delete(CloudFile file) async {
    final r = await _send('DELETE', _file(file.name));
    if (r.statusCode != 404) _check(r, '刪除舊備份');
  }
}

DateTime? _httpDate(String? s) {
  if (s == null) return null;
  try {
    return parseHttpDate(s);
  } on FormatException {
    return null;
  }
}

/// RFC 1123 dates, as WebDAV servers send them.
DateTime parseHttpDate(String s) {
  final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final month = m == null ? -1 : months.indexOf(m[2]!);
  if (m == null || month < 0) throw FormatException('not an HTTP date', s);
  return DateTime.utc(int.parse(m[3]!), month + 1, int.parse(m[1]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!))
      .toLocal();
}
