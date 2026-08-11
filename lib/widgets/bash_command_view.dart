import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum ShellTokenKind {
  command,
  flag,
  string,
  variable,
  operator,
  assignment,
  comment,
  word,
  whitespace,
}

class ShellToken {
  const ShellToken(this.text, this.kind);

  final String text;
  final ShellTokenKind kind;
}

class ShellCommandInfo {
  const ShellCommandInfo({
    required this.name,
    required this.summary,
    required this.category,
  });

  final String name;
  final String summary;
  final String category;
}

const _commandDescriptions = <String, ShellCommandInfo>{
  'awk': ShellCommandInfo(
    name: 'awk',
    summary: 'Processes text as records and fields using small programs.',
    category: 'Text processing',
  ),
  'bash': ShellCommandInfo(
    name: 'bash',
    summary: 'Runs commands using the GNU Bourne Again Shell.',
    category: 'Shell',
  ),
  'cat': ShellCommandInfo(
    name: 'cat',
    summary: 'Prints or joins the contents of files.',
    category: 'Files',
  ),
  'cd': ShellCommandInfo(
    name: 'cd',
    summary: 'Changes the shell\'s current working directory.',
    category: 'Shell',
  ),
  'chmod': ShellCommandInfo(
    name: 'chmod',
    summary: 'Changes file or directory permission bits.',
    category: 'Files',
  ),
  'chown': ShellCommandInfo(
    name: 'chown',
    summary: 'Changes the owner or group of files and directories.',
    category: 'Files',
  ),
  'cmake': ShellCommandInfo(
    name: 'cmake',
    summary: 'Configures and generates cross-platform build systems.',
    category: 'Build',
  ),
  'command': ShellCommandInfo(
    name: 'command',
    summary: 'Runs or identifies a command while bypassing shell functions.',
    category: 'Shell',
  ),
  'cp': ShellCommandInfo(
    name: 'cp',
    summary: 'Copies files and directories.',
    category: 'Files',
  ),
  'curl': ShellCommandInfo(
    name: 'curl',
    summary: 'Transfers data to or from URLs using protocols such as HTTP.',
    category: 'Network',
  ),
  'dart': ShellCommandInfo(
    name: 'dart',
    summary: 'Runs Dart programs and Dart development commands.',
    category: 'Development',
  ),
  'docker': ShellCommandInfo(
    name: 'docker',
    summary: 'Builds, runs, and manages containers and container images.',
    category: 'Containers',
  ),
  'echo': ShellCommandInfo(
    name: 'echo',
    summary: 'Writes its arguments to standard output.',
    category: 'Shell',
  ),
  'env': ShellCommandInfo(
    name: 'env',
    summary: 'Displays or modifies environment variables for a command.',
    category: 'Shell',
  ),
  'find': ShellCommandInfo(
    name: 'find',
    summary: 'Searches directory trees using names, types, times, and actions.',
    category: 'Search',
  ),
  'flutter': ShellCommandInfo(
    name: 'flutter',
    summary: 'Builds, tests, runs, and manages Flutter applications.',
    category: 'Development',
  ),
  'gh': ShellCommandInfo(
    name: 'gh',
    summary: 'Works with GitHub repositories, issues, pull requests, and runs.',
    category: 'Version control',
  ),
  'git': ShellCommandInfo(
    name: 'git',
    summary:
        'Tracks source history, branches, commits, and remote repositories.',
    category: 'Version control',
  ),
  'grep': ShellCommandInfo(
    name: 'grep',
    summary:
        'Searches input for lines matching a text or regular-expression pattern.',
    category: 'Search',
  ),
  'head': ShellCommandInfo(
    name: 'head',
    summary: 'Prints the beginning of files or streamed input.',
    category: 'Text processing',
  ),
  'journalctl': ShellCommandInfo(
    name: 'journalctl',
    summary: 'Queries logs collected by the systemd journal.',
    category: 'System',
  ),
  'jq': ShellCommandInfo(
    name: 'jq',
    summary: 'Filters, transforms, and formats JSON data.',
    category: 'Text processing',
  ),
  'kill': ShellCommandInfo(
    name: 'kill',
    summary: 'Sends a signal to one or more processes.',
    category: 'Processes',
  ),
  'kubectl': ShellCommandInfo(
    name: 'kubectl',
    summary: 'Inspects and changes resources in Kubernetes clusters.',
    category: 'Containers',
  ),
  'ls': ShellCommandInfo(
    name: 'ls',
    summary: 'Lists files and directories.',
    category: 'Files',
  ),
  'make': ShellCommandInfo(
    name: 'make',
    summary: 'Runs build rules and dependency-based automation from makefiles.',
    category: 'Build',
  ),
  'mkdir': ShellCommandInfo(
    name: 'mkdir',
    summary: 'Creates directories.',
    category: 'Files',
  ),
  'mv': ShellCommandInfo(
    name: 'mv',
    summary: 'Moves or renames files and directories.',
    category: 'Files',
  ),
  'node': ShellCommandInfo(
    name: 'node',
    summary: 'Runs JavaScript programs using the Node.js runtime.',
    category: 'Development',
  ),
  'nohup': ShellCommandInfo(
    name: 'nohup',
    summary: 'Runs a command so it can continue after its terminal closes.',
    category: 'Processes',
  ),
  'npm': ShellCommandInfo(
    name: 'npm',
    summary: 'Installs packages and runs scripts in Node.js projects.',
    category: 'Development',
  ),
  'npx': ShellCommandInfo(
    name: 'npx',
    summary: 'Runs a command supplied by an npm package.',
    category: 'Development',
  ),
  'powershell': ShellCommandInfo(
    name: 'powershell',
    summary: 'Runs commands and scripts using Microsoft PowerShell.',
    category: 'Shell',
  ),
  'printf': ShellCommandInfo(
    name: 'printf',
    summary: 'Writes formatted text to standard output.',
    category: 'Shell',
  ),
  'ps': ShellCommandInfo(
    name: 'ps',
    summary: 'Displays information about running processes.',
    category: 'Processes',
  ),
  'python': ShellCommandInfo(
    name: 'python',
    summary: 'Runs Python programs and modules.',
    category: 'Development',
  ),
  'python3': ShellCommandInfo(
    name: 'python3',
    summary: 'Runs Python 3 programs and modules.',
    category: 'Development',
  ),
  'rg': ShellCommandInfo(
    name: 'rg (ripgrep)',
    summary:
        'Recursively searches files using fast regular-expression matching.',
    category: 'Search',
  ),
  'rm': ShellCommandInfo(
    name: 'rm',
    summary: 'Removes files or directory trees.',
    category: 'Files',
  ),
  'rsync': ShellCommandInfo(
    name: 'rsync',
    summary:
        'Efficiently synchronizes files locally or over a remote transport.',
    category: 'Files',
  ),
  'scp': ShellCommandInfo(
    name: 'scp',
    summary: 'Copies files between machines over SSH.',
    category: 'Network',
  ),
  'sed': ShellCommandInfo(
    name: 'sed',
    summary: 'Transforms text streams using editing expressions.',
    category: 'Text processing',
  ),
  'sh': ShellCommandInfo(
    name: 'sh',
    summary: 'Runs commands using a POSIX-compatible shell.',
    category: 'Shell',
  ),
  'sort': ShellCommandInfo(
    name: 'sort',
    summary: 'Sorts lines of text.',
    category: 'Text processing',
  ),
  'ssh': ShellCommandInfo(
    name: 'ssh',
    summary: 'Opens an encrypted remote shell or runs a remote command.',
    category: 'Network',
  ),
  'sudo': ShellCommandInfo(
    name: 'sudo',
    summary:
        'Runs another command with another user\'s privileges, commonly root.',
    category: 'System',
  ),
  'systemctl': ShellCommandInfo(
    name: 'systemctl',
    summary: 'Inspects and controls systemd services and system state.',
    category: 'System',
  ),
  'tail': ShellCommandInfo(
    name: 'tail',
    summary: 'Prints or follows the end of files and streamed input.',
    category: 'Text processing',
  ),
  'timeout': ShellCommandInfo(
    name: 'timeout',
    summary:
        'Runs another command with a time limit and stops it if the limit is reached.',
    category: 'Processes',
  ),
  'sshpass': ShellCommandInfo(
    name: 'sshpass',
    summary:
        'Supplies a password non-interactively to SSH and related commands.',
    category: 'Network',
  ),
  'true': ShellCommandInfo(
    name: 'true',
    summary: 'Returns a successful exit status without doing other work.',
    category: 'Shell',
  ),
  'false': ShellCommandInfo(
    name: 'false',
    summary: 'Returns a failed exit status without doing other work.',
    category: 'Shell',
  ),
  'sleep': ShellCommandInfo(
    name: 'sleep',
    summary: 'Waits for a specified amount of time.',
    category: 'Processes',
  ),
  'esptool': ShellCommandInfo(
    name: 'esptool',
    summary: 'Communicates with and flashes Espressif ESP-series chips.',
    category: 'Development',
  ),
  'tar': ShellCommandInfo(
    name: 'tar',
    summary: 'Creates, extracts, and inspects archive files.',
    category: 'Files',
  ),
  'tee': ShellCommandInfo(
    name: 'tee',
    summary: 'Copies streamed input to both output and one or more files.',
    category: 'Text processing',
  ),
  'time': ShellCommandInfo(
    name: 'time',
    summary:
        'Measures how long another command takes and reports resource use.',
    category: 'Processes',
  ),
  'uniq': ShellCommandInfo(
    name: 'uniq',
    summary: 'Filters adjacent duplicate lines, usually after sorting.',
    category: 'Text processing',
  ),
  'wc': ShellCommandInfo(
    name: 'wc',
    summary: 'Counts lines, words, characters, or bytes.',
    category: 'Text processing',
  ),
  'wget': ShellCommandInfo(
    name: 'wget',
    summary: 'Downloads files and web resources from URLs.',
    category: 'Network',
  ),
  'xargs': ShellCommandInfo(
    name: 'xargs',
    summary: 'Builds and runs commands using items read from standard input.',
    category: 'Shell',
  ),
};

