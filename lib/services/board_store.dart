import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../models/project_board.dart';
import 'background_json_store.dart';
import 'board_relay.dart';
import 'secure_storage_service.dart';

/// Project boards, synced through the relay. Each board is a set of sealed
/// records (`config`, `card.<id>`, `proposal.<id>`) that this device, the
/// user's other devices and agents on the user's computers all read and
/// write. A board exists for a project once someone turns it on; its
/// secret travels in the account vault.
///
/// Local edits apply at once and wait in an outbox until the relay takes
/// them. When the relay already holds a newer version, the edit with the
/// later `updatedAt` wins, and a deletion always wins.
class BoardStore extends ChangeNotifier {
  /// A store with neither [cache] nor [relay] keeps boards in memory and
  /// never syncs, for widget tests. Sync tests pass a fake [relay].
  BoardStore({
    BackgroundJsonStore? cache,
    SecureStorageService? secrets,
    String Function()? relayUrl,
    BoardRelay Function(String url, BoardKeys keys)? relay,
  }) : _cache = cache,
       _secrets = secrets,
       _relayUrl = relayUrl,
       _syncs = cache != null || relay != null,
       _makeRelay = relay ?? BoardRelay.new;

  /// The app's store. Tests swap it for an in-memory one.
  static BoardStore shared = BoardStore(
    cache: BackgroundJsonStore('project-boards-v2'),
    secrets: SecureStorageService(),
  );

  final BackgroundJsonStore? _cache;
  final SecureStorageService? _secrets;
  String Function()? _relayUrl;
  final bool _syncs;
  final BoardRelay Function(String url, BoardKeys keys) _makeRelay;
  final Map<String, _Board> _boards = {};
  Future<void>? _loading;
  Timer? _poll;
  Timer? _flushSoon;

  /// Called after a board is turned on or off here or by another device,
  /// so the vault and the computers' grants follow.
  VoidCallback? onSecretsChanged;

  /// Called when a board is turned off here, or found deleted on the relay,
  /// so the vault records the removal. A board that only goes missing
  /// locally is never removed from the vault.
  void Function(String projectId)? onTurnedOff;

  /// The relay allows 300 board requests an hour per board from one address.
  /// A phone, a desktop and a computer behind one router share that, so
  /// each device polls at most 60 times an hour.
  static const pollEvery = Duration(minutes: 1);

  /// Points the store at the relay and starts syncing. Call once at
  /// startup, after [ensureLoaded].
  void connect(String Function() relayUrl) {
    if (!_syncs) return;
    _relayUrl = relayUrl;
    _pollWhileBoards();
    unawaited(syncAll());
  }

