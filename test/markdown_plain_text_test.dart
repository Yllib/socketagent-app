import 'package:app/util/markdown_plain_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('drops formatting marks but keeps headings and lists readable', () {
    expect(
      markdownToPlainText(
        '# Result\n\nRead the [full report](https://x.test) with **care**.\n\n- one\n- two',
      ),
      'Result\n\nRead the full report with care.\n\none\ntwo',
    );
  });

  test('keeps code blocks exactly as written', () {
    expect(
      markdownToPlainText(
        'Steps:\n\n```bash\n# install deps\n- not a list\nnpm **ci**\n```',
      ),
      'Steps:\n\n# install deps\n- not a list\nnpm **ci**',
    );
  });

  test('writes table rows as tab separated lines', () {
    expect(
      markdownToPlainText('| Name | Age |\n| --- | --- |\n| Ann | 3 |'),
      'Name\tAge\nAnn\t3',
    );
  });
}
