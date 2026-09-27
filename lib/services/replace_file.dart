import 'dart:io';

/// Windows readers and antivirus can briefly prevent replacing an existing
/// file. Keep the previous copy intact and retry the atomic rename.
Future<void> replaceFile(File temporary, String destination) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await temporary.rename(destination);
      return;
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          !const {5, 32, 33}.contains(error.osError?.errorCode) ||
          attempt >= 5) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 20 << attempt));
    }
  }
}
