import 'big5hkscs.dart';

/// Column order of a CWMoney classic export (both generations).
const cwmColumns = [
  '日期', '類別', '主分類', '子分類', '帳戶', '專案', '金額', '匯率', '小計', //
  '建檔時間', 'GPS', '地址', '發票號碼', '轉帳', '備註',
];

enum CwmExportFormat {
  /// True CSV (seen in 2026 exports). Supported.
  csv,

  /// Excel HTML table with a .csv extension (seen in 2018 exports).
  html,

  /// A workbook the user re-saved from Excel.
  xlsx,
  unknown,
}

class CwmFormatException implements Exception {
  CwmFormatException(this.message);
  final String message;
  @override
  String toString() => 'CwmFormatException: $message';
}

/// One raw export row, fields in [cwmColumns] order.
class CwmRow {
  CwmRow(this.fields, this.lineNumber) : assert(fields.length == 15);

  final List<String> fields;

  /// 1-based record number in the file (header is 1).
  final int lineNumber;

  String get date => fields[0];
  String get type => fields[1];
  String get mainCategory => fields[2];
  String get subCategory => fields[3];
  String get account => fields[4];
  String get project => fields[5];
  String get amount => fields[6];
  String get rate => fields[7];
  String get subtotal => fields[8];
  String get createdAt => fields[9];
  String get gps => fields[10];
  String get address => fields[11];
  String get invoiceNumber => fields[12];
  String get transferFlag => fields[13];
  String get note => fields[14];
}

CwmExportFormat detectCwmFormat(List<int> bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04) {
    return CwmExportFormat.xlsx;
  }
  final head = String.fromCharCodes(
    bytes.take(64).where((b) => b < 0x80),
  ).trimLeft().toLowerCase();
  if (head.startsWith('<!doctype html') ||
      head.startsWith('<html') ||
      head.startsWith('<table')) {
    return CwmExportFormat.html;
  }
  if (bytes.isNotEmpty && bytes[0] == 0x22) return CwmExportFormat.csv;
  return CwmExportFormat.unknown;
}

/// Parses a CWMoney CSV export.
///
/// CWMoney quotes every field but does not escape quotes inside them, and
/// uses CRLF between records while notes contain bare LF. A generic CSV
/// parser mis-splits such files, so records are split on CRLF and fields
/// on `","`; the note is the last field and may contain anything.
List<CwmRow> readCwmCsv(List<int> bytes) {
  final format = detectCwmFormat(bytes);
  if (format != CwmExportFormat.csv) {
    throw CwmFormatException(switch (format) {
      CwmExportFormat.html => '這是舊版 CWMoney 的 HTML 匯出格式，目前還不支援',
      CwmExportFormat.xlsx => '這是 Excel 活頁簿，請匯入 CWMoney 原始的 CSV 檔',
      _ => '無法辨識的檔案格式，請匯入 CWMoney 經典版匯出的 CSV 檔',
    });
  }
  final records = decodeBig5Hkscs(bytes).split('\r\n');
  final header = _splitRecord(records.first);
  if (header == null || header.join(',') != cwmColumns.join(',')) {
    throw CwmFormatException('標題列和 CWMoney 經典版的格式不符');
  }
  final rows = <CwmRow>[];
  for (var i = 1; i < records.length; i++) {
    final line = records[i];
    if (line.isEmpty) continue;
    final fields = _splitRecord(line);
    if (fields == null) {
      throw CwmFormatException('第 ${i + 1} 筆紀錄的格式錯誤');
    }
    rows.add(CwmRow(fields, i + 1));
  }
  return rows;
}

List<String>? _splitRecord(String line) {
  if (line.length < 2 || !line.startsWith('"') || !line.endsWith('"')) {
    return null;
  }
  final body = line.substring(1, line.length - 1);
  final fields = <String>[];
  var start = 0;
  while (fields.length < 14) {
    final sep = body.indexOf('","', start);
    if (sep < 0) return null;
    fields.add(body.substring(start, sep));
    start = sep + 3;
  }
  fields.add(body.substring(start));
  return fields;
}
