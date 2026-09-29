import 'dart:typed_data';

import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/photo_picker.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 PNG, so Image.memory has something real to decode.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _Picker implements PhotoPicker {
  final asked = <bool>[];

  @override
  bool get hasCamera => true;

  @override
  Future<Uint8List?> pick({required bool camera}) async {
    asked.add(camera);
    return _png;
  }
}

void main() {
  testWidgets('photos are added to a record, kept with it and removed', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picker = _Picker();
    final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), photoPicker: picker);
    await app.load();
    app.startFresh();
    await tester.pumpWidget(AuraApp(app: app));
    await tester.pumpAndSettle();
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tap(find.byKey(const Key('addTxn')));
    await tester.enterText(find.byKey(const Key('txnAmount')), '350');
    await tap(find.byKey(const Key('addPhoto')));
    await tap(find.byKey(const Key('photoCamera')));
    await tap(find.byKey(const Key('addPhoto')));
    await tap(find.byKey(const Key('photoGallery')));
    expect(picker.asked, [true, false]);
    expect(find.byKey(const Key('newPhoto-1')), findsOneWidget);
    await tap(find.byKey(const Key('saveTxn')));

    final txn = app.ledger.transactions().single;
    expect(app.ledger.photoIds(txn.id), hasLength(2));
    expect(app.ledger.photo(app.ledger.photoIds(txn.id).first)!.bytes, _png);
    expect(find.bySemanticsLabel('有照片'), findsNothing, reason: 'semantics off; the icon is there');
    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);

    // Open, view one, delete it; nothing changes until saved.
    await tap(find.text('生活費 · 早餐'));
    final first = app.ledger.photoIds(txn.id).first;
    await tap(find.byKey(Key('photo-$first')));
    await tap(find.byKey(const Key('deletePhoto')));
    expect(find.byKey(Key('photo-$first')), findsNothing);
    expect(app.ledger.photoIds(txn.id), hasLength(2));
    await tap(find.byKey(const Key('saveTxn')));
    expect(app.ledger.photoIds(txn.id), hasLength(1));

    // Backups carry them.
    final bytes = await tester.runAsync(() => encodeBackup(app.ledger, createdAt: DateTime(2026)));
    final restored = await tester.runAsync(() => decodeBackup(bytes!));
    expect(restored!.info.photos, 1);
    expect(restored.ledger.photos().single.bytes, _png);
  });
}
