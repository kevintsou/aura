import 'package:aura_core/aura_core.dart';

import 'ledger_store_memory.dart'
    if (dart.library.ffi) 'ledger_store_sqlite.dart'
    as impl;

/// Opens the device ledger: SQLite on iOS/Android/desktop; in memory on
/// the web (a development target without FFI), so nothing persists there.
Future<LedgerStore> openLedgerStore() => impl.openLedgerStore();