const _lineBreakOperators = {'&&', '||', '|', ';'};

const _simpleCommandWrappers = {
  'env',
  'nohup',
  'sudo',
  'time',
  'nice',
  'setsid',
  'stdbuf',
};

const _sshOptionsWithValues = {
  '-b',
  '-c',
  '-D',
  '-E',
  '-e',
  '-F',
  '-I',
  '-i',
  '-J',
  '-L',
  '-l',
  '-m',
  '-O',
  '-o',
  '-p',
  '-Q',
  '-R',
  '-S',
  '-W',
  '-w',
};

String shellExecutableName(String command) {
  var value = command.trim();
  if (value.startsWith('\\')) value = value.substring(1);
  final slash = value.lastIndexOf('/');
  if (slash >= 0) value = value.substring(slash + 1);
  return value;
}

ShellCommandInfo commandInfoFor(String command) {
  final executable = shellExecutableName(command);
  return _commandDescriptions[executable] ??
      ShellCommandInfo(
        name: executable.isEmpty ? command : executable,
        summary:
            'Invokes the `${command.trim()}` executable. SocketAgent does not yet have a built-in description for it.',
        category: 'Command',
      );
}

String stripRoutineShellWrapper(String command) {
  final trimmed = command.trim();
  final match = RegExp(
    r'^(?:(?:/usr/bin/)?env\s+)?(?:(?:/usr)?/bin/)?(?:bash|sh)\s+-[A-Za-z]*c[A-Za-z]*\s+([\s\S]+)$',
  ).firstMatch(trimmed);
  if (match == null) return trimmed;
  var inner = match.group(1)!.trim();
  if (inner.length >= 2) {
    final first = inner.codeUnitAt(0);
    final last = inner.codeUnitAt(inner.length - 1);
    if ((first == 0x27 && last == 0x27) || (first == 0x22 && last == 0x22)) {
      inner = inner.substring(1, inner.length - 1);
    }
  }
  return inner;
}

