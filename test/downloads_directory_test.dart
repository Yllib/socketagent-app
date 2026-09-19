import 'dart:io';

import 'package:app/services/downloads_directory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The bug this rule exists for: every download path hardcoded the Android
  // shared folder. On Windows that is drive-relative, so downloads were
  // written to C:\storage\emulated\0\Download and the user never found them.
  test('desktop uses the folder the platform names, not the Android one', () {
    expect(
      resolveDownloadsPath(
        isAndroid: false,
        platformDownloads: r'C:\Users\billy\Downloads',
        home: r'C:\Users\billy',
      ),
      r'C:\Users\billy\Downloads',
    );
  });

  test('android keeps the shared folder it has always used', () {
    expect(
      resolveDownloadsPath(
        isAndroid: true,
        platformDownloads: null,
        home: '/data/user/0',
      ),
      '/storage/emulated/0/Download',
    );
  });

  // getDownloadsDirectory is documented to return null on some platforms, and
  // a download that lands in the home folder still beats one that fails.
  test('a desktop that will not name its folder falls back to home', () {
    final expected = '/home/billy${Platform.pathSeparator}Downloads';
    expect(
      resolveDownloadsPath(
        isAndroid: false,
        platformDownloads: null,
        home: '/home/billy',
      ),
      expected,
    );
    expect(
      resolveDownloadsPath(
        isAndroid: false,
        platformDownloads: '   ',
        home: '/home/billy',
      ),
      expected,
    );
  });

  test('with nothing to go on, downloads still land somewhere writable', () {
    expect(
      resolveDownloadsPath(
        isAndroid: false,
        platformDownloads: null,
        home: null,
      ),
      Directory.systemTemp.path,
    );
  });

  test('home comes from whichever variable the platform sets', () {
    expect(homeDirectoryFrom({'HOME': '/home/billy'}), '/home/billy');
    expect(
      homeDirectoryFrom({'USERPROFILE': r'C:\Users\billy'}),
      r'C:\Users\billy',
    );
    expect(homeDirectoryFrom({}), isNull);
  });
}
