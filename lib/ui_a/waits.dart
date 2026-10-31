import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/composer_attachment.dart';
import '../models/computer_access.dart';
import '../models/device_registry.dart';
import '../services/window_security_service.dart';
import 'board.dart' show waitKindLabel;
import 'bits.dart';
import 'data.dart';
import 'theme.dart';

/// The answer surface for one wait. Same widget in the session dock and in
/// the desktop's wait view, so an answer looks the same everywhere.
class WaitCard extends StatelessWidget {
  const WaitCard({super.key, required this.wait});

  final TowerWait wait;

  @override
  Widget build(BuildContext context) {
    final m = wait.message;
    return switch (wait.kind) {
      WaitKind.question || WaitKind.approval when m != null => QuestionCard(
        message: m,
        key: ValueKey(m.id),
      ),
      WaitKind.secret when m != null => SecretCard(message: m, key: ValueKey(m.id)),
      WaitKind.access when m != null => AccessCard(message: m, key: ValueKey(m.id)),
      WaitKind.device when wait.device != null => DeviceCard(device: wait.device!),
      _ => SignInCard(wait: wait),
    };
  }
}

/// Header line shared by every card: kind, age or countdown.
class _CardHead extends StatelessWidget {
  const _CardHead({required this.kind, this.since, this.expires, this.extra});

  final WaitKind kind;
  final DateTime? since;
  final DateTime? expires;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Row(
      children: [
        LiveMark(color: p.wait),
        const SizedBox(width: 8),
        Text(waitKindLabel(kind).toUpperCase(), style: Ts.label(p, p.wait)),
        if (extra != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              extra!,
              style: Ts.meta(p),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ] else
          const Spacer(),
        if (expires != null)
          Countdown(expires!, style: Ts.mono(p, color: p.wait, size: 11.5))
        else if (since != null)
          Text(agoText(since!), style: Ts.mono(p, size: 11.5)),
      ],
    );
  }
}

