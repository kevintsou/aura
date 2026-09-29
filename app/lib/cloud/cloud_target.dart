import 'dart:typed_data';

/// A backup file stored in the cloud.
class CloudFile {
  const CloudFile({required this.name, this.size, this.modifiedAt, this.id});

  final String name;
  final int? size;
  final DateTime? modifiedAt;

  /// The provider's own id, where it has one (Google Drive).
  final String? id;
}

/// A failure to show the user as is.
class CloudException implements Exception {
  const CloudException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Somewhere to keep backup files: a folder the app owns on a cloud
/// service. Every call throws [CloudException] with a message for users.
abstract interface class CloudTarget {
  /// Checks the connection and that the folder can be written.
  Future<void> test();

  /// Newest first.
  Future<List<CloudFile>> list();
  Future<void> upload(String name, Uint8List bytes);
  Future<Uint8List> download(CloudFile file);
  Future<void> delete(CloudFile file);
}

/// Backups the app made itself, the only files it will ever delete.
final backupNamePattern = RegExp(r'^aura-\d{8}-\d{6}\.aura$');
