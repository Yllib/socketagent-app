import 'package:flutter/material.dart';

import '../../models/device_registry.dart';
import '../../models/message.dart';
import '../../util/format.dart';
import '../model/actions.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import 'clock.dart';
import 'primitives.dart';

IconData inboxIcon(InboxKind kind) => switch (kind) {
  InboxKind.question => Icons.help_outline,
  InboxKind.toolApproval => Icons.gpp_maybe_outlined,
  InboxKind.secret => Icons.key_outlined,
  InboxKind.access => Icons.lan_outlined,
  InboxKind.device => Icons.phonelink_lock_outlined,
  InboxKind.signIn => Icons.login,
  InboxKind.delivery => Icons.sms_failed_outlined,
  InboxKind.automation => Icons.schedule_outlined,
  InboxKind.review => Icons.rate_review_outlined,
};

String inboxKindLabel(InboxKind kind) => switch (kind) {
  InboxKind.question => 'question',
  InboxKind.toolApproval => 'approval',
  InboxKind.secret => 'secret',
  InboxKind.access => 'access',
  InboxKind.device => 'new device',
  InboxKind.signIn => 'sign in',
  InboxKind.delivery => 'not delivered',
  InboxKind.automation => 'automation result',
  InboxKind.review => 'review',
};

/// One thing waiting on the user. Simple cases answer right here; the rest
/// open the answer sheet through [onOpen].
class InboxCard extends StatelessWidget {
  const InboxCard(
    this.item, {
    super.key,
    required this.actions,
    required this.onOpen,
  });

  final InboxItem item;
  final UiBActions actions;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final now = UiBClockScope.read(context);
    final expired = item.expiresAt != null && !item.expiresAt!.isAfter(now);
    final color = expired
        ? t.text3
        : item.kind == InboxKind.delivery
        ? t.failed
        : item.kind == InboxKind.automation || item.kind == InboxKind.review
        ? t.info
        : t.waiting;
    final where = <String>[
      if (item.sessionTitle.isNotEmpty) item.sessionTitle,
      if (item.computerName.isNotEmpty) item.computerName,
      formatTimeAgo(item.since, now: now),
      if (item.expiresAt != null)
        expired
            ? 'expired'
            : 'expires in ${formatTimeLeft(item.expiresAt!.difference(now))}',
      if (!item.deliverable) 'computer offline',
    ];
    return Material(
      color: t.surface,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(9, 7, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(inboxIcon(item.kind), size: 13, color: color),
                  const SizedBox(width: 5),
                  Text(
                    inboxKindLabel(item.kind).toUpperCase(),
                    style: text.micro.copyWith(color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      where.join(' · '),
                      style: text.meta,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                item.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: text.body.copyWith(fontWeight: FontWeight.w500),
              ),
              if (item.detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  item.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.body2.copyWith(fontSize: 12 * text.scale),
                ),
              ],
              const SizedBox(height: 6),
              _quickActions(context, expired),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickActions(BuildContext context, bool expired) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final enabled = item.deliverable && !expired;
    final buttons = <Widget>[];
    switch (item.kind) {
      case InboxKind.question:
        final q = item.message?.questions;
        if (q != null &&
            q.length == 1 &&
            q.single.options.length <= 3 &&
            !q.single.multiSelect) {
          for (final option in q.single.options) {
            buttons.add(
              FlatButton(
                option.label,
                compact: true,
                onPressed: enabled
                    ? () => actions.answerQuestion(item.message!.questionId!, {
                        q.single.question: option.label,
                      })
                    : null,
              ),
            );
          }
          buttons.add(FlatButton('Other', compact: true, onPressed: onOpen));
        } else {
          buttons.add(
            FlatButton(
              'Answer',
              compact: true,
              primary: true,
              onPressed: onOpen,
            ),
          );
        }
      case InboxKind.toolApproval:
        buttons.add(
          FlatButton('Review', compact: true, primary: true, onPressed: onOpen),
        );
      case InboxKind.secret:
        buttons.add(
          FlatButton(
            'Enter secret',
            compact: true,
            primary: true,
            icon: Icons.lock_outline,
            onPressed: enabled ? onOpen : null,
          ),
        );
        buttons.add(
          FlatButton(
            'Cancel',
            compact: true,
            onPressed: enabled
                ? () => actions.cancelSecret(item.message!.questionId!)
                : null,
          ),
        );
      case InboxKind.access:
        final id = item.message?.questionId ?? '';
        buttons.add(
          FlatButton(
            'Allow once',
            compact: true,
            primary: true,
            onPressed: enabled ? () => actions.answerAccess(id, 'once') : null,
          ),
        );
        buttons.add(FlatButton('More', compact: true, onPressed: onOpen));
        buttons.add(
          FlatButton(
            'Deny',
            compact: true,
            danger: true,
            onPressed: enabled ? () => actions.answerAccess(id, 'deny') : null,
          ),
        );
      case InboxKind.device:
        final device = item.payload;
        if (device is PendingDevice) {
          buttons.add(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: t.raised,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                device.code,
                style: text.code.copyWith(
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
          buttons.add(
            FlatButton(
              'Code matches',
              compact: true,
              primary: true,
              onPressed: enabled ? () => actions.approveDevice(device) : null,
            ),
          );
          buttons.add(
            FlatButton(
              'Deny',
              compact: true,
              danger: true,
              onPressed: enabled ? () => actions.denyDevice(device) : null,
            ),
          );
        }
      case InboxKind.signIn:
        final url = item.message?.toolOutput ?? '';
        buttons.add(
          FlatButton(
            'Open sign-in',
            compact: true,
            primary: true,
            icon: Icons.open_in_new,
            onPressed: url.isEmpty ? null : () => actions.openUrl(url),
          ),
        );
        buttons.add(FlatButton('Done', compact: true, onPressed: onOpen));
      case InboxKind.delivery:
        buttons.add(FlatButton('Show', compact: true, onPressed: onOpen));
        buttons.add(
          FlatButton(
            'Discard',
            compact: true,
            danger: true,
            onPressed: () => actions.discardDelivery(item.id),
          ),
        );
      case InboxKind.automation:
        buttons.add(
          FlatButton(
            'Open result',
            compact: true,
            primary: true,
            onPressed: onOpen,
          ),
        );
        if (item.serverId != null) {
          buttons.add(
            FlatButton(
              'Mark read',
              compact: true,
              onPressed: () =>
                  actions.markAutomationRead(item.serverId!, item.id),
            ),
          );
        }
      case InboxKind.review:
        buttons.add(
          FlatButton('Review', compact: true, primary: true, onPressed: onOpen),
        );
    }
    return Wrap(spacing: 6, runSpacing: 6, children: buttons);
  }
}

/// Builds the inbox title for a transcript card.
String inboxTitleFor(ChatMessage m) => switch (m.type) {
  MessageType.question =>
    m.questions?.map((q) => q.question).join('  ') ?? 'Question',
  MessageType.secureInput => m.toolInput?['label']?.toString() ?? 'Secret',
  MessageType.computerAccess =>
    m.textContent.isNotEmpty
        ? m.textContent
        : 'Access to ${m.toolInput?['target']?['name'] ?? 'a computer'}',
  MessageType.elicitationUrl =>
    m.textContent.isNotEmpty
        ? m.textContent
        : 'Sign in to ${m.toolName ?? 'a connected app'}',
  _ => m.textContent,
};
