import 'package:app/models/context_meter.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> usage(int tokens, {int window = 1000000}) => {
  'inputTokens': 1200,
  'cacheReadTokens': tokens - 1200,
  'cacheCreateTokens': 0,
  'contextWindow': window,
};

const claudeContext = {
  'totalTokens': 180000,
  'maxTokens': 355000,
  'autoCompactThreshold': 322000,
  'isAutoCompactEnabled': true,
};

void main() {
  test('a Claude session measures toward compaction, not the model window', () {
    final meter = ContextMeter.from(
      usage: usage(161000),
      context: claudeContext,
    )!;
    expect(meter.limit, 322000);
    expect(meter.fill, 0.5);
    expect(meter.windowTokens, 355000);
    expect(meter.compactMark, closeTo(322000 / 355000, 0.001));
  });

  test('a changed limit moves the meter before the next turn confirms it', () {
    final meter = ContextMeter.from(
      usage: usage(161000),
      context: claudeContext,
      pendingWindow: 500000,
    )!;
    // The 33k reserve carries over to the new window.
    expect(meter.windowTokens, 500000);
    expect(meter.compactAt, 467000);

    // A window past what the model holds is capped at the model's.
    final capped = ContextMeter.from(
      usage: usage(161000, window: 400000),
      context: claudeContext,
      pendingWindow: 900000,
    )!;
    expect(capped.compactAt, 367000);
  });

  test('with auto-compact off the model window is the limit', () {
    final meter = ContextMeter.from(
      usage: usage(250000),
      context: claudeContext,
      autoCompact: false,
    )!;
    expect(meter.compactAt, isNull);
    expect(meter.limit, 1000000);
    expect(meter.compactMark, isNull);
  });

  test('Codex reports a window and no compaction point', () {
    final meter = ContextMeter.from(
      usage: usage(129200, window: 0),
      context: const {'totalTokens': 129200, 'maxTokens': 258400},
    )!;
    expect(meter.compactAt, isNull);
    expect(meter.fill, 0.5);
  });

  test('before any breakdown arrives the model window is all there is', () {
    expect(ContextMeter.from(usage: usage(100000))!.limit, 1000000);
    expect(ContextMeter.from(usage: usage(100000, window: 0)), isNull);
  });
}
