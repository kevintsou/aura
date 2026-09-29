import 'package:aura_store/aura_store.dart';

import '../../aura_core/test/ledger_store_contract.dart';

void main() => ledgerStoreContract(SqliteLedger.inMemory);
