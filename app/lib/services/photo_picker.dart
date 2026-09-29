import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// Takes or picks a photo for a record. Photos are shrunk to at most
/// 1600 px and saved as JPEG, enough to read a receipt.
abstract interface class PhotoPicker {
  /// Whether this device has a camera to take photos with.
  bool get hasCamera;

  /// Null when the user cancelled.
  Future<Uint8List?> pick({required bool camera});
}

class DevicePhotoPicker implements PhotoPicker {
  final _picker = ImagePicker();

  @override
  bool get hasCamera =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<Uint8List?> pick({required bool camera}) async {
    final file = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
      requestFullMetadata: false, // no location or camera data
    );
    return file?.readAsBytes();
  }
}