class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.message});

  final ChatMessage message;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  /// Chosen labels per question text.
  final Map<String, Set<String>> _picked = {};
  final Map<String, TextEditingController> _other = {};
  bool _sending = false;

  @override
  void dispose() {
    for (final c in _other.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _otherFor(String q) =>
      _other.putIfAbsent(q, TextEditingController.new);

  List<QuestionItem> get _items => widget.message.questions ?? const [];

  /// One single-select question answers on the first tap.
  bool get _instant =>
      _items.length == 1 && !_items.first.multiSelect && _items.first.options.isNotEmpty;

  Map<String, String> _answers() {
    final out = <String, String>{};
    for (final q in _items) {
      final typed = _other[q.question]?.text.trim() ?? '';
      final picked = _picked[q.question] ?? const <String>{};
      final parts = [...picked, if (typed.isNotEmpty) typed];
      if (parts.isNotEmpty) out[q.question] = parts.join(', ');
    }
    return out;
  }

  Future<void> _send(Map<String, String> answers) async {
    if (answers.isEmpty || _sending) return;
    setState(() => _sending = true);
    await context.read<TowerData>().answerQuestion(
      widget.message.questionId ?? '',
      answers,
    );
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final m = widget.message;
    final email = m.emailPreview;
    final ready = _answers().length == _items.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHead(
          kind: WaitKind.question,
          since: m.timestamp,
          extra: m.asyncQuestion ? 'answer starts a new turn' : null,
        ),
        if (email != null) _EmailPreview(email: email),
        for (final q in _items) ...[
          const SizedBox(height: 10),
          if ((q.header ?? '').isNotEmpty)
            Text(q.header!.toUpperCase(), style: Ts.label(p, p.muted)),
          const SizedBox(height: 2),
          Text(q.question, style: Ts.title(p).copyWith(fontSize: 15, height: 1.3)),
          const SizedBox(height: 8),
          for (final o in q.options)
            _OptionRow(
              option: o,
              multi: q.multiSelect,
              picked: _picked[q.question]?.contains(o.label) ?? false,
              onTap: _sending
                  ? null
                  : () {
                      if (_instant) {
                        unawaited(_send({q.question: o.label}));
                        return;
                      }
                      setState(() {
                        final set = _picked.putIfAbsent(q.question, () => {});
                        if (q.multiSelect) {
                          set.contains(o.label) ? set.remove(o.label) : set.add(o.label);
                        } else {
                          set
                            ..clear()
                            ..add(o.label);
                        }
                      });
                    },
            ),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: p.line)),
            child: TextField(
              controller: _otherFor(q.question),
              minLines: 1,
              maxLines: 4,
              style: Ts.body(p),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: q.options.isEmpty ? 'Answer' : 'Other answer or context',
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
              onSubmitted: _instant
                  ? (v) => _send({if (v.trim().isNotEmpty) q.question: v.trim()})
                  : null,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Act(
              _sending ? 'Sending' : 'Send answer',
              filled: true,
              color: p.wait,
              onTap: (_instant ? _answers().isNotEmpty : ready) && !_sending
                  ? () => _send(_answers())
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.multi,
    required this.picked,
    required this.onTap,
  });

  final QuestionOption option;
  final bool multi;
  final bool picked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        decoration: BoxDecoration(
          color: picked ? p.wait.withValues(alpha: 0.14) : null,
          border: Border.all(color: picked ? p.wait : p.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              multi
                  ? (picked ? Icons.check_box : Icons.check_box_outline_blank)
                  : (picked ? Icons.radio_button_checked : Icons.arrow_forward),
              size: 16,
              color: picked ? p.wait : p.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.label, style: Ts.title(p)),
                  if ((option.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(option.description!, style: Ts.meta(p)),
                  ],
                  if ((option.preview ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      color: p.raised,
                      child: Text(
                        option.preview!,
                        maxLines: 12,
                        overflow: TextOverflow.ellipsis,
                        style: Ts.mono(p, color: p.text, size: 11.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailPreview extends StatelessWidget {
  const _EmailPreview({required this.email});
  final Map<String, String> email;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    Widget field(String k, String label) {
      final v = email[k] ?? '';
      if (v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$label  ', style: Ts.label(p, p.muted)),
              TextSpan(text: v, style: Ts.body(p)),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      color: p.raised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          field('to', 'TO'),
          field('cc', 'CC'),
          field('subject', 'SUBJECT'),
          const SizedBox(height: 6),
          Text(
            email['body'] ?? '',
            maxLines: 14,
            overflow: TextOverflow.ellipsis,
            style: Ts.body(p),
          ),
        ],
      ),
    );
  }
}

/// Secure entry for a secret the agent asked for. Screenshots are blocked
/// while it is on screen and the field keeps no suggestions or history.
class SecretCard extends StatefulWidget {
  const SecretCard({super.key, required this.message});

  final ChatMessage message;

  @override
  State<SecretCard> createState() => _SecretCardState();
}

class _SecretCardState extends State<SecretCard> {
  final _value = TextEditingController();
  bool _show = false;

  @override
  void initState() {
    super.initState();
    unawaited(WindowSecurityService.enableScreenshotProtection());
  }

  @override
  void dispose() {
    _value.dispose();
    unawaited(WindowSecurityService.disableScreenshotProtection());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final m = widget.message;
    final input = m.toolInput ?? const <String, dynamic>{};
    final label = input['label']?.toString() ?? 'Secret';
    final env = input['envHint']?.toString() ?? '';
    final scope = input['scope']?.toString() ?? 'session';
    final multiline = input['multiline'] == true;
    final requestId = m.questionId ?? '';
    final lower = label.toLowerCase();
    final matches = data.storedSecrets
        .where(
          (s) =>
              s.label.toLowerCase().contains(lower) ||
              lower.contains(s.label.toLowerCase()) ||
              (env.isNotEmpty && s.envHint == env),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHead(kind: WaitKind.secret, since: m.timestamp),
        const SizedBox(height: 8),
        Text(label, style: Ts.title(p).copyWith(fontSize: 15)),
        if ((input['reason']?.toString() ?? '').isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(input['reason'].toString(), style: Ts.meta(p)),
        ],
        const SizedBox(height: 6),
        Text(
          [if (env.isNotEmpty) '\$$env', 'scope $scope'].join('   '),
          style: Ts.mono(p, size: 11.5),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(border: Border.all(color: p.wait)),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _value,
                  obscureText: !_show && !multiline,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: multiline
                      ? TextInputType.multiline
                      : TextInputType.visiblePassword,
                  minLines: 1,
                  maxLines: multiline ? 6 : 1,
                  style: Ts.mono(p, color: p.text, size: 13),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Value',
                    contentPadding: EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
              if (!multiline)
                IconButton(
                  tooltip: _show ? 'Hide' : 'Show',
                  onPressed: () => setState(() => _show = !_show),
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility, size: 18),
                ),
            ],
          ),
        ),
        if (matches.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('STORED', style: Ts.label(p, p.muted)),
          for (final s in matches.take(3))
            _StoredSecretRow(
              secret: s,
              onUse: () => data.useStoredSecret(requestId, s),
            ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Act('Cancel', color: p.muted, onTap: () => data.cancelSecret(requestId)),
            const Spacer(),
            Act(
              'Save to computer',
              filled: true,
              color: p.wait,
              onTap: _value.text.isEmpty
                  ? null
                  : () {
                      data.submitSecret(requestId, _value.text);
                      _value.clear();
                    },
            ),
          ],
        ),
      ],
    );
  }
}

class _StoredSecretRow extends StatelessWidget {
  const _StoredSecretRow({required this.secret, required this.onUse});
  final SecretMetadata secret;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return InkWell(
      onTap: onUse,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.key, size: 14, color: p.muted),
            const SizedBox(width: 8),
            Expanded(child: Text(secret.label, style: Ts.body(p))),
            Text(secret.scope, style: Ts.mono(p, size: 11)),
            const SizedBox(width: 10),
            Text('use', style: Ts.mono(p, color: p.accent, size: 12)),
          ],
        ),
      ),
    );
  }
}

