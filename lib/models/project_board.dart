import 'dart:math';

/// What a status means to the app and to agents. The user names statuses;
/// the kind decides colour, the Needs you count and which moves make sense.
enum StatusKind {
  incoming('new'),
  active('active'),
  user('user'),
  other('other'),
  done('done');

  const StatusKind(this.wire);
  final String wire;

  static StatusKind parse(Object? raw) =>
      values.where((k) => k.wire == raw).firstOrNull ?? StatusKind.incoming;
}

/// One column of a board.
class BoardStatus {
  const BoardStatus({
    required this.key,
    required this.name,
    required this.kind,
    this.meaning = '',
  });

  final String key;
  final String name;
  final StatusKind kind;

  /// One line telling agents and people when a card belongs here.
  final String meaning;

  BoardStatus copyWith({String? name, StatusKind? kind, String? meaning}) =>
      BoardStatus(
        key: key,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        meaning: meaning ?? this.meaning,
      );

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'kind': kind.wire,
    'meaning': meaning,
  };

  static BoardStatus? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final name = raw['name'];
    if (key is! String || name is! String) return null;
    return BoardStatus(
      key: key,
      name: name,
      kind: StatusKind.parse(raw['kind']),
      meaning: _string(raw['meaning']),
    );
  }

  /// The five statuses a new board starts with, one of each kind.
  static const defaults = [
    BoardStatus(
      key: 'inbox',
      name: 'Inbox',
      kind: StatusKind.incoming,
      meaning: 'Came in from a ticket or message. Nobody has looked yet.',
    ),
    BoardStatus(
      key: 'doing',
      name: 'Doing',
      kind: StatusKind.active,
      meaning: 'An agent is working on it now.',
    ),
    BoardStatus(
      key: 'needs_you',
      name: 'Needs you',
      kind: StatusKind.user,
      meaning: 'Waiting on a decision, an approval or an answer from you.',
    ),
    BoardStatus(
      key: 'waiting',
      name: 'Waiting',
      kind: StatusKind.other,
      meaning: 'Asked someone else and waiting for their answer.',
    ),
    BoardStatus(
      key: 'done',
      name: 'Done',
      kind: StatusKind.done,
      meaning: 'Finished or dropped.',
    ),
  ];
}

enum WaitingKind { user, person, agent }

/// Who a card is waiting on.
class WaitingOn {
  const WaitingOn(this.kind, this.name);
  final WaitingKind kind;
  final String name;

  Map<String, Object?> toJson() => {'kind': kind.name, 'name': name};

  static WaitingOn? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final kind = WaitingKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (name is! String || name.isEmpty || kind == null) return null;
    return WaitingOn(kind, name);
  }
}

enum AskKind {
  approve('Approve'),
  send('Send'),
  decide('Decide'),
  answer('Answer');

  const AskKind(this.label);
  final String label;
}

/// The exact thing a card asks of the user, and the chat that asked.
class CardAsk {
  const CardAsk(this.kind, this.text, {this.sessionId});
  final AskKind kind;
  final String text;
  final String? sessionId;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'text': text,
    if (sessionId != null) 'sessionId': sessionId,
  };

  static CardAsk? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final kind = AskKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    if (text is! String || text.isEmpty || kind == null) return null;
    final session = raw['sessionId'];
    return CardAsk(kind, text, sessionId: session is String ? session : null);
  }
}

/// The user's answer to a card's ask, saved on the card. It reaches the
/// agent only when the user sends it; until then [sentAt] is null.
class CardReply {
  const CardReply({
    required this.text,
    required this.at,
    this.approved,
    this.sentAt,
  });

  /// Approve or decline for asks of kind approve and send; null for decide
  /// and answer, where [text] is the answer.
  final bool? approved;

  /// The answer, or an optional note with an approval.
  final String text;
  final DateTime at;
  final DateTime? sentAt;

  bool get sent => sentAt != null;

  /// How the answer reads on the card and in the message to the agent.
  String verdict(AskKind kind) => switch ((kind, approved)) {
    (AskKind.send, true) => 'Send it',
    (AskKind.send, false) => "Don't send",
    (_, true) => 'Approved',
    (_, false) => 'Declined',
    (_, null) => 'Answered',
  };

