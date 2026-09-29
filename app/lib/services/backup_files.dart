import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Where backup files go and come from: the platform's file dialogs, so
/// users can pick the Files app, Google Drive, iCloud Drive and so on.
abstract interface class BackupFiles {
  /// False when the user cancelled.
  Future<bool> save(String fileName, Uint8List bytes);

  /// Null when the user cancelled.
  Future<({String name, Uint8List bytes})?> pick();
}

class DeviceBackupFiles implements BackupFiles {
  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      dialogTitle: '儲存備份檔',
    );
    // The web starts a download and never learns where it went, so it
    // always returns null; on devices null means the user cancelled.
    return kIsWeb || uri != null;
  }

  @override
  Future<({String name, Uint8List bytes})?> pick() async {
    final file = await FilePicker.pickFile(dialogTitle: '選擇備份檔');
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }
}
