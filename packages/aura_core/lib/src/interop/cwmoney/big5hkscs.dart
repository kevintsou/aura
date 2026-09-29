import 'dart:convert';
import 'dart:typed_data';

import 'big5hkscs_table.g.dart';

const _trailsPerLead = 157; // 0x40-0x7E (63) + 0xA1-0xFE (94)

Uint16List? _table;

Uint16List _loadTable() => _table ??= Uint8List.fromList(
  base64.decode(big5HkscsTableBase64),
).buffer.asUint16List();

int _trailIndex(int trail) {
  if (trail >= 0x40 && trail <= 0x7E) return trail - 0x40;
  if (trail >= 0xA1 && trail <= 0xFE) return trail - 0xA1 + 63;
  return -1;
}

/// Decodes Big5-HKSCS bytes (the encoding of CWMoney exports).
///
/// Invalid or unmapped byte sequences become U+FFFD, like a lenient
/// decoder, so one bad character never aborts an import.
String decodeBig5Hkscs(List<int> bytes) {
  final table = _loadTable();
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i++;
      continue;
    }
    if (b >= 0x81 && b <= 0xFE && i + 1 < bytes.length) {
      final t = _trailIndex(bytes[i + 1]);
      if (t >= 0) {
        final slot = ((b - 0x81) * _trailsPerLead + t) * 2;
        final first = table[slot];
        if (first != 0) {
          out.writeCharCode(first);
          final second = table[slot + 1];
          if (second != 0) out.writeCharCode(second);
          i += 2;
          continue;
        }
      }
    }
    out.writeCharCode(0xFFFD);
    i++;
  }
  return out.toString();
}
