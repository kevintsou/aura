import 'package:aura_core/aura_core.dart';
import 'package:geolocator/geolocator.dart';

/// Where the phone is now, for records made with location turned on.
abstract interface class LocationSource {
  /// Null when location is off, not allowed, or not found in time.
  Future<GeoPoint?> current();
}

class DeviceLocationSource implements LocationSource {
  @override
  Future<GeoPoint?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      // A shop-level fix is enough, and much quicker than a precise one.
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
      );
      return GeoPoint(p.latitude, p.longitude);
    } on Exception {
      return null; // timeouts, services switched off mid-way, no plugin (tests)
    }
  }
}