String shellCommandSummary(String command) {
  final tokens = tokenizeShellCommand(stripRoutineShellWrapper(command));
  final buffer = StringBuffer();
  for (final token in tokens) {
    if (token.kind == ShellTokenKind.operator &&
        {'&&', '||', ';'}.contains(token.text)) {
      break;
    }
    if (token.text.contains('\n')) {
      buffer.write(token.text.split('\n').first);
      break;
    }
    buffer.write(token.text);
  }
  return buffer.toString().trim();
}

List<ShellToken> tokenizeShellCommand(String command) {
  final tokens = <ShellToken>[];
  var index = 0;

  bool isOperatorStart(String character) =>
      '&|;()<>'.contains(character) || character == '`';

  while (index < command.length) {
    final char = command[index];

    if (RegExp(r'\s').hasMatch(char)) {
      final start = index++;
      while (index < command.length && RegExp(r'\s').hasMatch(command[index])) {
        index++;
      }
      final text = command.substring(start, index);
      tokens.add(ShellToken(text, ShellTokenKind.whitespace));
      continue;
    }

    if (char == '#' &&
        (index == 0 || RegExp(r'\s').hasMatch(command[index - 1]))) {
      final start = index++;
      while (index < command.length && command[index] != '\n') {
        index++;
      }
      tokens.add(
        ShellToken(command.substring(start, index), ShellTokenKind.comment),
      );
      continue;
    }

    if (char == '\'' || char == '"') {
      final quote = char;
      final start = index++;
      while (index < command.length) {
        if (command[index] == '\\' &&
            quote == '"' &&
            index + 1 < command.length) {
          index += 2;
          continue;
        }
        if (command[index] == quote) {
          index++;
          break;
        }
        index++;
      }
      tokens.add(
        ShellToken(command.substring(start, index), ShellTokenKind.string),
      );
      continue;
    }

    if (char == r'$') {
      final start = index++;
      if (index < command.length && command[index] == '{') {
        index++;
        while (index < command.length && command[index] != '}') {
          index++;
        }
        if (index < command.length) {
          index++;
        }
      } else if (index < command.length && command[index] == '(') {
        index++;
        tokens.add(
          ShellToken(command.substring(start, index), ShellTokenKind.operator),
        );
        continue;
      } else {
        while (index < command.length &&
            RegExp(r'[A-Za-z0-9_@#?!*$-]').hasMatch(command[index])) {
          index++;
        }
      }
      tokens.add(
        ShellToken(command.substring(start, index), ShellTokenKind.variable),
      );
      continue;
    }

    if (isOperatorStart(char)) {
      final candidates = ['&&', '||', '>>', '<<', ';;', '&>', '2>', '2>>'];
      var value = char;
      for (final candidate in candidates) {
        if (command.startsWith(candidate, index)) {
          value = candidate;
          break;
        }
      }
      tokens.add(ShellToken(value, ShellTokenKind.operator));
      index += value.length;
      continue;
    }

    final start = index;
    while (index < command.length &&
        !RegExp(r'\s').hasMatch(command[index]) &&
        command[index] != '\'' &&
        command[index] != '"' &&
        command[index] != r'$' &&
        !isOperatorStart(command[index])) {
      if (command[index] == '\\' && index + 1 < command.length) {
        index += 2;
      } else {
        index++;
      }
    }
    final value = command.substring(start, index);
    ShellTokenKind kind;
    if (value.startsWith('-') && !RegExp(r'^-\d+(?:\.\d+)?$').hasMatch(value)) {
      kind = ShellTokenKind.flag;
    } else if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(value)) {
      kind = ShellTokenKind.assignment;
    } else {
      kind = ShellTokenKind.word;
    }
    tokens.add(ShellToken(value, kind));
  }

  _classifyCommands(tokens);
  _expandNestedShellPayloads(tokens);
  return tokens;
}

