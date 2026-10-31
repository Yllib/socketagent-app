import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/composer_attachment.dart';
import '../../models/device_registry.dart' show PendingDevice;
import '../../models/message.dart';
import '../../services/window_security_service.dart';
import '../../util/format.dart';
import '../model/actions.dart';
import '../model/board_model.dart';
import '../model/session_model.dart';
import '../theme/ui_b_theme.dart';
import 'clock.dart';
import 'inbox_card.dart';
import 'primitives.dart';

/// Opens the full answer flow for an inbox item. On the phone it is a bottom
/// sheet; on the desktop a dialog, so the log stays visible beside it.
Future<void> openAnswerSheet(
  BuildContext context,
  InboxItem item,
  UiBActions actions,
  SessionView? session,
) {
  final body = AnswerSheet(item: item, actions: actions, session: session);
  if (Platform.isWindows || MediaQuery.sizeOf(context).width > 700) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: body,
    ),
  );
}

class AnswerSheet extends StatelessWidget {
  const AnswerSheet({
    super.key,
    required this.item,
    required this.actions,
    this.session,
  });
  final InboxItem item;
  final UiBActions actions;
  final SessionView? session;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final where = <String>[
      if (item.sessionTitle.isNotEmpty) item.sessionTitle,
      if (item.computerName.isNotEmpty) item.computerName,
      formatTimeAgo(item.since, now: UiBClockScope.read(context)),
      if (item.expiresAt case final e?)
        'expires ${formatTimeLeft(e.difference(UiBClockScope.read(context)))}',
    ];
    final Widget form = switch (item.kind) {
      InboxKind.question => QuestionForm(item: item, actions: actions),
      InboxKind.secret => SecretForm(
        item: item,
        actions: actions,
        inventory: session?.secretInventory ?? const [],
      ),
      InboxKind.access => AccessForm(item: item, actions: actions),
      InboxKind.device => DeviceForm(item: item, actions: actions),
      InboxKind.signIn => SignInForm(item: item, actions: actions),
      InboxKind.delivery => DeliveryForm(item: item, actions: actions),
      InboxKind.automation => AutomationForm(item: item, actions: actions),
      InboxKind.toolApproval => ToolApprovalForm(item: item),
      InboxKind.review => const StubForm(
        'Work review opens here. Approving and commenting on a review is not wired in this interface yet.',
      ),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.line)),
          ),
          child: Row(
            children: [
              Icon(inboxIcon(item.kind), size: 15, color: t.waiting),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inboxKindLabel(item.kind).toUpperCase(),
                      style: text.micro.copyWith(color: t.waiting),
                    ),
                    Text(
                      where.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.meta,
                    ),
                  ],
                ),
              ),
              if (!item.deliverable) Tag('computer offline', color: t.failed),
              IconBtn(
                Icons.close,
                size: 18,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: form,
          ),
        ),
      ],
    );
  }
}

/// All questions of one request. Single choice, multiple choice, a preview
/// per option when the agent sent one, and a free text field per question.
class QuestionForm extends StatefulWidget {
  const QuestionForm({super.key, required this.item, required this.actions});
  final InboxItem item;
  final UiBActions actions;

