/// The one thing worth saying about a computer's backends.
///
/// A backend that is not signed in is not a fault when the other one works.
/// Most installs deliberately use only Claude or only Codex, and flagging the
/// unused one left those computers permanently warning about a backend their
/// owner never intended to set up. The failure that matters is having no way
/// to run a turn at all.
///
/// Returns the health entry to surface, a synthesized summary when nothing is
/// signed in, or null when there is nothing to say.
Map<String, dynamic>? backendWarningFor(List<Map<String, dynamic>> health) {
  if (health.isEmpty) return null;

  if (health.any((item) => item['severity'] == 'ok')) {
    // Something can run a turn. A degraded-but-working backend still deserves
    // a nudge; a dead one the owner does not use does not.
    for (final item in health) {
      if (item['severity'] == 'warning') return item;
    }
    return null;
  }

  final errors = health.where((item) => item['severity'] == 'error').toList();
  if (errors.isNotEmpty && errors.every((item) => item['kind'] == 'auth')) {
    return <String, dynamic>{
      'backend': 'none',
      'severity': 'error',
      'kind': 'auth',
      'label': 'No backend signed in',
      'reason': 'Neither Claude nor Codex is signed in on this computer.',
    };
  }

  // Nothing usable, and at least one failure is not about signing in, so the
  // specific fault is more useful than a summary that would misattribute it.
  for (final item in health) {
    if (item['severity'] == 'error') return item;
  }
  for (final item in health) {
    if (item['severity'] == 'warning') return item;
  }
  return null;
}