bool _isControlOperator(ShellToken token) =>
    token.kind == ShellTokenKind.operator &&
    {'&&', '||', '|', ';', '(', r'$(', '`'}.contains(token.text);

bool _isSignificant(ShellToken token) =>
    token.kind != ShellTokenKind.whitespace &&
    token.kind != ShellTokenKind.comment;

int? _nextSignificant(List<ShellToken> tokens, int from, int end) {
  for (var index = from; index < end; index++) {
    if (_isSignificant(tokens[index])) return index;
  }
  return null;
}

int _segmentEnd(List<ShellToken> tokens, int from) {
  for (var index = from; index < tokens.length; index++) {
    if (_isControlOperator(tokens[index])) return index;
  }
  return tokens.length;
}

void _markCommand(List<ShellToken> tokens, int index) {
  final token = tokens[index];
  tokens[index] = ShellToken(token.text, ShellTokenKind.command);
  final executable = shellExecutableName(token.text);
  final end = _segmentEnd(tokens, index + 1);
  final nested = _wrappedCommandIndex(tokens, index, end, executable);
  if (nested != null) _markCommand(tokens, nested);
}

void _classifyCommands(List<ShellToken> tokens) {
  var expectCommand = true;
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (_isControlOperator(token)) {
      expectCommand = true;
      continue;
    }
    if (!expectCommand || !_isSignificant(token)) continue;
    if (token.kind == ShellTokenKind.assignment ||
        token.kind == ShellTokenKind.flag ||
        token.kind == ShellTokenKind.operator) {
      continue;
    }
    if (token.kind == ShellTokenKind.word) {
      _markCommand(tokens, index);
    }
    expectCommand = false;
  }
}