  @override
  State<QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<QuestionForm> {
  late final List<QuestionItem> _questions =
      widget.item.message?.questions ?? const [];
  late final List<Set<String>> _chosen = [
    for (final _ in _questions) <String>{},
  ];
  late final List<TextEditingController> _other = [
    for (final _ in _questions) TextEditingController(),
  ];
  bool _sending = false;

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete {
    for (var i = 0; i < _questions.length; i++) {
      if (_chosen[i].isEmpty && _other[i].text.trim().isEmpty) return false;
    }
    return _questions.isNotEmpty;
  }

  Future<void> _submit() async {
    final id = widget.item.message?.questionId;
    if (id == null) return;
    final answers = <String, String>{};
    for (var i = 0; i < _questions.length; i++) {
      final free = _other[i].text.trim();
      final parts = [..._chosen[i], if (free.isNotEmpty) free];
      answers[_questions[i].question] = parts.join(', ');
    }
    setState(() => _sending = true);
    await widget.actions.answerQuestion(id, answers);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.item.message?.emailPreview case final p?)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: t.line),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EMAIL PREVIEW', style: text.micro),
                for (final e in p.entries) KV(e.key, e.value),
              ],
            ),
          ),
        for (var i = 0; i < _questions.length; i++) ...[
          if (_questions[i].header case final h?)
            Text(h.toUpperCase(), style: text.micro.copyWith(color: t.accent)),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: SelectableText(
              _questions[i].question,
              style: text.body.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          for (final o in _questions[i].options) _option(context, i, o),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 10),
            child: TextField(
              controller: _other[i],
              style: text.body,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Your own answer',
                isDense: true,
              ),
            ),
          ),
        ],
        Row(
          children: [
            const Spacer(),
            FlatButton(
              _sending ? 'Sending' : 'Send answer',
              primary: true,
              onPressed: _complete && !_sending && widget.item.deliverable
                  ? _submit
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _option(BuildContext context, int qi, QuestionOption o) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final q = _questions[qi];
    final on = _chosen[qi].contains(o.label);
    final showPreview = o.preview != null && on;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (q.multiSelect) {
              on ? _chosen[qi].remove(o.label) : _chosen[qi].add(o.label);
            } else {
              _chosen[qi]
                ..clear()
                ..add(o.label);
            }
          }),
          borderRadius: BorderRadius.circular(5),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: on ? t.accent.withValues(alpha: 0.12) : t.raised,
              border: Border.all(color: on ? t.accent : t.line),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    q.multiSelect
                        ? (on
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank)
                        : (on
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off),
                    size: 15,
                    color: on ? t.accent : t.text3,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        o.label,
                        style: text.body.copyWith(fontWeight: FontWeight.w500),
                      ),
                      if (o.description case final d?)
                        Text(d, style: text.meta.copyWith(color: t.text2)),
                    ],
                  ),
                ),
                if (o.preview != null)
                  Icon(Icons.code, size: 13, color: t.text3),
              ],
            ),
          ),
        ),
        if (showPreview)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: t.raised,
              borderRadius: BorderRadius.circular(5),
            ),
            child: SelectableText(o.preview!, style: text.code),
          ),
      ],
    );
  }
}

/// Secure entry. Screenshots are blocked while the field is on screen, the
/// value is obscured until revealed, and nothing is echoed back after send.
class SecretForm extends StatefulWidget {
  const SecretForm({
    super.key,
    required this.item,
    required this.actions,
    required this.inventory,
  });
  final InboxItem item;
  final UiBActions actions;
  final List<SecretMetadata> inventory;

  @override
  State<SecretForm> createState() => _SecretFormState();
}

