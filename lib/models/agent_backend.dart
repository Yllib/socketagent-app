/// The agent programs a SocketAgent server drives, by wire name.
const agentBackends = ['claude', 'codex', 'gemini'];

/// Whether [value] is a backend this app knows.
bool isAgentBackend(Object? value) => agentBackends.contains(value);

/// The short name people see. Unknown values read as Claude, the default
/// backend, like older sessions saved without one.
String backendName(String? backend) => switch (backend) {
  'codex' => 'Codex',
  'gemini' => 'Gemini',
  _ => 'Claude',
};
