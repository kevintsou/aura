import 'package:aura/app_state.dart';
import 'package:aura/lock/app_lock.dart';
import 'package:aura/main.dart';
import 'package:aura/services/ai_settings_store.dart';
import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBiometrics implements Biometrics {
  _FakeBiometrics({this.succeed = true});
  bool succeed;
  var asked = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return succeed;
  }
}

var _now = DateTime(2026, 9, 29, 21);

AppLock _lock(LockStore store, {Biometrics biometrics = const NoBiometrics()}) =>
    AppLock(store: store, biometrics: biometrics, clock: () => _now, iterations: 1000);

void main() {
  setUp(() => _now = DateTime(2026, 9, 29, 21));

  group('AppLock', () {
    test('a PIN turns it on; the app starts locked from then on', () async {
      final store = MemoryLockStore();
      final lock = _lock(store);
      await lock.load();
      expect((lock.enabled, lock.locked), (false, false));
      await lock.setPin('2468');
      expect((lock.enabled, lock.locked, lock.pinLength), (true, false, 4));
      expect(store.value, isNot(contains('2468')), reason: 'only a hash is stored');

      final next = _lock(store);
      await next.load();
      expect(next.locked, isTrue);
      expect(await next.unlock('1111'), isA<WrongPin>());
      expect(next.locked, isTrue);
      expect(await next.unlock('2468'), isA<Unlocked>());
      expect(next.locked, isFalse);
      expect(() => next.setPin('12a4'), throwsArgumentError);
      expect(() => next.setPin('123'), throwsArgumentError);
    });

    test('wrong PINs lead to growing waits that survive a restart', () async {
      final store = MemoryLockStore();
      final lock = _lock(store);
      await lock.setPin('2468');
      for (var left = 4; left >= 1; left--) {
        expect((await lock.unlock('0000') as WrongPin).triesBeforeWait, left);
      }
      final fifth = await lock.unlock('0000');
      expect((fifth as MustWait).until, _now.add(const Duration(seconds: 30)));

      final restarted = _lock(store);
      await restarted.load();
      expect(await restarted.unlock('2468'), isA<MustWait>(), reason: 'even the right PIN waits');

      _now = _now.add(const Duration(seconds: 31));
      final sixth = await restarted.unlock('0000');
      expect((sixth as MustWait).until, _now.add(const Duration(minutes: 1)));
      _now = _now.add(const Duration(minutes: 2));
      expect(await restarted.unlock('2468'), isA<Unlocked>());
      _now = _now.add(const Duration(minutes: 1));
      expect((await restarted.unlock('0000') as WrongPin).triesBeforeWait, 4, reason: 'count reset');
    });

    test('locks again after the timeout in the background', () async {
      final lock = _lock(MemoryLockStore());
      await lock.setPin('2468');
      lock
        ..backgrounded()
        ..resumed();
      expect(lock.locked, isFalse, reason: 'back within a minute');

      lock.backgrounded();
      _now = _now.add(const Duration(minutes: 2));
      lock.resumed();
      expect(lock.locked, isTrue);
      await lock.unlock('2468');

      await lock.setTimeout(LockTimeout.immediately);
      await lock.whileAway(() async {
        lock.backgrounded(); // e.g. the file picker opened
        _now = _now.add(const Duration(minutes: 3));
        lock.resumed();
      });
      expect(lock.locked, isFalse, reason: 'left on purpose, from inside the app');
      lock
        ..backgrounded()
        ..resumed();
      expect(lock.locked, isTrue);
    });

    test('turning it off needs the PIN; biometrics unlock', () async {
      final bio = _FakeBiometrics();
      final store = MemoryLockStore();
      final lock = _lock(store, biometrics: bio);
      await lock.load();
      await lock.setPin('135790');
      expect(lock.biometricsEnabled, isTrue, reason: 'on by default where available');

      final next = _lock(store, biometrics: bio);
      await next.load();
      expect(await next.unlockWithBiometrics(), isTrue);
      expect(next.locked, isFalse);

      expect(await next.disable('000000'), isA<WrongPin>());
      expect(next.enabled, isTrue);
      expect(await next.disable('135790'), isA<Unlocked>());
      expect((next.enabled, store.value), (false, null));
    });
  });

  group('screens', () {
    Future<AppLock> open(WidgetTester tester, {String? pin, Biometrics biometrics = const NoBiometrics()}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryLockStore();
      if (pin != null) {
        await tester.runAsync(() async {
          final setup = _lock(store, biometrics: biometrics);
          await setup.load();
          await setup.setPin(pin);
        });
      }
      final lock = _lock(store, biometrics: biometrics);
      await tester.runAsync(lock.load);
      final app = AppState(ledger: InMemoryLedger(), settings: MemoryAiSettingsStore(), lock: lock);
      await tester.pumpWidget(AuraApp(app: app));
      await tester.pumpAndSettle();
      return lock;
    }

    Future<void> enter(WidgetTester tester, String digits) async {
      for (final d in digits.split('')) {
        await tester.tap(find.byKey(Key('pin$d')));
        await tester.pump();
      }
      // PBKDF2 runs as real async work.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    String message(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('pinMessage'))).data!;

    testWidgets('the app opens locked and a PIN unlocks it', (tester) async {
      final lock = await open(tester, pin: '2468');
      expect(find.byKey(const Key('lockScreen')), findsOneWidget);
      expect(find.byKey(const Key('pinNext')), findsNothing, reason: 'submits by itself at 4 digits');
      await enter(tester, '1357');
      expect(message(tester), 'PIN 碼不對，還可以再試 4 次');
      expect(lock.locked, isTrue);

      await tester.tap(find.text('忘記 PIN 碼？'));
      await tester.pump();
      expect(find.byKey(const Key('forgotPinHelp')), findsOneWidget);

      await enter(tester, '2468');
      expect(find.byKey(const Key('lockScreen')), findsNothing);
      expect(find.text('開始記帳'), findsOneWidget);
    });

    testWidgets('offers biometrics when the lock screen appears', (tester) async {
      final bio = _FakeBiometrics(succeed: false);
      final lock = await open(tester, pin: '2468', biometrics: bio);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(bio.asked, 1);
      expect(lock.locked, isTrue, reason: 'cancelled');

      bio.succeed = true;
      await tester.tap(find.byKey(const Key('unlockBiometrics')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse);
    });

    testWidgets('turned on from settings with a PIN entered twice', (tester) async {
      final lock = await open(tester);
      await tester.tap(find.text('設定'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appLock')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lockSwitch')));
      await tester.pumpAndSettle();

      await enter(tester, '12345');
      await tester.tap(find.byKey(const Key('pinNext')));
      await tester.pumpAndSettle();
      expect(find.text('再輸入一次'), findsOneWidget);
      await enter(tester, '12344');
      expect(find.text('兩次輸入不一樣，請重新設定'), findsOneWidget);

      await enter(tester, '12345');
      await tester.tap(find.byKey(const Key('pinNext')));
      await tester.pumpAndSettle();
      await enter(tester, '12345');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect((lock.enabled, lock.pinLength, lock.locked), (true, 5, false));
      expect(find.text('變更 PIN 碼'), findsOneWidget);

      await tester.tap(find.byKey(const Key('timeout-immediately')));
      await tester.pumpAndSettle();
      expect(lock.timeout, LockTimeout.immediately);

      // Leaving the app locks it.
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lockScreen')), findsOneWidget);
      await enter(tester, '12345');
      expect(find.text('變更 PIN 碼'), findsOneWidget, reason: 'back where the user was');
    });

    testWidgets('nothing behind the lock screen can be read, focused or tapped', (tester) async {
      final semantics = tester.ensureSemantics();
      final lock = await open(tester, pin: '2468');
      expect(find.text('開始記帳'), findsOneWidget, reason: 'built underneath');
      expect(find.semantics.byLabel(RegExp('開始記帳')), findsNothing, reason: 'hidden from screen readers');
      final button = find.byKey(const Key('startFresh'));
      expect(Focus.of(tester.element(button)).canRequestFocus, isFalse);
      expect(
        find.ancestor(of: button, matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring)),
        findsOneWidget,
      );

      await enter(tester, '2468');
      expect(lock.locked, isFalse);
      expect(find.semantics.byLabel(RegExp('開始記帳')), findsAny);
      semantics.dispose();
    });

    testWidgets('covers the screen while the app is not in front', (tester) async {
      final lock = await open(tester, pin: '2468');
      await enter(tester, '2468');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(lock.locked, isFalse, reason: 'a glance at the app switcher is not leaving');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });
  });
}
