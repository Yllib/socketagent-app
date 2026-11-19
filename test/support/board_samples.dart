import 'package:app/models/project_board.dart';

/// Example cards for the board screenshots in `boards_render_test.dart`.
/// [sessionId] links the asks to a chat, so their buttons render.
List<BoardCard> sampleBoardCards({String? sessionId, DateTime? now}) {
  final at = now ?? DateTime.now();
  var n = 0;
  BoardCard card(
    String title,
    String status, {
    required Duration age,
    String notes = '',
    String detail = '',
    WaitingOn? waitingOn,
    CardAsk? ask,
    List<CardLink> links = const [],
    List<(String, Duration, String)> path = const [],
  }) {
    final created = at.subtract(age);
    final history = [
      CardMove(at: created, by: 'Agent', to: path.isEmpty ? status : 'inbox'),
      for (final (i, (to, ago, why)) in path.indexed)
        CardMove(
          at: at.subtract(ago),
          by: i.isEven ? 'Agent' : 'You',
          from: i == 0 ? 'inbox' : path[i - 1].$1,
          to: to,
          why: why,
        ),
    ];
    n++;
    return BoardCard(
      id: 'c_sample$n',
      title: title,
      status: status,
      notes: notes,
      detail: detail,
      waitingOn: waitingOn,
      ask: ask,
      links: [
        ...links,
        if (sessionId != null) CardLink(LinkKind.session, sessionId),
      ],
      history: history,
      createdAt: created,
      updatedAt: history.last.at,
    );
  }

  return [
    card(
      'Approve the 2.4 release notes',
      'needs_you',
      age: const Duration(hours: 26),
      notes:
          'Drafted from the merged PRs. Two items moved under Fixes after '
          'review. Ready to publish once approved.',
      detail: _releaseNotes,
      ask: CardAsk(
        AskKind.approve,
        'Publish the 2.4 release notes as drafted?',
        sessionId: sessionId,
      ),
      path: [
        ('doing', const Duration(hours: 25), 'Started the draft'),
        ('needs_you', const Duration(hours: 3), 'Draft is ready'),
      ],
    ),
    card(
      'Reply to Dana about the rate limit',
      'needs_you',
      age: const Duration(days: 2),
      notes:
          'Dana asked whether the 60 per minute limit is per key or per '
          'account. It is per key. Reply drafted.',
      detail: _danaReply,
      ask: CardAsk(
        AskKind.send,
        'Send the drafted reply to Dana in the support thread?',
        sessionId: sessionId,
      ),
      links: const [
        CardLink(
          LinkKind.thread,
          'https://example.com/t/4821',
          label: 'Support thread',
        ),
      ],
      path: [('needs_you', const Duration(minutes: 40), 'Reply drafted')],
    ),
    card(
      'Pick a retry policy for webhooks',
      'needs_you',
      age: const Duration(days: 1),
      detail: _retryOptions,
      ask: CardAsk(
        AskKind.decide,
        'Retry failed webhooks 5 times over an hour, or 10 times over a day?',
        sessionId: sessionId,
      ),
      path: [
        ('needs_you', const Duration(hours: 20), 'Two options written up'),
      ],
    ),
    card(
      'Fix the login loop on Android 15',
      'doing',
      age: const Duration(hours: 5),
      notes:
          'Reproduced on a Pixel 9. The token refresh runs twice when the '
          'app resumes. Patch in progress.',
      waitingOn: const WaitingOn(WaitingKind.agent, 'Mobile agent'),
      links: const [CardLink(LinkKind.ticket, 'APP-1183')],
      path: [('doing', const Duration(hours: 4), 'Picked up')],
    ),
    card(
      'Migrate the reports page to the new API',
      'doing',
      age: const Duration(days: 3),
      notes: 'Four of six queries moved. Totals row still reads the old view.',
      path: [('doing', const Duration(days: 2), 'Started')],
    ),
    card(
      'Vendor quote for the new sensors',
      'waiting',
      age: const Duration(days: 4),
      notes: 'Asked for pricing on 200 units and lead time.',
      waitingOn: const WaitingOn(WaitingKind.person, 'Marco at Acme'),
      links: const [
        CardLink(
          LinkKind.thread,
          'https://example.com/mail/77',
          label: 'Email to Marco',
        ),
      ],
      path: [('waiting', const Duration(days: 4), 'Email sent')],
    ),
    card(
      'Confirm the staging database size',
      'waiting',
      age: const Duration(days: 6),
      waitingOn: const WaitingOn(WaitingKind.person, 'Ops'),
      path: [('waiting', const Duration(days: 6), 'Asked in #ops')],
    ),
    card(
      'Customer reports CSV export is empty',
      'inbox',
      age: const Duration(hours: 2),
      notes: 'From the feedback form. No account ID given.',
      detail: _csvReport,
    ),
    card(
      'Dark mode contrast on the invoice page',
      'inbox',
      age: const Duration(minutes: 25),
    ),
    card(
      'Update the onboarding screenshots',
      'done',
      age: const Duration(days: 5),
      notes: 'New screenshots in the store listing.',
      path: [
        ('doing', const Duration(days: 4), 'Started'),
        ('done', const Duration(days: 1), 'Uploaded'),
      ],
    ),
  ];
}

const _releaseNotes = """
## What's new in 2.4

**Faster sync.** Opening a project with a long history is about three
times faster, because the app now loads the newest messages first.

**Exports you can trust.** CSV exports include every column you see on
screen, in the same order, and dates use your own time zone.

### Fixes

- Signing in on Android 15 no longer loops back to the sign-in page.
- The invoice page is readable in dark mode.
- Search keeps your filter when you come back to it.

### For admins

Rate limits are now **60 requests a minute per API key**, up from 30. The
limit is per key, not per account, so a second key gets its own 60.
""";

const _danaReply = """
> **Dana, in the support thread:** Is the 60 per minute limit per key or
> per account? We run three services and I need to know if they share it.

**Drafted reply:**

Hi Dana,

It's per key, so each of your three services gets its own 60 requests a
minute as long as each uses its own key. You can make more keys under
**Settings > API keys**; there's no charge for them.

If one service needs more than 60, tell me which one and roughly what
peak you expect and I'll look at raising it for that key.
""";

const _csvReport = """
**From the feedback form, 2 hours ago:**

> When I export the Orders report to CSV the file only has the header row.
> The page shows 340 orders for last month. I tried Chrome and Safari.
> This worked last week.

No account ID or email was given, so there's no way to reply yet.
""";

const _retryOptions = """
**Option A: 5 tries over an hour.** 1, 5, 10, 15 and 29 minutes after the
first failure. Receivers that are down for a deploy recover in time. Total
work per failed event stays small.

**Option B: 10 tries over a day.** Doubling from 1 minute up to 8 hours.
Catches longer outages, but a receiver that's gone for good costs ten
attempts per event, and events can arrive up to a day late.

Most failures in the last month (92%) recovered within 20 minutes.
""";