  /// Polls every [pollEvery] while the app is in front and has a board.
  void _pollWhileBoards() {
    if (_boards.isEmpty || _relayUrl == null || !_syncs) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(pollEvery, (_) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        unawaited(syncAll());
      }
    });
  }

  /// Reads the secrets once, then the cached boards in the background.
  /// The future completes once the secrets are in, which is all the
  /// account sync needs. Safe to call often.
  Future<void> ensureLoaded() => _loading ??= _loadSecrets();

  /// Completes when the cached records are restored. Syncs wait for it.
  Future<void>? _cacheLoaded;

  Future<void> _loadSecrets() async {
    try {
      final raw = await _secrets?.getBoardSecrets();
      final secrets = raw == null ? null : jsonDecode(raw);
      if (secrets is Map) {
        for (final MapEntry(:key, :value) in secrets.entries) {
          if (key is! String || value is! String) continue;
          final board = _Board.tryCreate(key, value);
          if (board != null) _boards[key] = board;
        }
      }
    } catch (error) {
      debugPrint('[Boards] Could not read board secrets: $error');
    } finally {
      _cacheLoaded = _loadCache();
      notifyListeners();
    }
  }

  Future<void> _loadCache() async {
    try {
      final cached = await _cache?.load();
      if (cached?['boards'] case final List list) {
        for (final item in list) {
          if (item case {'projectId': final String id}) {
            _boards[id]?.restore(item);
          }
        }
      }
    } catch (error) {
      debugPrint('[Boards] Could not read cached boards: $error');
    } finally {
      notifyListeners();
    }
  }

  /// Project ID to secret, for the account vault.
  Map<String, String> get secrets => {
    for (final b in _boards.values) b.projectId: b.secret,
  };

  ProjectBoard? board(String projectId) => _boards[projectId]?.view;

  /// Local edits the relay hasn't taken yet.
  int unsynced(String projectId) => _boards[projectId]?.pending.length ?? 0;

  /// Cards waiting on the user in [projectId], 0 when it has no board.
  int needsYouCount(String? projectId) =>
      projectId == null ? 0 : board(projectId)?.needsYou.length ?? 0;

  /// Turns on the board for [projectId] with a new secret and the default
  /// statuses.
  void enable(String projectId) {
    if (_boards.containsKey(projectId)) return;
    final board = _Board.tryCreate(projectId, BoardKeys.newSecret())!;
    board.write('config', _configRecord(board, BoardStatus.defaults, ''));
    _boards[projectId] = board;
    _secretsChanged();
    _changed(board);
  }

  /// Turns on [projectId]'s existing board from a [secret] a computer still
  /// held, pulling its cards from the relay. False when the secret is not a
  /// board secret.
  bool adopt(String projectId, String secret) {
    if (_boards.containsKey(projectId)) return true;
    final board = _Board.tryCreate(projectId, secret);
    if (board == null) return false;
    _boards[projectId] = board;
    _secretsChanged();
    _save();
    notifyListeners();
    unawaited(_sync(board));
    return true;
  }

  /// Turns the board off everywhere and deletes it from the relay.
  void disable(String projectId) {
    final board = _boards.remove(projectId);
    if (board == null) return;
    onTurnedOff?.call(projectId);
    _secretsChanged();
    _save();
    notifyListeners();
    final url = _relayUrl?.call();
    if (url == null) return;
    unawaited(
      _makeRelay(url, board.keys).delete().catchError((Object error) {
        debugPrint('[Boards] Delete failed: $error');
      }),
    );
  }

  /// Brings the boards in line with the account vault: boards turned on
  /// elsewhere appear, boards turned off elsewhere go, a new secret starts
  /// the board over from the relay.
  void applySecrets(Map<String, String> secrets) {
    var changed = false;
    for (final id in _boards.keys.toList()) {
      if (!secrets.containsKey(id)) {
        _boards.remove(id);
        changed = true;
      }
    }
    for (final MapEntry(key: id, value: secret) in secrets.entries) {
      if (_boards[id]?.secret == secret) continue;
      final board = _Board.tryCreate(id, secret);
      if (board == null) continue;
      _boards[id] = board;
      changed = true;
      unawaited(_sync(board));
    }
    if (!changed) return;
    _pollWhileBoards();
    _persistSecrets();
    _save();
    notifyListeners();
  }

  /// Adds [card] or replaces the card with its ID.
  void putCard(String projectId, BoardCard card) {
    final board = _boards[projectId];
    if (board == null) return;
    board.write('card.${card.id}', card.toJson());
    _changed(board);
  }

  /// Saves the user's answer to [cardId]'s ask on the card, unsent. Null
  /// clears it.
  void saveReply(String projectId, String cardId, CardReply? reply) {
    final card = board(
      projectId,
    )?.cards.where((c) => c.id == cardId).firstOrNull;
    if (card == null || card.ask == null) return;
    putCard(
      projectId,
      card.copyWith(reply: () => reply, updatedAt: DateTime.now()),
    );
  }

  /// Records that the answers on [cardIds] reached their chats.
  void markRepliesSent(String projectId, Iterable<String> cardIds) {
    final now = DateTime.now();
    final ids = cardIds.toSet();
    for (final card in [...?board(projectId)?.cards]) {
      final reply = card.reply;
      if (!ids.contains(card.id) || reply == null) continue;
      putCard(
        projectId,
        card.copyWith(reply: () => reply.markSent(now), updatedAt: now),
      );
    }
  }

  /// Moves a card and records the move in its history (last 50 kept).
  void moveCard(String projectId, String cardId, String to, {String why = ''}) {
    final card = board(
      projectId,
    )?.cards.where((c) => c.id == cardId).firstOrNull;
    if (card == null || card.status == to) return;
    final now = DateTime.now();
    final history = [
      ...card.history,
      CardMove(at: now, by: 'You', from: card.status, to: to, why: why),
    ];
    putCard(
      projectId,
      card.copyWith(
        status: to,
        updatedAt: now,
        history: history.length > 50
            ? history.sublist(history.length - 50)
            : history,
      ),
    );
  }

  void deleteCard(String projectId, String cardId) {
    final board = _boards[projectId];
    if (board == null) return;
    board.write('card.$cardId', {
      'v': 1,
      'id': cardId,
      'deleted': true,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    _changed(board);
  }

  void setConfig(
    String projectId, {
    List<BoardStatus>? statuses,
    String? rules,
  }) {
    final board = _boards[projectId];
    if (board == null) return;
    final view = board.view;
    board.write(
      'config',
      _configRecord(board, statuses ?? view.statuses, rules ?? view.rules),
    );
    _changed(board);
  }

  /// Applies an agent's proposed statuses and rules, or turns them down.
  void decideProposal(String projectId, String proposalId, bool approve) {
    final board = _boards[projectId];
    final proposal = board?.view.proposals
        .where((p) => p.id == proposalId)
        .firstOrNull;
    if (board == null || proposal == null) return;
    if (approve) {
      board.write(
        'config',
        _configRecord(
          board,
          proposal.statuses ?? board.view.statuses,
          proposal.rules ?? board.view.rules,
        ),
      );
    }
    board.write('proposal.$proposalId', {
      ...?board.record('proposal.$proposalId'),
      'state': approve ? 'approved' : 'declined',
    });
    _changed(board);
  }

  /// Makes an intake key for [projectId], registers it on the relay and
  /// lists it in the board's config. Returns the token to show the user
  /// once. Throws [BoardRelayDown] when the relay can't take it.
  Future<String> addIntake(String projectId, String label) async {
    final board = _boards[projectId];
    final url = _relayUrl?.call();
    if (board == null || url == null) {
      throw BoardRelayDown('Not connected to the relay');
    }
    final intake = board.keys.newIntake(url);
    await _makeRelay(url, board.keys).addIntake(intake.id);
    _writeIntakes(board, [
      ...board.view.intakes,
      BoardIntake(id: intake.id, label: label, createdAt: DateTime.now()),
    ]);
    return intake.token;
  }

  /// Revokes an intake key on the relay, then drops it from the config.
  Future<void> removeIntake(String projectId, String intakeId) async {
    final board = _boards[projectId];
    final url = _relayUrl?.call();
    if (board == null || url == null) {
      throw BoardRelayDown('Not connected to the relay');
    }
    await _makeRelay(url, board.keys).removeIntake(intakeId);
    _writeIntakes(board, [
      for (final i in board.view.intakes)
        if (i.id != intakeId) i,
    ]);
  }

  void _writeIntakes(_Board board, List<BoardIntake> intakes) {
    if (_boards[board.projectId] != board) return;
    board.write('config', {
      ..._configRecord(board, board.view.statuses, board.view.rules),
      'intakes': [for (final i in intakes) i.toJson()],
    });
    _changed(board);
  }

  /// Fetches what changed on every board and sends waiting edits.
  Future<void> syncAll() =>
      Future.wait([for (final b in _boards.values.toList()) _sync(b)]);

  /// Syncs one board now, for example when its screen opens.
  Future<void> refresh(String projectId) async {
    final board = _boards[projectId];
    if (board != null) await _sync(board);
  }

  Map<String, Object?> _configRecord(
    _Board board,
    List<BoardStatus> statuses,
    String rules,
  ) => {
    ...?board.record('config'),
    'v': 1,
    'statuses': [for (final s in statuses) s.toJson()],
    'rules': rules,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
    'updatedBy': 'You',
  };

  void _changed(_Board board) {
    board.rebuild();
    _save();
    notifyListeners();
    if (_relayUrl == null) return;
    _flushSoon?.cancel();
    _flushSoon = Timer(const Duration(milliseconds: 400), () {
      for (final b in _boards.values) {
        if (b.pending.isNotEmpty) unawaited(_sync(b));
      }
    });
  }

  /// Pulls, then pushes the outbox. One run per board at a time; a call
  /// during a run asks for one more pass.
  Future<void> _sync(_Board board) async {
    final cache = _cacheLoaded;
    if (cache != null) await cache;
    final url = _relayUrl?.call();
    if (url == null) return;
    if (board.syncing != null) {
      board.again = true;
      return board.syncing;
    }
    final relay = _makeRelay(url, board.keys);
    final run = () async {
      do {
        board.again = false;
        try {
          await _pull(board, relay);
          await _push(board, relay);
        } on BoardDeleted {
          _gone(board);
          return;
        } on BoardRelayDown catch (error) {
          debugPrint('[Boards] ${board.projectId}: $error');
          return;
        }
      } while (board.again && _boards[board.projectId] == board);
    }();
    board.syncing = run;
    try {
      await run;
    } finally {
      board.syncing = null;
    }
  }

  Future<void> _pull(_Board board, BoardRelay relay) async {
    final result = await relay.pull(board.seq);
    var changed = false;
    for (final record in result.records) {
      if ((board.remote[record.id]?.version ?? 0) >= record.version) continue;
      final data = board.keys.open(record.ciphertext);
      if (data == null) continue;
      board.remote[record.id] = (version: record.version, data: data);
      // Someone else wrote this record since the local edit was made.
      if (!board.keepsAfterConflict(record.id)) {
        board.pending.remove(record.id);
      }
      changed = true;
    }
    if (result.seq != board.seq || changed) {
      board.seq = result.seq;
      if (_boards[board.projectId] != board) return;
      board.rebuild();
      _save();
      notifyListeners();
    }
  }

  Future<void> _push(_Board board, BoardRelay relay) async {
    var conflicts = 0;
    while (board.pending.isNotEmpty && _boards[board.projectId] == board) {
      final MapEntry(key: id, value: data) = board.pending.entries.first;
      final result = await relay.put(id, board.remote[id]?.version ?? 0, data);
      switch (result) {
        case BoardWritten(:final version):
          board.remote[id] = (version: version, data: data);
          if (identical(board.pending[id], data)) board.pending.remove(id);
        case BoardConflict():
          if (++conflicts > 5) return;
          await _pull(board, relay);
          if (!board.keepsAfterConflict(id)) board.pending.remove(id);
        case BoardRejected(:final reason):
          debugPrint('[Boards] Relay refused $id: $reason');
          board.pending.remove(id);
        case BoardGone():
          _gone(board);
          return;
      }
      board.rebuild();
      _save();
      notifyListeners();
    }
  }

  /// The board was deleted on the relay by another device.
  void _gone(_Board board) {
    if (_boards[board.projectId] != board) return;
    _boards.remove(board.projectId);
    onTurnedOff?.call(board.projectId);
    _secretsChanged();
    _save();
    notifyListeners();
  }

  void _secretsChanged() {
    _pollWhileBoards();
    _persistSecrets();
    onSecretsChanged?.call();
  }

  void _persistSecrets() {
    final storage = _secrets;
    if (storage == null) return;
    unawaited(storage.setBoardSecrets(jsonEncode(secrets)));
  }

  void _save() {
    final cache = _cache;
    if (cache == null) return;
    unawaited(
      cache.save({
        'boards': [for (final b in _boards.values) b.toJson()],
      }),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _flushSoon?.cancel();
    super.dispose();
  }
}

typedef _Remote = ({int version, Map<String, Object?> data});

/// One board's records as last read from the relay, the local edits not yet
/// written, and the board they add up to.
class _Board {
  _Board._(this.projectId, this.secret, this.keys)
    : view = ProjectBoard(projectId: projectId);

  static _Board? tryCreate(String projectId, String secret) {
    try {
      return _Board._(projectId, secret, BoardKeys.fromSecret(secret));
    } catch (_) {
      return null;
    }
  }

  final String projectId;
  final String secret;
  final BoardKeys keys;
  int seq = 0;
  final Map<String, _Remote> remote = {};
  final Map<String, Map<String, Object?>> pending = {};
  ProjectBoard view;
  Future<void>? syncing;
  bool again = false;

  Map<String, Object?>? record(String id) => pending[id] ?? remote[id]?.data;

  void write(String id, Map<String, Object?> data) {
    pending[id] = data;
  }

  /// After a conflict on [id], whether the local edit still goes out. A
  /// deletion on either side wins; otherwise the later `updatedAt` does.
  bool keepsAfterConflict(String id) {
    final local = pending[id];
    final theirs = remote[id]?.data;
    if (local == null) return false;
    if (theirs == null) return true;
    if (theirs['deleted'] == true) return false;
    if (local['deleted'] == true) return true;
    return _time(local['updatedAt']) >= _time(theirs['updatedAt']);
  }

  static int _time(Object? value) => value is int ? value : 0;

  void rebuild() {
    final ids = {...remote.keys, ...pending.keys};
    view = ProjectBoard.fromRecords(projectId, {
      for (final id in ids) id: record(id)!,
    });
  }

  /// Fills in the cached records. A board that has already pulled keeps
  /// what it pulled; cached unsent edits are kept unless a newer local
  /// edit replaced them.
  void restore(Object? raw) {
    if (raw is! Map) return;
    final seq = raw['seq'];
    final fresh = this.seq == 0 && remote.isEmpty;
    if (fresh && seq is int) this.seq = seq;
    if (raw['remote'] case final Map records when fresh) {
      for (final MapEntry(:key, :value) in records.entries) {
        if (key is! String) continue;
        if (value case {
          'version': final int version,
          'data': final Map<String, Object?> data,
        }) {
          remote[key] = (version: version, data: data);
        }
      }
    }
    if (raw['pending'] case final Map records) {
      for (final MapEntry(:key, :value) in records.entries) {
        if (key is String && value is Map<String, Object?>) {
          pending.putIfAbsent(key, () => value);
        }
      }
    }
    rebuild();
  }

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'seq': seq,
    'remote': {
      for (final MapEntry(:key, :value) in remote.entries)
        key: {'version': value.version, 'data': value.data},
    },
    'pending': pending,
  };
}