  CardReply markSent(DateTime at) =>
      CardReply(text: text, at: this.at, approved: approved, sentAt: at);

  Map<String, Object?> toJson() => {
    'approved': ?approved,
    'text': text,
    'at': at.millisecondsSinceEpoch,
    if (sentAt != null) 'sentAt': sentAt!.millisecondsSinceEpoch,
  };

  static CardReply? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final at = raw['at'];
    final approved = raw['approved'];
    final sentAt = raw['sentAt'];
    if (text is! String || at is! int) return null;
    if (approved is! bool? || sentAt is! int?) return null;
    if (approved == null && text.trim().isEmpty) return null;
    return CardReply(
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      approved: approved,
      sentAt: sentAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(sentAt),
    );
  }
}

/// The one message a chat gets for the answers it is sent from a board:
/// every card with its ID, the question and the user's answer.
String boardAnswersMessage(String boardName, List<BoardCard> cards) {
  String indent(String text) => text.trim().replaceAll('\n', '\n   ');
  final lines = ['Answers from the $boardName board:'];
  for (final (i, card) in cards.indexed) {
    final ask = card.ask;
    final reply = card.reply;
    if (ask == null || reply == null) continue;
    lines
      ..add('')
      ..add(
        '${i + 1}. ${reply.verdict(ask.kind)}: ${card.title} (card ${card.id})',
      )
      ..add('   Question: ${indent(ask.text)}');
    if (reply.text.trim().isNotEmpty) {
      final label = reply.approved == null ? 'Answer' : 'Note';
      lines.add('   $label: ${indent(reply.text)}');
    }
  }
  return lines.join('\n');
}

enum LinkKind { session, ticket, thread, url }

class CardLink {
  const CardLink(this.kind, this.ref, {this.label = ''});
  final LinkKind kind;

  /// A session ID for [LinkKind.session], a URL or ticket key otherwise.
  final String ref;
  final String label;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'ref': ref,
    'label': label,
  };

  static CardLink? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ref = raw['ref'];
    final kind = LinkKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (ref is! String || ref.isEmpty || kind == null) return null;
    return CardLink(kind, ref, label: _string(raw['label']));
  }
}

/// One status change. [from] is null when the card was created.
class CardMove {
  const CardMove({
    required this.at,
    required this.by,
    required this.to,
    this.from,
    this.why = '',
  });
  final DateTime at;
  final String by;
  final String? from;
  final String to;
  final String why;

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'by': by,
    if (from != null) 'from': from,
    'to': to,
    'why': why,
  };

  static CardMove? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    final to = raw['to'];
    if (at is! int || to is! String) return null;
    final from = raw['from'];
    return CardMove(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      by: _string(raw['by']),
      from: from is String ? from : null,
      to: to,
      why: _string(raw['why']),
    );
  }
}

/// One piece of work that outlives a single turn.
class BoardCard {
  const BoardCard({
    required this.id,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.notes = '',
    this.detail = '',
    this.waitingOn,
    this.ask,
    this.reply,
    this.links = const [],
    this.history = const [],
    this.extra = const {},
  });

  final String id;
  final String title;
  final String status;

  /// Short: where this stands now.
  final String notes;

  /// Markdown. Everything needed to decide without leaving the card: the
  /// ticket's full request, the drafted reply, the proposed text.
  final String detail;
  final WaitingOn? waitingOn;
  final CardAsk? ask;

  /// The user's answer to [ask]. Belongs to that ask: a card without one
  /// has no reply, and a new ask clears it.
  final CardReply? reply;
  final List<CardLink> links;
  final List<CardMove> history;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Fields this app doesn't know, kept so a rewrite doesn't drop what a
  /// newer app or server wrote.
  final Map<String, Object?> extra;

  /// An answer saved in the app that hasn't gone to the chat that asked.
  bool get replyUnsent =>
      ask?.sessionId != null && reply != null && !reply!.sent;

  /// When the card reached its current status.
  DateTime get statusSince =>
      history.where((m) => m.to == status).lastOrNull?.at ?? createdAt;

