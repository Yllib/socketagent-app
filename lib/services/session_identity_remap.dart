bool moveSessionSetMember(Set<String> values, String oldId, String newId) {
  if (oldId == newId || !values.remove(oldId)) return false;
  values.add(newId);
  return true;
}

bool moveSessionMapEntry<T>(Map<String, T> values, String oldId, String newId) {
  if (oldId == newId || !values.containsKey(oldId)) return false;
  final value = values.remove(oldId) as T;
  values.putIfAbsent(newId, () => value);
  return true;
}

String? replacementSessionTitle(String? previousTitle, String? serverTitle) {
  final previous = previousTitle?.trim() ?? '';
  if (previous.isNotEmpty && previous != 'Untitled') return previousTitle;
  return serverTitle;
}
