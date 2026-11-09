import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage reply(String entryId, int seq, int revision, String text) =>
    ChatMessage.assistantText('s')
      ..entryId = entryId
      ..sessionSeq = seq
      ..revision = revision
      ..textContent = text;

void main() {
  test('a page keeps unchanged cards, swaps revised ones, drops removed', () {
    final older = reply('old', 1, 1, 'older page');
    final kept = reply('a', 3, 1, 'unchanged');
    final revised = reply('b', 4, 1, 'before');
    final removed = reply('c', 5, 1, 'deleted on the server');
    final page = [
      reply('a', 3, 1, 'unchanged'),
      reply('b', 4, 2, 'after'),
      reply('d', 6, 1, 'new'),
    ];

    final result = reconcileViewTranscript(page, [
      older,
      kept,
      revised,
      removed,
    ], fromSeq: 3);

    expect(result.map((m) => m.textContent), [
      'older page',
      'unchanged',
      'after',
      'new',
    ]);
    expect(result[0], same(older));
    expect(result[1], same(kept));
    expect(result[2], same(page[1]));
  });

  test('a streaming card keeps its object and takes the row position', () {
    final streaming = ChatMessage.assistantText('s')
      ..streamId = 'stream-1'
      ..textContent = 'Partial';
    final row = reply('a', 3, 1, 'Partial reply');

    final result = reconcileViewTranscript([row], [streaming], fromSeq: 3);

    expect(result.single, same(streaming));
    expect(streaming.textContent, 'Partial reply');
    expect(streaming.sessionSeq, 3);
    expect(streaming.entryId, 'a');
  });

  test('a pending prompt becomes its row by client message ID', () {
    final prompt = ChatMessage.userText('run it')..isPending = true;
    final row = ChatMessage.userText('run it')
      ..entryId = 'u'
      ..sessionSeq = 7
      ..revision = 1
      ..clientMessageId = prompt.id;

    final result = reconcileViewTranscript([row], [prompt], fromSeq: 7);

    expect(result.single, same(prompt));
    expect(prompt.sessionSeq, 7);
  });

  test('drafts keep their place after the card they followed', () {
    final first = reply('a', 3, 1, 'first');
    final localCard = ChatMessage.toolCall(
      tool: 'SendFile',
      input: const {'file_path': '/tmp/x'},
      toolUseId: 'file_1',
    );
    final second = reply('b', 4, 1, 'second');
    final pending = ChatMessage.userText('not stored yet');

    final result = reconcileViewTranscript(
      [reply('a', 3, 1, 'first'), reply('b', 4, 1, 'second')],
      [first, localCard, second, pending],
      fromSeq: 3,
    );

    expect(result, [first, localCard, second, pending]);
  });

  test('a live row newer than the page stays until a later page has it', () {
    // The app holds a page for up to 150 ms while live events keep coming.
    final older = reply('old', 1, 1, 'older');
    final inRange = reply('a', 3, 1, 'kept');
    final liveAhead = reply('z', 9, 1, 'arrived after the page');

    final result = reconcileViewTranscript(
      [reply('a', 3, 1, 'kept')],
      [older, inRange, liveAhead],
      fromSeq: 3,
    );

    expect(result, [older, inRange, liveAhead]);
  });
}
