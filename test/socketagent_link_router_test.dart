import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/socketagent_link_router.dart';
import 'package:markdown/markdown.dart' as md;

/// The HTML the chat's markdown parser makes of [source], minus the wrapping
/// paragraph, so expectations read like the rendered links.
String render(String source) => md
    .markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: SocketAgentLinkRouter.inlineSyntaxes,
      encodeHtml: false,
    )
    .trim();

void main() {
  group('SocketAgentLinkRouter.inlineSyntaxes', () {
    test('turns a bare app link into a named link', () {
      const href = 'socketagent://file/download?path=%2Ftmp%2Fbuild.apk';

      expect(
        render('Get it here: $href.'),
        '<p>Get it here: <a href="$href">Download file</a>.</p>',
      );
    });

    test('keeps an existing Markdown link as written', () {
      const href = 'socketagent://file/download?path=%2Ftmp%2Fbuild.apk';

      expect(
        render('[Download APK]($href)'),
        '<p><a href="$href">Download APK</a></p>',
      );
    });

    test('leaves inline, fenced, and indented code literal', () {
      const source = '''
`socketagent://file/view?path=%2Ftmp%2Fa.txt`

````
```
/home/billy/project/report.md
```
````

    /home/billy/project/indented.md
''';

      expect(render(source), isNot(contains('<a ')));
    });

    test('turns an exact backticked path into a linked code span', () {
      expect(
        render('Open `/home/billy/project/report.md:17` to review it.'),
        '<p>Open <a href="socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Freport.md&line=17">'
        '<code>/home/billy/project/report.md:17</code></a> to review it.</p>',
      );
    });

    test('leaves application routes with query parameters as code', () {
      expect(
        render('The QR opens `/join?code=abc` automatically.'),
        '<p>The QR opens <code>/join?code=abc</code> automatically.</p>',
      );
    });

    test('turns standalone and labeled plain paths into links', () {
      const source = '''
/home/billy/project/report.md:17

- Output: /home/billy/project/build.apk.
''';

      expect(
        render(source),
        '<p><a href="socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Freport.md&line=17">'
        '/home/billy/project/report.md:17</a></p>\n'
        '<ul>\n<li>Output: <a href="socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Fbuild.apk">'
        '/home/billy/project/build.apk</a>.</li>\n</ul>',
      );
    });

    test('turns a standalone Windows path into a link', () {
      expect(
        render(r'C:\Users\Billy\project\report.txt:8'),
        r'<p><a href="socketagent://file/open?path=C%3A%2FUsers%2FBilly%2Fproject%2Freport.txt&line=8">'
        r'C:\Users\Billy\project\report.txt:8</a></p>',
      );
    });

    test('leaves paths in prose, commands, JSON, and relative paths alone', () {
      const source = '''
The file at /home/billy/project/report.md is ready.
rm /home/billy/project/report.md
{"path":"/home/billy/project/report.md"}
`lib/report.dart`
lib/report.dart
''';

      expect(render(source), isNot(contains('<a ')));
    });
  });

  group('SocketAgentLinkRouter.fileLinkFor', () {
    test('opens an absolute path at its line and column', () {
      expect(
        SocketAgentLinkRouter.fileLinkFor(
          '/home/billy/project/router.dart:42:7',
        ),
        'socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Frouter.dart&line=42&column=7',
      );
    });

    test('decodes the escaped spaces the parser puts in link targets', () {
      final html = render(
        '[report](</home/billy/My Project/report final.md:9>)',
      );
      final href = RegExp(r'href="([^"]+)"').firstMatch(html)![1]!;

      expect(
        SocketAgentLinkRouter.fileLinkFor(href),
        'socketagent://file/open?path=%2Fhome%2Fbilly%2FMy+Project%2Freport+final.md&line=9',
      );
    });

    test('leaves web links and app links to the browser and app', () {
      expect(SocketAgentLinkRouter.fileLinkFor('https://example.com'), isNull);
      expect(
        SocketAgentLinkRouter.fileLinkFor('socketagent://file/view?path=%2Fa'),
        isNull,
      );
    });
  });
}
