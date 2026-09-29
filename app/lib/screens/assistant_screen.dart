import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/tool_chart.dart';
import 'ai_settings_screen.dart';

const _suggestions = [
  '這個月花最多錢的是哪些分類？',
  '最近三個月每個月的支出趨勢如何？',
  '我最常在哪些商家消費？',
  '今年加油總共花了多少？',
];

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.app});

  final AppState app;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  AssistantSession get _session => widget.app.assistant;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final q = text ?? _input.text;
    if (q.trim().isEmpty) return;
    _input.clear();
    _session.send(q);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openSettings() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => AiSettingsScreen(app: widget.app)),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.app, _session]),
      builder: (context, _) {
        final app = widget.app;
        return Scaffold(
          appBar: AppBar(
            title: const Text('AI 助理'),
            actions: [
              IconButton(
                tooltip: '新對話',
                icon: const Icon(Icons.refresh),
                onPressed: _session.items.isEmpty ? null : _session.reset,
              ),
              IconButton(
                tooltip: 'AI 連線設定',
                icon: const Icon(Icons.tune),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: !app.aiReady
              ? _NotConfigured(onSetup: _openSettings)
              : Column(
                  children: [
                    Expanded(
                      child: _session.items.isEmpty
                          ? _Welcome(app: app, onAsk: _send)
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.all(12),
                              itemCount: _session.items.length +
                                  (_session.busy ? 1 : 0),
                              itemBuilder: (context, i) =>
                                  i == _session.items.length
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: LinearProgressIndicator(),
                                    )
                                  : _ChatBubble(item: _session.items[i]),
                            ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('question'),
                                controller: _input,
                                minLines: 1,
                                maxLines: 4,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _send(),
                                decoration: const InputDecoration(
                                  hintText: '問問你的帳…',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              key: const Key('send'),
                              tooltip: '送出',
                              onPressed: _session.busy ? null : _send,
                              icon: const Icon(Icons.send),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured({required this.onSetup});
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, size: 48),
          const SizedBox(height: 16),
          const Text(
            '接上你自己的 AI',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Aura 完全免費，AI 分析使用你自己的 OpenAI API 金鑰，'
            '或任何 OpenAI 相容的服務、本機模型、自己的 Agent。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onSetup,
            icon: const Icon(Icons.settings),
            label: const Text('設定 AI 連線'),
          ),
        ],
      ),
    ),
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.app, required this.onAsk});
  final AppState app;
  final void Function(String) onAsk;

  @override
  Widget build(BuildContext context) {
    final count = app.ledger.count();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          '使用 ${app.aiConfig.preset.label} · ${app.aiConfig.model}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Text(
          count == 0
              ? '帳本目前是空的。先到「設定」匯入 CWMoney 的 CSV，AI 才有資料可以分析。'
              : '帳本有 $count 筆紀錄。可以這樣問：',
        ),
        const SizedBox(height: 16),
        if (count > 0)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _suggestions)
                ActionChip(label: Text(s), onPressed: () => onAsk(s)),
            ],
          ),
      ],
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.item});
  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (item) {
      UserChatItem(:final text) => Align(
        alignment: Alignment.centerRight,
        child: _Bubble(color: scheme.primaryContainer, child: Text(text)),
      ),
      ReplyChatItem(:final text, :final usage) => Align(
        alignment: Alignment.centerLeft,
        child: _Bubble(
          color: scheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(text),
              if (usage != null && usage.inputTokens + usage.outputTokens > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'tokens：輸入 ${usage.inputTokens}／輸出 ${usage.outputTokens}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      ErrorChatItem(:final message) => _Bubble(
        color: scheme.errorContainer,
        child: Text(message),
      ),
      final ToolChatItem tool => switch (tool.result) {
        final r? when r.ok => switch (ToolChartData.from(tool.call.name, r.content)) {
          final chart? => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_ToolTile(item: tool), ToolChart(data: chart)],
          ),
          null => _ToolTile(item: tool),
        },
        _ => _ToolTile(item: tool),
      },
    };
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(12),
    constraints: const BoxConstraints(maxWidth: 560),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

/// One tool call, expandable to show exactly what was sent to the AI.
class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.item});
  final ToolChatItem item;

  @override
  Widget build(BuildContext context) {
    final result = item.result;
    final args = _pretty(item.call.argumentsJson);
    final compact = item.call.argumentsJson.trim();
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        dense: true,
        leading: result == null
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                result.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 20,
              ),
        title: Text(describeToolCall(item.call)),
        subtitle: compact.isEmpty || compact == '{}'
            ? null
            : Text(compact, maxLines: 1, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('AI 的查詢參數', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(args, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          if (result != null) ...[
            const SizedBox(height: 8),
            const Text('送給 AI 的資料', style: TextStyle(fontWeight: FontWeight.bold)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: SelectableText(
                  _pretty(result.content),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _pretty(String json) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(json));
    } on FormatException {
      return json;
    }
  }
}
