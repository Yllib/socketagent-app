/// One model a harness offers: the id sent to the server and the name shown.
class ModelChoice {
  const ModelChoice(this.value, this.label);

  final String value;
  final String label;
}

/// Reads a `model_catalog` reply's models. Entries without an id are skipped,
/// and so is Claude's `default` alias, which editors offer as their own
/// "harness default" choice.
List<ModelChoice> parseModelCatalog(Object? raw) {
  if (raw is! List) return const [];
  final choices = <ModelChoice>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final value = entry['value'] ?? entry['id'];
    if (value is! String || value.isEmpty || value == 'default') continue;
    final name = entry['displayName'];
    choices.add(
      ModelChoice(value, name is String && name.isNotEmpty ? name : value),
    );
  }
  return choices;
}
