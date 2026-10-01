import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// A time of day, minutes precision.
typedef ReminderTime = ({int hour, int minute});

/// The next [days] reminders at [at], starting today unless that time has
/// passed or something was already recorded today.
List<DateTime> reminderTimes(DateTime now, ReminderTime at, {required bool recordedToday, int days = 7}) {
  final today = DateTime(now.year, now.month, now.day, at.hour, at.minute);
  final skipToday = recordedToday || !today.isAfter(now);
  return [
    for (var i = skipToday ? 1 : 0; i < days + (skipToday ? 1 : 0); i++)
      DateTime(now.year, now.month, now.day + i, at.hour, at.minute),
  ];
}

/// Puts reminders on the phone's notification schedule.
abstract interface class ReminderScheduler {
  /// Asks to show notifications; false when the user said no.
  Future<bool> requestPermission();

  /// Replaces every scheduled reminder with [times] (empty: none).
  Future<void> schedule(List<DateTime> times);
}

/// Web and tests: remembers what it was asked to schedule.
class MemoryReminders implements ReminderScheduler {
  MemoryReminders({this.allowed = true});
  bool allowed;
  List<DateTime> scheduled = const [];

  @override
  Future<bool> requestPermission() async => allowed;

  @override
  Future<void> schedule(List<DateTime> times) async => scheduled = times;
}

class DeviceReminders implements ReminderScheduler {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  /// Ids used for the week of reminders.
  static const _firstId = 1001, _slots = 8;

  Future<void> _init() => _ready ??= () async {
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
    } on Object {
      tz.setLocalLocation(tz.getLocation('Asia/Taipei'));
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Asked for when the user turns reminders on, not at start.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
  }();

  @override
  Future<bool> requestPermission() async {
    try {
      await _init();
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            true;
      }
      return await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true) ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> schedule(List<DateTime> times) async {
    try {
      await _init();
      for (var i = 0; i < _slots; i++) {
        await _plugin.cancel(id: _firstId + i);
      }
      for (final (i, t) in times.take(_slots).indexed) {
        await _plugin.zonedSchedule(
          id: _firstId + i,
          title: '記帳時間到了',
          body: '今天還沒有記帳，花一分鐘把今天的收支記下來吧。',
          scheduledDate: tz.TZDateTime.from(t, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'daily_reminder',
              '每日記帳提醒',
              channelDescription: '當天還沒記帳時，在你設定的時間提醒',
            ),
            iOS: DarwinNotificationDetails(),
          ),
          // About the set time is enough; exact alarms need a permission.
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    } on Object catch (e) {
      debugPrint('reminders: $e');
    }
  }
}
