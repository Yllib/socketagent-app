import 'package:app/services/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only servers from 1.1.10 on are asked to search', () {
    expect(serverVersionSupportsSessionSearch(null), isFalse);
    expect(serverVersionSupportsSessionSearch('1.0.52'), isFalse);
    expect(serverVersionSupportsSessionSearch('1.1.9'), isFalse);
    expect(serverVersionSupportsSessionSearch('1.1.10'), isTrue);
    expect(serverVersionSupportsSessionSearch('1.1.912'), isTrue);
    expect(serverVersionSupportsSessionSearch('1.2.0'), isTrue);
    expect(serverVersionSupportsSessionSearch('2.0.0-dev'), isTrue);
  });
}
