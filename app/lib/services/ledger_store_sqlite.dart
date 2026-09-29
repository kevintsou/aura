import 'package:aura_core/aura_core.dart';
import 'package:aura_store/aura_store.dart';
import 'package:path_provider/path_provider.dart';

/// `aura.db` in the app's private support directory (not user-visible,
/// included in the platform's app backup).
Future<LedgerStore> openLedgerStore() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return SqliteLedger.open('${dir.path}/aura.db');
}
