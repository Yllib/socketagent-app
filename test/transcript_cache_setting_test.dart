import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/transcript_cache_setting.dart';

void main() {
  const mb = 1024 * 1024;

  test('scales the estimate from the average cached transcript', () {
    expect(
      transcriptCacheEstimate((count: 10, bytes: 10 * mb), 500),
      'Now 10 sessions use 10.0 MB.\n'
      'At 500 sessions, about 500.0 MB. '
      'Each is capped at 2 MB, so never more than 1000.0 MB.',
    );
  });

  test('gives only the cap when nothing is cached', () {
    expect(
      transcriptCacheEstimate((count: 0, bytes: 0), 30),
      'Nothing cached yet.\nAt 30 sessions, at most 60.0 MB, since each is '
      'capped at 2 MB.',
    );
  });

  test('warns how many transcripts a lower limit deletes', () {
    expect(
      transcriptCacheEstimate((count: 12, bytes: 12 * mb), 5),
      endsWith('Saving deletes the 7 oldest cached transcripts.'),
    );
  });
}