  /// Copies with changes. Nullable fields take a function so they can be
  /// cleared: `ask: () => null`.
  BoardCard copyWith({
    String? title,
    String? status,
    String? notes,
    String? detail,
    WaitingOn? Function()? waitingOn,
    CardAsk? Function()? ask,
    CardReply? Function()? reply,
    List<CardLink>? links,
    List<CardMove>? history,
    DateTime? updatedAt,
  }) => BoardCard(
    id: id,
    title: title ?? this.title,
    status: status ?? this.status,
    notes: notes ?? this.notes,
    detail: detail ?? this.detail,
    waitingOn: waitingOn == null ? this.waitingOn : waitingOn(),
    ask: ask == null ? this.ask : ask(),
    reply: reply == null ? this.reply : reply(),
    links: links ?? this.links,
    history: history ?? this.history,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );

  static const _known = {
    'v',
    'id',
    'title',
    'status',
    'notes',
    'detail',
    'waitingOn',
    'ask',
    'reply',
    'links',
    'history',
    'createdAt',
    'updatedAt',
  };

  Map<String, Object?> toJson() => {
    ...extra,
    'v': 1,
    'id': id,
    'title': title,
    'status': status,
    'notes': notes,
    if (detail.isNotEmpty) 'detail': detail,
    if (waitingOn != null) 'waitingOn': waitingOn!.toJson(),
    if (ask != null) 'ask': ask!.toJson(),
    if (ask != null && reply != null) 'reply': reply!.toJson(),
    'links': [for (final l in links) l.toJson()],
    'history': [for (final m in history) m.toJson()],
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static BoardCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    final status = raw['status'];
    final created = raw['createdAt'];
    if (id is! String ||
        title is! String ||
        status is! String ||
        created is! int) {
      return null;
    }
    final updated = raw['updatedAt'];
    return BoardCard(
      id: id,
      title: title,
      status: status,
      notes: _string(raw['notes']),
      detail: _string(raw['detail']),
      waitingOn: WaitingOn.fromJson(raw['waitingOn']),
      ask: CardAsk.fromJson(raw['ask']),
      reply: CardReply.fromJson(raw['reply']),
      links: _list(raw['links'], CardLink.fromJson),
      history: _list(raw['history'], CardMove.fromJson),
      createdAt: DateTime.fromMillisecondsSinceEpoch(created),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        updated is int ? updated : created,
      ),
      extra: {
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && !_known.contains(key)) key: value,
      },
    );
  }

  static String newId() {
    final random = Random.secure();
    return 'c_${List.generate(6, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }
}

/// The statuses, rules and cards of one project.
class ProjectBoard {
  const ProjectBoard({
    required this.projectId,
    this.statuses = BoardStatus.defaults,
    this.rules = '',
    this.cards = const [],
    this.proposals = const [],
    this.intakes = const [],
  });

  final String projectId;
  final List<BoardStatus> statuses;

  /// Plain text the user writes: when to make a card, when to move it.
  final String rules;
  final List<BoardCard> cards;

  /// Agents' suggested changes to statuses and rules, newest first.
  final List<BoardProposal> proposals;

  /// Keys outside services use to add items, oldest first.
  final List<BoardIntake> intakes;

  List<BoardProposal> get openProposals =>
      proposals.where((p) => p.state == ProposalState.open).toList();

  /// Cards dropped from lists after this long in a done status.
  static const doneHiddenAfter = Duration(days: 30);

  BoardStatus? status(String key) =>
      statuses.where((s) => s.key == key).firstOrNull;

  /// The status a card shows under. A card whose status was deleted lands
  /// in the first status so it never disappears.
  BoardStatus statusOf(BoardCard card) => status(card.status) ?? statuses.first;

