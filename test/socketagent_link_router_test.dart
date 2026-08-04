import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/socketagent_link_router.dart';

void main() {
  group('SocketAgentLinkRouter.prepareMarkdown', () {
    test('turns a bare app link into a Markdown link', () {
      const href = 'socketagent://file/download?path=%2Ftmp%2Fbuild.apk';

      expect(
        SocketAgentLinkRouter.prepareMarkdown('Get it here: $href'),
        'Get it here: [Download file]($href)',
      );
    });

    test('does not rewrite an existing Markdown link', () {
      const source =
          '[Download APK](socketagent://file/download?path=%2Ftmp%2Fbuild.apk)';

      expect(SocketAgentLinkRouter.prepareMarkdown(source), source);
    });

    test('leaves inline and fenced code examples literal', () {
      const source = '''
`socketagent://file/view?path=%2Ftmp%2Fa.txt`
```
socketagent://file/view?path=%2Ftmp%2Fb.txt
```
''';

      expect(SocketAgentLinkRouter.prepareMarkdown(source), source);
    });

    test('turns an absolute workspace file link into an app open link', () {
      const source = '[router.dart](/home/billy/project/router.dart:42:7)';

      expect(
        SocketAgentLinkRouter.prepareMarkdown(source),
        '[router.dart](socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Frouter.dart&line=42&column=7)',
      );
    });

    test('supports angle-wrapped workspace paths containing spaces', () {
      const source = '[report](</home/billy/My Project/report final.md:9>)';

      expect(
        SocketAgentLinkRouter.prepareMarkdown(source),
        '[report](socketagent://file/open?path=%2Fhome%2Fbilly%2FMy+Project%2Freport+final.md&line=9)',
      );
    });

    test('does not rewrite web links or Markdown images', () {
      const source = '''
[Docs](https://example.com/docs)
![Preview](/home/billy/project/preview.png)
''';

      expect(SocketAgentLinkRouter.prepareMarkdown(source), source);
    });

    test('turns an exact backticked path into a linked code span', () {
      const source = 'Open `/home/billy/project/report.md:17` to review it.';

      expect(
        SocketAgentLinkRouter.prepareMarkdown(source),
        'Open [`/home/billy/project/report.md:17`](socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Freport.md&line=17) to review it.',
      );
    });

    test('turns standalone and labeled plain paths into links', () {
      const source = '''
/home/billy/project/report.md:17
- Output: /home/billy/project/build.apk
''';

      expect(SocketAgentLinkRouter.prepareMarkdown(source), '''
[/home/billy/project/report.md:17](socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Freport.md&line=17)
- Output: [/home/billy/project/build.apk](socketagent://file/open?path=%2Fhome%2Fbilly%2Fproject%2Fbuild.apk)
''');
    });

    test('turns a standalone Windows path into a link', () {
      const source = r'C:\Users\Billy\project\report.txt:8';

      expect(
        SocketAgentLinkRouter.prepareMarkdown(source),
        r'[C:\Users\Billy\project\report.txt:8](socketagent://file/open?path=C%3A%2FUsers%2FBilly%2Fproject%2Freport.txt&line=8)',
      );
    });

    test('leaves embedded prose commands JSON and relative paths literal', () {
      const source = '''
The file at /home/billy/project/report.md is ready.
rm /home/billy/project/report.md
{"path":"/home/billy/project/report.md"}
`lib/report.dart`
lib/report.dart
''';

      expect(SocketAgentLinkRouter.prepareMarkdown(source), source);
    });
  });
}
