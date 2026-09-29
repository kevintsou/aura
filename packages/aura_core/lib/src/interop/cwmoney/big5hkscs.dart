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

Map<int, int>? _single;
Map<int, Map<int, int>>? _pairs;

/// Builds the reverse table. Twelve characters have two codes (十 is
/// 0xA2CC and 0xA451). The higher one wins, except for the fullwidth
/// slashes, which CWMoney writes as 0xA1FE and 0xA240 (checked against
/// real exports).
void _loadReverse() {
  if (_single != null) return;
  final table = _loadTable();
  final single = <int, int>{};
  final pairs = <int, Map<int, int>>{};
  for (var lead = 0x81; lead <= 0xFE; lead++) {
    for (var t = 0; t < _trailsPerLead; t++) {
      final slot = ((lead - 0x81) * _trailsPerLead + t) * 2;
      final first = table[slot], second = table[slot + 1];
      if (first == 0) continue;
      final trail = t < 63 ? 0x40 + t : 0xA1 + t - 63;
      final code = lead << 8 | trail;
      if (second == 0) {
        single[first] = code;
      } else {
        pairs.putIfAbsent(first, () => {})[second] = code;
      }
    }
  }
  single
    ..[0xFF0F] = 0xA1FE // ／
    ..[0xFF3C] = 0xA240; // ＼
  _single = single;
  _pairs = pairs;
}

/// Encodes [text] as Big5-HKSCS. Characters it cannot represent (emoji,
/// for one) become `?`; [unmappable] counts them.
Uint8List encodeBig5Hkscs(String text, {void Function(int codeUnit)? unmappable}) {
  _loadReverse();
  final out = BytesBuilder(copy: false);
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u < 0x80) {
      out.addByte(u);
      continue;
    }
    // Two-unit sequences first: surrogate pairs and HKSCS compositions.
    if (i + 1 < units.length) {
      final code = _pairs![u]?[units[i + 1]];
      if (code != null) {
        out
          ..addByte(code >> 8)
          ..addByte(code & 0xFF);
        i++;
        continue;
      }
    }
    final code = _single![u];
    if (code != null) {
      out
        ..addByte(code >> 8)
        ..addByte(code & 0xFF);
      continue;
    }
    unmappable?.call(u);
    out.addByte(0x3F);
    // A lone half of a surrogate pair stands for one character.
    if (u >= 0xD800 && u < 0xDC00 && i + 1 < units.length && units[i + 1] >= 0xDC00 && units[i + 1] < 0xE000) i++;
  }
  return out.takeBytes();
}