/// An agent wants to act on another computer, or to link to it.
class AccessCard extends StatefulWidget {
  const AccessCard({super.key, required this.message});
  final ChatMessage message;

  @override
  State<AccessCard> createState() => _AccessCardState();
}

class _AccessCardState extends State<AccessCard> {
  ComputerAccess? _access;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.read<TowerData>();
    final r = ComputerAccessRequest.fromJson(widget.message.toolInput);
    if (r == null) return const SizedBox.shrink();
    final access = _access ?? r.access;
    void decide(String decision) => unawaited(
      data.answerAccess(r.requestId, decision, access: r.isLink ? access : null),
    );
    Widget box(String label, bool on, ComputerAccess Function(bool) next) => InkWell(
      onTap: () => setState(() => _access = next(!on)),
      child: Padding(
        padding: const EdgeInsets.only(right: 14, top: 4, bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
              color: on ? p.wait : p.muted,
            ),
            const SizedBox(width: 6),
            Text(label, style: Ts.body(p)),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHead(
          kind: WaitKind.access,
          since: widget.message.timestamp,
          expires: r.expiresAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(r.expiresAt)
              : null,
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            style: Ts.title(p).copyWith(fontSize: 15, height: 1.3),
            children: [
              TextSpan(text: r.askerLabel),
              TextSpan(text: r.isLink ? '  link to  ' : '  ${r.actionLabel.toLowerCase()} on  ', style: Ts.body(p).copyWith(color: p.muted)),
              TextSpan(text: r.targetName),
            ],
          ),
        ),
        if (r.summary.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: p.raised,
            child: Text(
              r.summary,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: Ts.mono(p, color: p.text, size: 12),
            ),
          ),
        ],
        if (r.reason.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(r.reason, style: Ts.meta(p)),
        ],
        if (r.isLink) ...[
          const SizedBox(height: 6),
          Wrap(
            children: [
              box('Read', access.read, (v) => ComputerAccess(read: v, agents: access.agents, commands: access.commands)),
              box('Commands', access.commands, (v) => ComputerAccess(read: access.read, agents: access.agents, commands: v)),
              box('Agents', access.agents, (v) => ComputerAccess(read: access.read, agents: v, commands: access.commands)),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            Act('Deny', color: p.fail, onTap: () => decide('deny')),
            if (!r.isLink) ...[
              Act('Once', color: p.wait, onTap: () => decide('once')),
              Act(
                'This chat',
                filled: true,
                color: p.wait,
                onTap: () => decide('chat'),
              ),
            ] else ...[
              if (r.hasAction)
                Act('This action', color: p.wait, onTap: () => decide('action')),
              Act('Today', color: p.wait, onTap: () => decide('today')),
              Act('Link', filled: true, color: p.wait, onTap: () => decide('linked')),
            ],
          ],
        ),
      ],
    );
  }
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.device});
  final PendingDevice device;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.read<TowerData>();
    final computer = data.computers.where((c) => c.id == device.serverId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHead(kind: WaitKind.device, extra: computer?.name),
        const SizedBox(height: 8),
        Text('${device.name}  ${device.platform}', style: Ts.title(p).copyWith(fontSize: 15)),
        const SizedBox(height: 8),
        Text(
          device.code,
          style: Ts.mono(p, color: p.text, size: 26).copyWith(letterSpacing: 6),
        ),
        const SizedBox(height: 4),
        Text('Match this code with the new device', style: Ts.meta(p)),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Act('Deny', color: p.fail, onTap: () => data.denyDevice(device)),
            const SizedBox(width: 8),
            Act('Approve', filled: true, color: p.wait, onTap: () => data.approveDevice(device)),
          ],
        ),
      ],
    );
  }
}

/// Sign-ins: connected-app links, harness and MCP re-auth, private
/// integrations. Opening a plain link works; finishing a flow is not wired.
class SignInCard extends StatelessWidget {
  const SignInCard({super.key, required this.wait});
  final TowerWait wait;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final url = wait.message?.toolOutput ?? wait.message?.authStartUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHead(kind: wait.kind, since: wait.since),
        const SizedBox(height: 8),
        Text(wait.title, style: Ts.title(p).copyWith(fontSize: 15)),
        if (wait.detail.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(wait.detail, style: Ts.meta(p), maxLines: 4, overflow: TextOverflow.ellipsis),
        ],
        if (url != null && url.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(url, style: Ts.mono(p, size: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            if (url != null && url.startsWith('http'))
              Act(
                'Open link',
                color: p.wait,
                onTap: () => unawaited(
                  launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                ),
              ),
            Stubbed(child: Act('Finish sign-in', filled: true, color: p.wait, onTap: () {})),
          ],
        ),
      ],
    );
  }
}
