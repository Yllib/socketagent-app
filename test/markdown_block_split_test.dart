import 'package:flutter_test/flutter_test.dart';
import 'package:app/util/markdown_block_split.dart';

void main() {
  test('splits at blank lines', () {
    expect(splitMarkdownBlocks('# Title\n\nOne.\n\n\n- a\n- b\n'), [
      '# Title',
      'One.',
      '- a\n- b',
    ]);
  });

  test('keeps fenced code whole, blank lines included', () {
    const text =
        'Before.\n\n```dart\nfinal a = 1;\n\nfinal b = 2;\n```\n\nAfter.';
    expect(splitMarkdownBlocks(text), [
      'Before.',
      '```dart\nfinal a = 1;\n\nfinal b = 2;\n```',
      'After.',
    ]);
  });

  test('keeps an indented continuation with the block before it', () {
    const text = '1. Item\n\n    more about it\n\n2. Next';
    expect(splitMarkdownBlocks(text), [
      '1. Item\n\n    more about it',
      '2. Next',
    ]);
  });

  test('an unclosed fence holds the rest of a streaming reply', () {
    expect(splitMarkdownBlocks('Intro.\n\n```\nline\n\nstill code'), [
      'Intro.',
      '```\nline\n\nstill code',
    ]);
  });

  test('as text streams in, only the last block changes', () {
    const full =
        '# Plan\n\nFirst paragraph.\n\n```sh\nnpm test\n\nnpm run build\n```\n\n'
        '- one\n- two\n\nLast words.';
    final finalBlocks = splitMarkdownBlocks(full);
    for (var end = 1; end <= full.length; end++) {
      final blocks = splitMarkdownBlocks(full.substring(0, end));
      for (var i = 0; i < blocks.length - 1; i++) {
        expect(blocks[i], finalBlocks[i], reason: 'prefix length $end');
      }
    }
  });
}
