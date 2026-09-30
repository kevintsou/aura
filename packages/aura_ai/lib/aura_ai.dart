/// Aura's AI analysis agent: bring-your-own OpenAI-compatible endpoint,
/// with ledger tools that run on the device.
library;

export 'src/agent.dart';
export 'src/ai_client.dart';
export 'src/categorize.dart';
export 'src/config.dart';
export 'src/messages.dart';
export 'src/prompts.dart';
export 'src/tools/ledger_tools.dart' show ledgerTools, redact;
export 'src/tools/tool.dart';