int? _wrappedCommandIndex(
  List<ShellToken> tokens,
  int wrapperIndex,
  int end,
  String executable,
) {
  if (executable == 'command') {
    // `command -v name` and `command -V name` inspect a name; they do not run it.
    final option = _nextSignificant(tokens, wrapperIndex + 1, end);
    if (option != null && {'-v', '-V'}.contains(tokens[option].text)) {
      return null;
    }
    return _firstCommandOperand(tokens, wrapperIndex + 1, end);
  }
  if (executable == 'timeout') {
    var cursor = wrapperIndex + 1;
    var foundDuration = false;
    while (true) {
      final current = _nextSignificant(tokens, cursor, end);
      if (current == null) return null;
      final text = tokens[current].text;
      cursor = current + 1;
      if (!foundDuration) {
        if ({'-k', '--kill-after', '-s', '--signal'}.contains(text)) {
          final value = _nextSignificant(tokens, cursor, end);
          if (value == null) return null;
          cursor = value + 1;
          continue;
        }
        if (text.startsWith('-')) continue;
        foundDuration = true;
        continue;
      }
      return tokens[current].kind == ShellTokenKind.word ? current : null;
    }
  }
  if (executable == 'sshpass') {
    var cursor = wrapperIndex + 1;
    while (true) {
      final current = _nextSignificant(tokens, cursor, end);
      if (current == null) return null;
      final text = tokens[current].text;
      cursor = current + 1;
      if ({'-p', '-f', '-d', '-P'}.contains(text)) {
        final value = _nextSignificant(tokens, cursor, end);
        if (value == null) return null;
        cursor = value + 1;
        continue;
      }
      if (text.startsWith('-')) continue;
      return tokens[current].kind == ShellTokenKind.word ? current : null;
    }
  }
  if (_simpleCommandWrappers.contains(executable)) {
    return _firstCommandOperand(tokens, wrapperIndex + 1, end);
  }
  return null;
}

int? _firstCommandOperand(List<ShellToken> tokens, int from, int end) {
  var cursor = from;
  while (true) {
    final current = _nextSignificant(tokens, cursor, end);
    if (current == null) return null;
    final token = tokens[current];
    cursor = current + 1;
    if (token.kind == ShellTokenKind.flag ||
        token.kind == ShellTokenKind.assignment ||
        token.kind == ShellTokenKind.operator) {
      continue;
    }
    return token.kind == ShellTokenKind.word ? current : null;
  }
}

void _expandNestedShellPayloads(List<ShellToken> tokens) {
  for (var index = 0; index < tokens.length; index++) {
    if (tokens[index].kind != ShellTokenKind.command) continue;
    final executable = shellExecutableName(tokens[index].text);
    int? payloadIndex;
    if (executable == 'ssh') {
      payloadIndex = _sshPayloadIndex(
        tokens,
        index,
        _segmentEnd(tokens, index),
      );
    } else if ({'bash', 'sh'}.contains(executable)) {
      payloadIndex = _shellCPayloadIndex(
        tokens,
        index,
        _segmentEnd(tokens, index),
      );
    }
    if (payloadIndex == null) continue;
    final quoted = tokens[payloadIndex].text;
    if (quoted.length < 2) continue;
    final quote = quoted[0];
    if ((quote != "'" && quote != '"') || quoted[quoted.length - 1] != quote) {
      continue;
    }
    final inner = quoted.substring(1, quoted.length - 1);
    final replacement = <ShellToken>[
      ShellToken(quote, ShellTokenKind.string),
      ...tokenizeShellCommand(inner),
      ShellToken(quote, ShellTokenKind.string),
    ];
    tokens.replaceRange(payloadIndex, payloadIndex + 1, replacement);
    index = payloadIndex + replacement.length - 1;
  }
}

int? _shellCPayloadIndex(List<ShellToken> tokens, int command, int end) {
  var cursor = command + 1;
  while (true) {
    final current = _nextSignificant(tokens, cursor, end);
    if (current == null) return null;
    if (tokens[current].text.contains('c') &&
        tokens[current].text.startsWith('-')) {
      final payload = _nextSignificant(tokens, current + 1, end);
      return payload != null && tokens[payload].kind == ShellTokenKind.string
          ? payload
          : null;
    }
    cursor = current + 1;
  }
}

int? _sshPayloadIndex(List<ShellToken> tokens, int command, int end) {
  var cursor = command + 1;
  var foundDestination = false;
  while (true) {
    final current = _nextSignificant(tokens, cursor, end);
    if (current == null) return null;
    final token = tokens[current];
    cursor = current + 1;
    if (!foundDestination) {
      if (_sshOptionsWithValues.contains(token.text)) {
        final value = _nextSignificant(tokens, cursor, end);
        if (value == null) return null;
        cursor = value + 1;
        continue;
      }
      if (token.kind == ShellTokenKind.flag) continue;
      foundDestination = true;
      continue;
    }
    if (token.kind == ShellTokenKind.string) return current;
    // Unquoted remote commands are ambiguous, so leave them as arguments.
    return null;
  }
}