class _SecretFormState extends State<SecretForm> {
  final _value = TextEditingController();
  bool _reveal = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WindowSecurityService.enableScreenshotProtection();
  }

  @override
  void dispose() {
    _value.dispose();
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  String? get _requestId => widget.item.message?.questionId;

  Future<void> _submit() async {
    final id = _requestId;
    if (id == null || _value.text.isEmpty) return;
    setState(() => _sending = true);
    widget.actions.submitSecret(id, _value.text);
    _value.clear();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final input = widget.item.message?.toolInput ?? const {};
    final label = input['label']?.toString() ?? widget.item.title;
    final reason = input['reason']?.toString() ?? '';
    final env = input['envHint']?.toString() ?? '';
    final scope = input['scope']?.toString() ?? 'session';
    final stored = widget.inventory
        .where((s) => s.envHint == env || s.label == label)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: text.title),
        if (reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(reason, style: text.body),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 10),
          child: Wrap(
            spacing: 6,
            children: [
              if (env.isNotEmpty) Tag(env, color: t.info),
              Tag('kept for the $scope', color: t.text3),
              Tag('screenshots blocked', color: t.running),
            ],
          ),
        ),
        if (stored.isNotEmpty) ...[
          Text('STORED', style: text.micro),
          for (final s in stored)
            InkWell(
              onTap: _sending || _requestId == null
                  ? null
                  : () async {
                      setState(() => _sending = true);
                      widget.actions.useStoredSecret(_requestId!, s);
                      if (context.mounted) Navigator.of(context).maybePop();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(Icons.key_outlined, size: 13, color: t.text2),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('${s.label} · ${s.scope}', style: text.body),
                    ),
                    Text('use', style: text.meta.copyWith(color: t.accent)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _value,
          obscureText: !_reveal,
          autocorrect: false,
          enableSuggestions: false,
          autofocus: true,
          style: text.code,
          minLines: 1,
          maxLines: _reveal ? 6 : 1,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Paste or type the value',
            isDense: true,
            suffixIcon: IconBtn(
              _reveal
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
              tooltip: _reveal ? 'Hide' : 'Show',
              onPressed: () => setState(() => _reveal = !_reveal),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FlatButton(
              'Cancel request',
              danger: true,
              onPressed: _requestId == null
                  ? null
                  : () {
                      widget.actions.cancelSecret(_requestId!);
                      Navigator.of(context).maybePop();
                    },
            ),
            const Spacer(),
            FlatButton(
              _sending ? 'Sending' : 'Send securely',
              primary: true,
              onPressed:
                  _value.text.isEmpty || _sending || !widget.item.deliverable
                  ? null
                  : _submit,
            ),
          ],
        ),
      ],
    );
  }
}

/// A computer asking to act on another. Every grant scope is one tap.
class AccessForm extends StatelessWidget {
  const AccessForm({super.key, required this.item, required this.actions});
  final InboxItem item;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final input = item.message?.toolInput ?? const {};
    final source =
        (input['source'] is Map ? (input['source'] as Map)['name'] : null)
            ?.toString() ??
        'a computer';
    final target =
        (input['target'] is Map ? (input['target'] as Map)['name'] : null)
            ?.toString() ??
        'this computer';
    final action = input['action']?.toString() ?? '';
    final summary = input['summary']?.toString() ?? '';
    final reason = input['reason']?.toString() ?? '';
    final link = input['kind'] == 'link';
    final id = item.message?.questionId ?? item.id;
    Future<void> answer(String d) async {
      await actions.answerAccess(id, d);
      if (context.mounted) Navigator.of(context).maybePop();
    }

    Widget choice(
      String label,
      String hint,
      String decision, {
      bool danger = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: item.deliverable ? () => answer(decision) : null,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            border: Border.all(
              color: danger ? t.failed.withValues(alpha: 0.6) : t.line,
            ),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: text.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: danger ? t.failed : t.text,
                      ),
                    ),
                    Text(hint, style: text.meta),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: t.text3),
            ],
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ComputerTag(source),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward, size: 13, color: t.text3),
            ),
            ComputerTag(target),
            const SizedBox(width: 8),
            if (action.isNotEmpty) Tag(action, color: t.info),
          ],
        ),
        const SizedBox(height: 8),
        if (summary.isNotEmpty)
          SelectableText(
            summary,
            style: text.body.copyWith(fontWeight: FontWeight.w500),
          ),
        if (reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(reason, style: text.body2),
          ),
        const SizedBox(height: 12),
        if (link) ...[
          choice(
            'Link $source to $target',
            'Agents on $source can use $target from now on',
            'linked',
          ),
        ] else ...[
          choice('Allow once', 'Only this request', 'once'),
          choice(
            'Allow for this chat',
            'Anything $source asks in this session',
            'chat',
          ),
          choice(
            'Allow this action',
            'Any "$action" from $source until you revoke it',
            'action',
          ),
          choice(
            'Allow today',
            'Everything from $source until midnight',
            'today',
          ),
        ],
        choice('Deny', 'The agent is told no', 'deny', danger: true),
      ],
    );
  }
}

