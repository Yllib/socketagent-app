import 'package:app/models/file_manager_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file-manager listing preserves pagination metadata', () {
    final listing = FileManagerListing.fromJson({
      'path': '/tmp',
      'entries': [
        {
          'name': 'preview.html',
          'path': '/tmp/preview.html',
          'kind': 'file',
          'hidden': false,
          'extension': '.html',
          'mediaKind': 'code',
          'protected': false,
        },
      ],
      'roots': const [],
      'offset': 200,
      'limit': 200,
      'totalCount': 9076,
      'nextOffset': 400,
      'hasMore': true,
    });

    expect(listing.offset, 200);
    expect(listing.limit, 200);
    expect(listing.totalCount, 9076);
    expect(listing.nextOffset, 400);
    expect(listing.hasMore, isTrue);
    expect(listing.entries.single.name, 'preview.html');
  });
}
