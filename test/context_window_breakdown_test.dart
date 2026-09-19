import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/context_window_breakdown.dart';

/// Verbatim from a stored `lastContextUsage`, on a CLI that reports `kind`.
const _withKind = [
  {'name': 'System prompt', 'tokens': 6575, 'color': 'promptBorder', 'kind': 'used'},
  {'name': 'System tools', 'tokens': 12081, 'color': 'inactive', 'kind': 'used'},
  {'name': 'MCP tools', 'tokens': 303, 'color': 'cyan_FOR_SUBAGENTS_ONLY', 'kind': 'used'},
  {
    'name': 'MCP tools (deferred)',
    'tokens': 19199,
    'color': 'inactive',
    'isDeferred': true,
    'kind': 'deferred',
  },
  {
    'name': 'System tools (deferred)',
    'tokens': 25403,
    'color': 'inactive',
    'isDeferred': true,
    'kind': 'deferred',
  },
  {'name': 'Memory files', 'tokens': 2990, 'color': 'claude', 'kind': 'used'},
  {'name': 'Skills', 'tokens': 3858, 'color': 'warning', 'kind': 'used'},
  {'name': 'Messages', 'tokens': 70248, 'color': 'purple_FOR_SUBAGENTS_ONLY', 'kind': 'used'},
  {'name': 'Autocompact buffer', 'tokens': 33000, 'color': 'inactive', 'kind': 'buffer'},
  {'name': 'Free space', 'tokens': 225945, 'color': 'promptBorder', 'kind': 'free'},
];

/// The same session from an older CLI, which sends no `kind` at all.
const _withoutKind = [
  {'name': 'System prompt', 'tokens': 6265, 'color': 'promptBorder'},
  {'name': 'System tools', 'tokens': 13822, 'color': 'inactive'},
  {'name': 'MCP tools (deferred)', 'tokens': 19502, 'color': 'inactive', 'isDeferred': true},
  {'name': 'System tools (deferred)', 'tokens': 25699, 'color': 'inactive', 'isDeferred': true},
  {'name': 'Skills', 'tokens': 2059, 'color': 'warning'},
  {'name': 'Messages', 'tokens': 182796, 'color': 'purple_FOR_SUBAGENTS_ONLY'},
  {'name': 'Autocompact buffer', 'tokens': 33000, 'color': 'inactive'},
  {'name': 'Free space', 'tokens': 117058, 'color': 'promptBorder'},
];

void main() {
  // The whole point of the split: the used rows are the reported total, so a
  // bar drawn from them lands on the headline percentage. Summing every row
  // instead gave 384.8k against a 355k window, which is what filled the bar
  // to roughly twice the stated usage.
  test('used rows alone account for the reported total', () {
    final breakdown = classifyContextCategories(_withKind);
    expect(breakdown.usedTokens, 6575 + 12081 + 303 + 2990 + 3858 + 70248);
    expect(breakdown.deferredTokens, 19199 + 25403);
    expect(breakdown.bufferTokens, 33000);
    expect(breakdown.freeTokens, 225945);
    expect(
      breakdown.usedTokens + breakdown.bufferTokens + breakdown.freeTokens,
      355000,
    );
  });

  test('an older CLI without kind is classified the same way', () {
    final breakdown = classifyContextCategories(_withoutKind);
    expect(breakdown.usedTokens, 6265 + 13822 + 2059 + 182796);
    expect(breakdown.deferredTokens, 19502 + 25699);
    expect(breakdown.bufferTokens, 33000);
    expect(breakdown.freeTokens, 117058);
  });

  test('categories are ordered largest first', () {
    final breakdown = classifyContextCategories(_withKind);
    expect(breakdown.used.first.name, 'Messages');
    expect(
      breakdown.used.map((c) => c.tokens),
      orderedEquals(
        breakdown.used.map((c) => c.tokens).toList()
          ..sort((a, b) => b.compareTo(a)),
      ),
    );
  });

  // The SDK sends terminal theme tokens, several rows sharing one, so parsing
  // them as colours left every swatch the same fallback grey.
  test('each category gets a distinct colour of its own', () {
    final breakdown = classifyContextCategories(_withKind);
    final colors = breakdown.used.map((c) => c.color).toSet();
    expect(colors.length, breakdown.used.length);
  });

  test('a category keeps its colour when the others change', () {
    final full = classifyContextCategories(_withKind);
    final trimmed = classifyContextCategories(
      _withKind.where((c) => c['name'] != 'Skills').toList(),
    );
    Object colorOf(ContextBreakdown b, String name) =>
        b.used.firstWhere((c) => c.name == name).color;
    expect(colorOf(trimmed, 'Messages'), colorOf(full, 'Messages'));
    expect(colorOf(trimmed, 'Memory files'), colorOf(full, 'Memory files'));
  });

  test('zero-token and malformed rows are dropped', () {
    final breakdown = classifyContextCategories([
      {'name': 'Messages', 'tokens': 10, 'kind': 'used'},
      {'name': 'Empty', 'tokens': 0, 'kind': 'used'},
      'not a row',
    ]);
    expect(breakdown.used.length, 1);
    expect(breakdown.usedTokens, 10);
  });

  test('a session with no categories reports empty', () {
    expect(classifyContextCategories(null).isEmpty, isTrue);
    expect(classifyContextCategories(const []).isEmpty, isTrue);
  });
}