/// A phone or desktop asking to pair. The code must match what it shows.
class DeviceForm extends StatelessWidget {
  const DeviceForm({super.key, required this.item, required this.actions});
  final InboxItem item;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final d = item.payload;
    if (d is! PendingDevice) return const EmptyLine('Device request is gone');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${d.name} · ${d.platform}', style: text.title),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Approve only if this code is on the new device\'s screen.',
            style: text.body2,
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 14),
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.raised,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            d.code,
            style: text.title.copyWith(
              fontSize: 30 * text.scale,
              letterSpacing: 4,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Text(
          'key ${d.publicKey.length > 16 ? d.publicKey.substring(0, 16) : d.publicKey}…',
          style: text.meta,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FlatButton(
              'Deny',
              danger: true,
              onPressed: () async {
                await actions.denyDevice(d);
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
            const Spacer(),
            FlatButton(
              'Code matches, approve',
              primary: true,
              onPressed: () async {
                await actions.approveDevice(d);
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// An MCP server wants the user to sign in somewhere.
class SignInForm extends StatelessWidget {
  const SignInForm({super.key, required this.item, required this.actions});
  final InboxItem item;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final text = UiBText.of(context);
    final url = item.message?.toolOutput ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(item.title, style: text.title),
        if (item.detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(item.detail, style: text.body),
          ),
        if (url.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(url, style: text.code2),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            FlatButton(
              'Open sign-in',
              primary: true,
              icon: Icons.open_in_new,
              onPressed: url.isEmpty ? null : () => actions.openUrl(url),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'The agent continues on its own once the sign-in completes.',
            style: text.meta,
          ),
        ),
      ],
    );
  }
}

/// A message this device could not deliver.
class DeliveryForm extends StatelessWidget {
  const DeliveryForm({super.key, required this.item, required this.actions});
  final InboxItem item;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(item.title, style: text.body),
        if (item.detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              item.detail,
              style: text.meta.copyWith(color: t.failed),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            FlatButton(
              'Discard',
              danger: true,
              onPressed: () async {
                await actions.discardDelivery(item.id);
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
            const Spacer(),
            Text(
              'Retries on its own while the computer is reachable',
              style: text.meta,
            ),
          ],
        ),
      ],
    );
  }
}

/// A scheduled task finished and nobody has looked.
class AutomationForm extends StatelessWidget {
  const AutomationForm({super.key, required this.item, required this.actions});
  final InboxItem item;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final text = UiBText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(item.title, style: text.title),
        if (item.detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(item.detail, style: text.body),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            FlatButton(
              'Mark read',
              onPressed: () {
                if (item.serverId case final s?)
                  actions.markAutomationRead(s, item.id);
                Navigator.of(context).maybePop();
              },
            ),
            const Spacer(),
            if (item.sessionId case final sid?)
              FlatButton(
                'Open session',
                primary: true,
                onPressed: () {
                  actions.openSession(item.serverId ?? '', sid);
                  Navigator.of(context).maybePop();
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// Tool approvals are not exposed by the app's services, so this shows what
/// one will look like and does nothing.
class ToolApprovalForm extends StatelessWidget {
  const ToolApprovalForm({super.key, required this.item});
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(item.title, style: text.title),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: t.raised,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(item.detail, style: text.code),
        ),
        Row(
          children: [
            const FlatButton('Deny', danger: true),
            const SizedBox(width: 8),
            const FlatButton('Allow this time'),
            const SizedBox(width: 8),
            const FlatButton('Allow for session', primary: true),
            const Spacer(),
            const StubBadge(),
          ],
        ),
      ],
    );
  }
}

class StubForm extends StatelessWidget {
  const StubForm(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = UiBText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: style.body),
        const SizedBox(height: 10),
        const StubBadge(),
      ],
    );
  }
}
