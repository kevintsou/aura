import 'package:aura_ai/aura_ai.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Where users plug in their own AI: OpenAI with their key, another
/// OpenAI-compatible service, a local model, or their own agent API.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, required this.app});

  final AppState app;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late AiPreset _preset;
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  final _headers = TextEditingController();
  bool _enableTools = true;
  bool _shareItems = true;
  bool _stream = true;
  bool _showKey = false;
  bool _working = false;
  String? _status;
  bool _statusIsError = false;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    final c = widget.app.aiConfig;
    _preset = c.preset;
    _baseUrl.text = c.baseUrl;
    _model.text = c.model;
    _enableTools = c.enableTools;
    _shareItems = c.shareInvoiceItems;
    _stream = c.stream;
    _headers.text = c.extraHeaders.entries
        .map((e) => '${e.key}: ${e.value}')
        .join('\n');
    widget.app.apiKeyFor(_preset).then((k) {
      if (mounted) setState(() => _apiKey.text = k ?? '');
    });
  }

  @override
  void dispose() {
    for (final c in [_baseUrl, _model, _apiKey, _headers]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _parseHeaders() => {
    for (final line in _headers.text.split('\n'))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).trim(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
  }..removeWhere((k, v) => k.isEmpty);

  AiEndpointConfig get _config => AiEndpointConfig(
    preset: _preset,
    baseUrl: _baseUrl.text.trim(),
    model: _model.text.trim(),
    extraHeaders: _parseHeaders(),
    enableTools: _enableTools,
    shareInvoiceItems: _shareItems,
    stream: _stream,
  );

  String? get _key => _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim();

  Future<void> _selectPreset(AiPreset preset) async {
    final key = await widget.app.apiKeyFor(preset);
    setState(() {
      _preset = preset;
      _baseUrl.text = preset.baseUrl;
      _model.text = preset.defaultModel;
      _apiKey.text = key ?? '';
      _status = null;
      _errors = const [];
    });
  }

  bool _check() {
    setState(() => _errors = _config.validate(hasApiKey: _key != null));
    return _errors.isEmpty;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _status = null;
    });
    try {
      await action();
    } on AiClientException catch (e) {
      _setStatus(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _setStatus(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _statusIsError = error;
    });
  }

  Future<void> _testConnection() async {
    if (!_check()) return;
    await _run(() async {
      final watch = Stopwatch()..start();
      final result = await widget.app
          .clientFor(_config, _key)
          .complete(messages: const [UserMessage('請只回覆「OK」兩個字。')]);
      final reply = result.message.content?.trim() ?? '';
      _setStatus(
        '連線成功（${watch.elapsedMilliseconds} ms）。模型回覆：'
        '${reply.isEmpty ? '（空白）' : reply}',
      );
    });
  }

  Future<void> _pickModel() async {
    if (_baseUrl.text.trim().isEmpty) return;
    await _run(() async {
      final models = await widget.app.clientFor(_config, _key).listModels();
      if (!mounted) return;
      if (models.isEmpty) {
        _setStatus('這個端點沒有提供模型清單，請直接輸入模型名稱', error: true);
        return;
      }
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => ListView(
          children: [
            for (final m in models)
              ListTile(
                title: Text(m),
                trailing: m == _model.text ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, m),
              ),
          ],
        ),
      );
      if (picked != null) setState(() => _model.text = picked);
    });
  }

  Future<void> _save() async {
    if (!_check()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errors.join('\n'))),
      );
      return;
    }
    await widget.app.saveAi(_config, _key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已儲存 AI 連線設定')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyLabel = _preset.requiresApiKey ? 'API 金鑰' : 'API 金鑰（選填）';
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 連線設定'),
        actions: [
          TextButton(onPressed: _working ? null : _save, child: const Text('儲存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('服務', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in AiPreset.values)
                ChoiceChip(
                  label: Text(p.label),
                  selected: p == _preset,
                  onSelected: (_) => _selectPreset(p),
                ),
            ],
          ),
          if (_preset == AiPreset.custom) ...[
            const SizedBox(height: 12),
            const _InfoCard(
              icon: Icons.hub_outlined,
              text:
                  '自訂 Agent 需要提供 OpenAI Chat Completions 相容的 API：'
                  'POST {網址}/chat/completions，支援 tools（function calling）。'
                  'Aura 會把帳本查詢工具交給你的 Agent，工具在手機上執行後把結果送回。'
                  '詳細規格見專案文件 docs/ai-agent-api.md。',
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('baseUrl'),
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'API 網址',
              hintText: 'https://api.openai.com/v1',
              helperText: 'Aura 會呼叫「網址/chat/completions」',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('apiKey'),
            controller: _apiKey,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: keyLabel,
              helperText: '只存在這支手機的安全儲存區，不會上傳到 Aura',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _showKey ? '隱藏' : '顯示',
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('model'),
            controller: _model,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: '模型',
              hintText: 'gpt-6-sol',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '從服務取得模型清單',
                icon: const Icon(Icons.list),
                onPressed: _working ? null : _pickModel,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('讓 AI 查詢帳本'),
            subtitle: const Text('提供帳本查詢工具。端點不支援 tool calling 時請關閉'),
            value: _enableTools,
            onChanged: (v) => setState(() => _enableTools = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('分享發票品項明細'),
            subtitle: const Text('讓 AI 看到買了哪些商品，分析會更準確'),
            value: _shareItems,
            onChanged: _enableTools
                ? (v) => setState(() => _shareItems = v)
                : null,
          ),
          SwitchListTile(
            key: const Key('streamReplies'),
            contentPadding: EdgeInsets.zero,
            title: const Text('逐字顯示回答'),
            subtitle: const Text('AI 一邊寫一邊顯示。端點不支援時會自動改成整段顯示'),
            value: _stream,
            onChanged: (v) => setState(() => _stream = v),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('進階：自訂 HTTP 標頭'),
            children: [
              TextField(
                key: const Key('headers'),
                controller: _headers,
                maxLines: 3,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: 'X-Agent-Id: my-agent\nOpenAI-Organization: org-…',
                  helperText: '每行一個「名稱: 值」，每次請求都會帶上',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in _errors)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(e, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton.tonalIcon(
            key: const Key('testConnection'),
            onPressed: _working ? null : _testConnection,
            icon: _working
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check),
            label: const Text('測試連線'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(
              _status!,
              key: const Key('status'),
              style: TextStyle(
                color: _statusIsError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: 24),
          const _InfoCard(
            icon: Icons.privacy_tip_outlined,
            text:
                'Aura 不經過任何伺服器，手機直接連到你設定的 AI 服務，費用由你的帳號支付。'
                '送出的只有你的問題和工具查詢的結果（彙總數字、必要的交易明細，'
                '以及你允許時的發票品項）。手機條碼載具、統編一律不會送出，'
                '長串數字（卡號、帳號）會遮蔽。每次查詢送了什麼，都可以在對話裡點開查看。',
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}
