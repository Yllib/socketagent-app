import 'package:app/widgets/code_editing_controller.dart';
import 'package:app/widgets/config_syntax.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _comment = Color(0xFF000001);
const _section = Color(0xFF000002);
const _attr = Color(0xFF000003);
const _string = Color(0xFF000004);
const _number = Color(0xFF000005);
const _literal = Color(0xFF000006);
const _theme = {
  'comment': TextStyle(color: _comment),
  'section': TextStyle(color: _section),
  'attr': TextStyle(color: _attr),
  'string': TextStyle(color: _string),
  'number': TextStyle(color: _number),
  'literal': TextStyle(color: _literal),
};

/// Flattens spans to (text, colour) runs, the way the field paints them.
List<(String, Color?)> runs(Iterable<InlineSpan> spans, [Color? inherited]) {
  final out = <(String, Color?)>[];
  for (final span in spans) {
    if (span is! TextSpan) continue;
    final color = span.style?.color ?? inherited;
    if (span.text != null) out.add((span.text!, color));
    out.addAll(runs(span.children ?? const [], color));
  }
  return out;
}

List<(String, Color?)> scan(String line, String language) =>
    runs(tokenizeConfigLine(line, language: language, theme: _theme));

void main() {
  test('TOML lines: headers, keys, values and comments, text kept whole', () {
    for (final line in [
      '[[servers.alpha]] # arr',
      'model = "gpt-5" # trailing',
      "path = 'C:\\x' ",
      'a.b_c = -1_000',
      'when = 1979-05-27T07:32:00Z',
      'flag = true',
      'inline = { key = "v", n = 3 }',
      'escaped = "say \\"hi\\" # not a comment"',
    ]) {
      expect(scan(line, 'toml').map((run) => run.$1).join(), line);
    }
    expect(scan('[[servers.alpha]] # arr', 'toml'), [
      ('[[servers.alpha]]', _section),
      (' ', null),
      ('# arr', _comment),
    ]);
    expect(scan('model = "gpt-5" # trailing', 'toml'), [
      ('model', _attr),
      (' = ', null),
      ('"gpt-5"', _string),
      (' ', null),
      ('# trailing', _comment),
    ]);
    expect(scan('a.b_c = -1_000', 'toml'), [
      ('a.b_c', _attr),
      (' = ', null),
      ('-1_000', _number),
    ]);
    expect(scan('when = 1979-05-27T07:32:00Z', 'toml').last, (
      '1979-05-27T07:32:00Z',
      _number,
    ));
    expect(scan('flag = true', 'toml').last, ('true', _literal));
    expect(scan('inline = { key = "v", n = 3 }', 'toml'), [
      ('inline', _attr),
      (' = { ', null),
      ('key', _attr),
      (' = ', null),
      ('"v"', _string),
      (', ', null),
      ('n', _attr),
      (' = ', null),
      ('3', _number),
      (' }', null),
    ]);
    expect(scan('escaped = "say \\"hi\\" # not a comment"', 'toml').last, (
      '"say \\"hi\\" # not a comment"',
      _string,
    ));
  });

  test('JSON lines tell keys from string values', () {
    expect(scan('  "allow": ["Bash", 3, true, null],', 'json'), [
      ('  ', null),
      ('"allow"', _attr),
      (': [', null),
      ('"Bash"', _string),
      (', ', null),
      ('3', _number),
      (', ', null),
      ('true', _literal),
      (', ', null),
      ('null', _literal),
      ('],', null),
    ]);
    // `#` is not a comment in JSON and `[` is not a header.
    expect(scan('["#tag"]', 'json'), [
      ('[', null),
      ('"#tag"', _string),
      (']', null),
    ]);
  });

  testWidgets('the controller joins lines back into the exact text', (
    tester,
  ) async {
    const source = '# top\r\n[model]\nname = "gpt-5"\n\nflag = true\n';
    final controller = CodeEditingController(language: 'toml', text: source)
      ..theme = _theme;
    late TextSpan span;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          span = controller.buildTextSpan(
            context: context,
            withComposing: false,
          );
          return const SizedBox();
        },
      ),
    );
    final painted = runs([span]);
    expect(painted.map((run) => run.$1).join(), source);
    expect(painted, contains(('[model]', _section)));
    expect(painted, contains(('name', _attr)));
  });

  testWidgets('a huge file is left plain rather than tokenised', (
    tester,
  ) async {
    final controller = CodeEditingController(
      language: 'json',
      text: '{"k": "v"}\n' * (CodeEditingController.highlightLimit ~/ 10),
    )..theme = _theme;
    late TextSpan span;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          span = controller.buildTextSpan(
            context: context,
            withComposing: false,
          );
          return const SizedBox();
        },
      ),
    );
    expect(span.children, isNull);
    expect(span.text, controller.text);
  });
}