class BashCommandView extends StatefulWidget {
  const BashCommandView({super.key, required this.command});

  final String command;

  @override
  State<BashCommandView> createState() => _BashCommandViewState();
}

class _BashCommandViewState extends State<BashCommandView> {
  final Map<int, TapGestureRecognizer> _recognizers = {};
  late String _displayCommand;
  late List<ShellToken> _tokens;

  @override
  void initState() {
    super.initState();
    _prepareCommand();
  }

  @override
  void didUpdateWidget(covariant BashCommandView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.command != widget.command) {
      _prepareCommand();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _prepareCommand() {
    _disposeRecognizers();
    _displayCommand = stripRoutineShellWrapper(widget.command);
    _tokens = tokenizeShellCommand(_displayCommand);
    for (var index = 0; index < _tokens.length; index++) {
      final token = _tokens[index];
      if (token.kind != ShellTokenKind.command) continue;
      _recognizers[index] = TapGestureRecognizer()
        ..onTap = () => _showCommandInfo(token.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shouldBreak =
        _displayCommand.length > 72 || _displayCommand.contains('\n');
    final spans = <InlineSpan>[];
    var skipLeadingWhitespace = false;

    for (var index = 0; index < _tokens.length; index++) {
      final token = _tokens[index];
      if (skipLeadingWhitespace && token.kind == ShellTokenKind.whitespace) {
        if (token.text.contains('\n')) {
          spans.add(TextSpan(text: token.text));
        }
        skipLeadingWhitespace = false;
        continue;
      }
      skipLeadingWhitespace = false;

      spans.add(
        TextSpan(
          text: token.text,
          style: _styleFor(token.kind),
          recognizer: _recognizers[index],
        ),
      );
      if (shouldBreak &&
          token.kind == ShellTokenKind.operator &&
          _lineBreakOperators.contains(token.text)) {
        spans.add(const TextSpan(text: '\n  '));
        skipLeadingWhitespace = true;
      }
    }

    return SelectableText.rich(
      TextSpan(children: spans),
      key: const ValueKey<String>('bash-highlighted-command'),
      style: GoogleFonts.jetBrainsMono(
        fontSize: 11,
        height: 1.45,
        color: const Color(0xFFCDD6F4),
      ),
    );
  }

  TextStyle _styleFor(ShellTokenKind kind) {
    switch (kind) {
      case ShellTokenKind.command:
        return const TextStyle(
          color: Color(0xFF89B4FA),
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.underline,
          decorationColor: Color(0x6689B4FA),
        );
      case ShellTokenKind.flag:
        return const TextStyle(color: Color(0xFFCBA6F7));
      case ShellTokenKind.string:
        return const TextStyle(color: Color(0xFFA6E3A1));
      case ShellTokenKind.variable:
        return const TextStyle(color: Color(0xFFFAB387));
      case ShellTokenKind.operator:
        return const TextStyle(
          color: Color(0xFFF38BA8),
          fontWeight: FontWeight.w700,
        );
      case ShellTokenKind.assignment:
        return const TextStyle(color: Color(0xFF94E2D5));
      case ShellTokenKind.comment:
        return const TextStyle(
          color: Color(0xFF6C7086),
          fontStyle: FontStyle.italic,
        );
      case ShellTokenKind.word:
      case ShellTokenKind.whitespace:
        return const TextStyle(color: Color(0xFFCDD6F4));
    }
  }

  void _showCommandInfo(String command) {
    final info = commandInfoFor(command);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.terminal, color: Color(0xFF89B4FA)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      info.name,
                      key: const ValueKey<String>('bash-command-info-name'),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF89B4FA).withAlpha(28),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      info.category,
                      style: const TextStyle(
                        color: Color(0xFF89B4FA),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                info.summary,
                key: const ValueKey<String>('bash-command-info-summary'),
                style: Theme.of(sheetContext).textTheme.bodyLarge,
              ),
              if (command.contains('/')) ...[
                const SizedBox(height: 14),
                Text(
                  'Executable path',
                  style: Theme.of(sheetContext).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  command,
                  style: GoogleFonts.jetBrainsMono(
                    color: const Color(0xFFA6ADC8),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
