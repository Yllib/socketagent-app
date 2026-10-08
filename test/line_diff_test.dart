import 'package:app/util/line_diff.dart';
import 'package:flutter_test/flutter_test.dart';

String render(List<DiffLine> diff) => diff
    .map(
      (l) => switch (l.op) {
        DiffOp.same => ' ${l.text}',
        DiffOp.removed => '-${l.text}',
        DiffOp.added => '+${l.text}',
      },
    )
    .join('\n');

void main() {
  test('one changed line keeps the rest as context', () {
    expect(render(lineDiff('a\nb\nc\nd', 'a\nB\nc\nd')), ' a\n-b\n+B\n c\n d');
  });

  test('insertions and deletions in the middle align on common lines', () {
    expect(
      render(lineDiff('x\none\ntwo\nthree\ny', 'x\none\nnew\nthree\nmore\ny')),
      ' x\n one\n-two\n+new\n three\n+more\n y',
    );
  });

  test('identical and fully replaced text', () {
    expect(render(lineDiff('a\nb', 'a\nb')), ' a\n b');
    expect(render(lineDiff('a\nb', 'c')), '-a\n-b\n+c');
  });
}
