import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/svg_viewer_screen.dart';

void main() {
  test('svgViewerDocument embeds the SVG only as an encoded img source', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script>'
        '<text>Résumé</text></svg>';
    final document = svgViewerDocument(svg);

    expect(document, isNot(contains('<script>')));
    final source = RegExp(
      r'<img src="data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)"',
    ).firstMatch(document);
    expect(source, isNotNull);
    expect(utf8.decode(base64Decode(source!.group(1)!)), svg);
  });
}
