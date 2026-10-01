import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The privacy policy, from the same file that is published for the
/// app stores (assets/legal/privacy-policy.md).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const asset = 'assets/legal/privacy-policy.md';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('隱私權政策')),
    body: FutureBuilder<String>(
      future: rootBundle.loadString(asset),
      builder: (context, snap) => switch (snap) {
        AsyncSnapshot(:final String data) => ListView(
          key: const Key('privacyText'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [for (final b in markdownBlocks(data)) _block(context, b)],
        ),
        AsyncSnapshot(hasError: true) => const Center(child: Text('讀不到隱私權政策')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    ),
  );

  Widget _block(BuildContext context, MdBlock b) {
    final t = Theme.of(context).textTheme;
    final text = Text.rich(_inline(b.text), style: switch (b.kind) {
      MdKind.title => t.headlineSmall,
      MdKind.heading => t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      _ => t.bodyMedium?.copyWith(height: 1.6),
    });
    return Padding(
      padding: EdgeInsets.only(top: b.kind == MdKind.heading ? 20 : 6, bottom: 2),
      child: b.kind == MdKind.bullet
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [const Text('・'), Expanded(child: text)],
            )
          : text,
    );
  }

  /// `**bold**` and `code`; everything else as written.
  static TextSpan _inline(String s) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');
    var at = 0;
    for (final m in re.allMatches(s)) {
      spans.add(TextSpan(text: s.substring(at, m.start)));
      spans.add(
        m[1] != null
            ? TextSpan(text: m[1], style: const TextStyle(fontWeight: FontWeight.w600))
            : TextSpan(text: m[2], style: const TextStyle(fontFamily: 'monospace')),
      );
      at = m.end;
    }
    spans.add(TextSpan(text: s.substring(at)));
    return TextSpan(children: spans);
  }
}

enum MdKind { title, heading, bullet, paragraph }

class MdBlock {
  const MdBlock(this.kind, this.text);
  final MdKind kind;
  final String text;
}

/// The small part of Markdown the policy uses: `#`, `##`, `- ` and
/// paragraphs (lines joined until a blank line).
List<MdBlock> markdownBlocks(String md) {
  final out = <MdBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) out.add(MdBlock(MdKind.paragraph, para.join()));
    para.clear();
  }

  for (final raw in md.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('## ')) {
      flush();
      out.add(MdBlock(MdKind.heading, line.substring(3)));
    } else if (line.startsWith('# ')) {
      flush();
      out.add(MdBlock(MdKind.title, line.substring(2)));
    } else if (line.startsWith('- ')) {
      flush();
      out.add(MdBlock(MdKind.bullet, line.substring(2)));
    } else {
      para.add(line);
    }
  }
  flush();
  return out;
}