  /// Cards in [statusKey], newest change first, without done cards past
  /// [doneHiddenAfter].
  List<BoardCard> cardsIn(String statusKey, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final list = cards.where((c) {
      if (statusOf(c).key != statusKey) return false;
      return statusOf(c).kind != StatusKind.done ||
          at.difference(c.statusSince) < doneHiddenAfter;
    }).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// Cards with an answer saved here that hasn't gone to its chat.
  List<BoardCard> get unsentReplies =>
      cards.where((c) => c.replyUnsent).toList();

  /// Cards waiting on the user. A card whose answer was sent waits on the
  /// agent now, so it isn't counted.
  List<BoardCard> get needsYou =>
      cards
          .where(
            (c) =>
                statusOf(c).kind == StatusKind.user &&
                !(c.reply?.sent ?? false),
          )
          .toList()
        ..sort((a, b) => a.statusSince.compareTo(b.statusSince));

  ProjectBoard copyWith({
    List<BoardStatus>? statuses,
    String? rules,
    List<BoardCard>? cards,
  }) => ProjectBoard(
    projectId: projectId,
    statuses: statuses ?? this.statuses,
    rules: rules ?? this.rules,
    cards: cards ?? this.cards,
    proposals: proposals,
    intakes: intakes,
  );

  /// The board that the relay's records add up to: `config`, `card.<id>`
  /// (skipping deleted ones) and `proposal.<id>`. A board with no config
  /// has the default statuses.
  static ProjectBoard fromRecords(
    String projectId,
    Map<String, Map<String, Object?>> records,
  ) {
    final config = records['config'];
    final statuses = _list(config?['statuses'], BoardStatus.fromJson);
    return ProjectBoard(
      projectId: projectId,
      statuses: statuses.isEmpty ? BoardStatus.defaults : statuses,
      rules: _string(config?['rules']),
      cards: [
        for (final MapEntry(:key, :value) in records.entries)
          if (key.startsWith('card.') && value['deleted'] != true)
            ?BoardCard.fromJson(value),
      ],
      proposals: [
        for (final MapEntry(:key, :value) in records.entries)
          if (key.startsWith('proposal.'))
            ?BoardProposal.fromJson(key.substring(9), value),
      ]..sort((a, b) => b.at.compareTo(a.at)),
      intakes: _list(config?['intakes'], BoardIntake.fromJson),
    );
  }
}

/// An intake key: a write-only key an outside service, such as the
/// Feedback Hub, uses to add items that agents turn into cards. The relay
/// knows the key by [id]; the app shows the token holding it only once.
class BoardIntake {
  const BoardIntake({
    required this.id,
    required this.label,
    required this.createdAt,
  });

  final String id;
  final String label;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static BoardIntake? fromJson(Object? raw) {
    if (raw case {'id': final String id, 'createdAt': final int at}) {
      return BoardIntake(
        id: id,
        label: _string(raw['label']),
        createdAt: DateTime.fromMillisecondsSinceEpoch(at),
      );
    }
    return null;
  }
}

enum ProposalState { open, approved, declined }

/// An agent's suggested statuses and rules. The board changes only when
/// the user approves it.
class BoardProposal {
  const BoardProposal({
    required this.id,
    required this.by,
    required this.why,
    required this.state,
    required this.at,
    this.statuses,
    this.rules,
  });

  final String id;

  /// Who proposed it, as the agent named itself.
  final String by;
  final String why;
  final ProposalState state;
  final DateTime at;

  /// Null when the proposal leaves that part as it is.
  final List<BoardStatus>? statuses;
  final String? rules;

  static BoardProposal? fromJson(String id, Map<String, Object?> raw) {
    final config = raw['config'];
    if (config is! Map) return null;
    final statuses = _list(config['statuses'], BoardStatus.fromJson);
    final rules = config['rules'];
    final at = raw['at'];
    final byName = _string(raw['byName']);
    return BoardProposal(
      id: id,
      by: byName.isNotEmpty ? byName : _string(raw['by']),
      why: _string(raw['why']),
      state:
          ProposalState.values
              .where((s) => s.name == raw['state'])
              .firstOrNull ??
          ProposalState.open,
      at: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
      statuses: statuses.isEmpty ? null : statuses,
      rules: rules is String ? rules : null,
    );
  }
}

String _string(Object? value) => value is String ? value : '';

List<T> _list<T>(Object? raw, T? Function(Object?) parse) => [
  if (raw is List)
    for (final item in raw)
      if (parse(item) case final T value) value,
];
