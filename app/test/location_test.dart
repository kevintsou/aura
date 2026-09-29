import 'package:aura/app_state.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura/services/location_source.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocation implements LocationSource {
  _FakeLocation(this.here);
  GeoPoint? here;
  var asked = 0;

  @override
  Future<GeoPoint?> current() async {
    asked++;
    return here;
  }
}

const _here = GeoPoint(25.033964, 121.564468);

Future<(AppState, _FakeLocation)> _app(WidgetTester tester, {GeoPoint? here = _here}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final location = _FakeLocation(here);
  final app = AppState(
    ledger: InMemoryLedger(),
    settings: MemoryAiSettingsStore(),
    clock: () => DateTime(2026, 9, 29),
    locationSource: location,
  );
  await app.load();
  app.startFresh();
  await tester.pumpWidget(AuraApp(app: app));
  return (app, location);
}

Future<void> _record(WidgetTester tester, String amount, {bool removeLocation = false}) async {
  await tester.tap(find.text('紀錄').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('addTxn')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('txnAmount')), amount);
  if (removeLocation) await tester.tap(find.byKey(const Key('removeLocation')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('saveTxn')));
  await tester.pumpAndSettle();
}

Future<void> _toggleSetting(WidgetTester tester) async {
  await tester.tap(find.text('設定').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('recordLocation')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('location is off until the user turns it on', (tester) async {
    final (app, location) = await _app(tester);
    expect(app.recordLocation, isFalse);
    await _record(tester, '80');
    expect(app.ledger.transactions().single.location, isNull);
    expect(location.asked, 0, reason: 'never looked up while off');
  });

  testWidgets('with it on, new records note where they were made', (tester) async {
    final (app, _) = await _app(tester);
    await _toggleSetting(tester);
    expect(app.recordLocation, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('recordLocation'))).value, isTrue);

    await tester.tap(find.text('紀錄').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addTxn')));
    await tester.pumpAndSettle();
    expect(find.text('25.03396, 121.56447'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('txnAmount')), '120');
    await tester.tap(find.byKey(const Key('saveTxn')));
    await tester.pumpAndSettle();
    final saved = app.ledger.transactions().single;
    expect(saved.location, _here);

    // Editing keeps it; the user can remove it.
    await tester.tap(find.text('NT\$120').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('txnLocation')), findsOneWidget);
    await tester.tap(find.byKey(const Key('removeLocation')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('saveTxn')));
    await tester.pumpAndSettle();
    expect(app.ledger.txn(saved.id)!.location, isNull);

    await _record(tester, '60', removeLocation: true);
    expect(app.ledger.transactions().where((t) => t.location != null), isEmpty);
  });

  testWidgets('without permission it stays off and says why', (tester) async {
    final (app, location) = await _app(tester, here: null);
    await _toggleSetting(tester);
    expect(location.asked, 1);
    expect(app.recordLocation, isFalse);
    expect(find.textContaining('無法取得位置'), findsOneWidget);
  });
}
