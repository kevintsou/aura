import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Files the user saves or opens (backups, CWMoney exports): the
/// platform's file dialogs, so users can pick the Files app, Google
/// Drive, iCloud Drive and so on.
abstract interface class BackupFiles {
  /// False when the user cancelled.
  Future<bool> save(String fileName, Uint8List bytes, {String title = '儲存備份檔'});

  /// Null when the user cancelled.
  Future<({String name, Uint8List bytes})?> pick({String title = '選擇備份檔'});
}

class DeviceBackupFiles implements BackupFiles {
  @override
  Future<bool> save(String fileName, Uint8List bytes, {String title = '儲存備份檔'}) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      dialogTitle: title,
    );
    // The web starts a download and never learns where it went, so it
    // always returns null; on devices null means the user cancelled.
    return kIsWeb || uri != null;
  }

  @override
  Future<({String name, Uint8List bytes})?> pick({String title = '選擇備份檔'}) async {
    final file = await FilePicker.pickFile(dialogTitle: title);
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }
}
