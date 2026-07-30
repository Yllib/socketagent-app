import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/work_review.dart';
import 'connection_manager.dart';

class WorkReviewServerEvent {
  final String serverId;
  final Map<String, dynamic> data;

  const WorkReviewServerEvent(this.serverId, this.data);
}

abstract class WorkReviewTransport {
  Stream<WorkReviewServerEvent> get events;

  bool send(String serverId, Map<String, dynamic> message);
}

class ConnectionManagerWorkReviewTransport implements WorkReviewTransport {
  final ConnectionManager connectionManager;

  const ConnectionManagerWorkReviewTransport(this.connectionManager);

  @override
  Stream<WorkReviewServerEvent> get events => connectionManager.messages.map(
    (event) => WorkReviewServerEvent(event.serverId, event.data),
  );

  @override
  bool send(String serverId, Map<String, dynamic> message) =>
      connectionManager.sendToServer(serverId, message);
}

abstract class WorkReviewCache {
  Future<Map<String, dynamic>?> read();

  Future<void> write(Map<String, dynamic> value);
}

class SharedPreferencesWorkReviewCache implements WorkReviewCache {
  static const _key = 'work_reviews_cache_v1';

  @override
  Future<Map<String, dynamic>?> read() async {
    final text = (await SharedPreferences.getInstance()).getString(_key);
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value));
  }
}

class WorkReviewRepository extends ChangeNotifier {
  final WorkReviewTransport transport;
  final WorkReviewCache cache;
  final Duration draftSyncDelay;

  final Map<String, WorkReview> _reviews = {};
  final Map<String, WorkReviewDraft> _drafts = {};
  final Map<String, Timer> _draftTimers = {};
  final Set<String> _locallyDirty = {};
  final Set<String> _publishing = {};
  final Map<String, String> _finishMutationIds = {};
  final Map<String, String> _errors = {};
  final Map<String, int> _capabilityVersions = {};
  final Map<String, Completer<WorkReview?>> _getCompleters = {};
  final Map<String, String> _draftRequestMutations = {};
  final Map<String, String> _draftInFlightRequests = {};
  final Map<String, Completer<void>> _draftIdleCompleters = {};
  StreamSubscription<WorkReviewServerEvent>? _subscription;
  bool _initialized = false;

  WorkReviewRepository({
    required this.transport,
    WorkReviewCache? cache,
    this.draftSyncDelay = const Duration(milliseconds: 650),
  }) : cache = cache ?? SharedPreferencesWorkReviewCache();

  static String identity(String serverId, String reviewId) =>
      '$serverId::$reviewId';

  bool get initialized => _initialized;

  List<WorkReview> reviewsForServer(
    String serverId, {
    bool includeArchived = false,
  }) {
    final result = _reviews.values
        .where(
          (review) =>
              review.serverId == serverId &&
              (includeArchived || review.status != WorkReviewStatus.archived),
        )
        .toList();
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  WorkReview? review(String reviewId, {String? serverId}) {
    if (serverId != null) return _reviews[identity(serverId, reviewId)];
    for (final review in _reviews.values) {
      if (review.id == reviewId) return review;
    }
    return null;
  }

  WorkReviewDraft? draft(String reviewId, {String? serverId}) {
    if (serverId != null) return _drafts[identity(serverId, reviewId)];
    for (final entry in _drafts.entries) {
      if (entry.value.reviewId == reviewId) return entry.value;
    }
    return null;
  }

  bool isPublishing(WorkReview review) =>
      _publishing.contains(identity(review.serverId, review.id));

  String? errorFor(WorkReview review) =>
      _errors[identity(review.serverId, review.id)];

  int pendingCount(String serverId) => reviewsForServer(
    serverId,
  ).where((review) => review.status == WorkReviewStatus.open).length;

  int? capabilityVersion(String serverId) => _capabilityVersions[serverId];

  bool supportsServer(String serverId) =>
      (_capabilityVersions[serverId] ?? 0) >= 1;

  Future<void> initialize() async {
    if (_initialized) return;
    _subscription = transport.events.listen(
      (event) => handleServerMessage(event.serverId, event.data),
    );
    await _restoreCache();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _restoreCache() async {
    final data = await cache.read();
    if (data == null) return;
    for (final raw in (data['reviews'] as List? ?? const []).whereType<Map>()) {
      final map = Map<String, dynamic>.from(raw);
      final serverId = map.remove('_serverId')?.toString() ?? '';
      if (serverId.isEmpty) continue;
      final review = WorkReview.fromJson(map, serverId: serverId);
      if (review.id.isNotEmpty) {
        _reviews[identity(serverId, review.id)] = review;
      }
    }
    for (final raw in (data['drafts'] as List? ?? const []).whereType<Map>()) {
      final map = Map<String, dynamic>.from(raw);
      final serverId = map.remove('_serverId')?.toString() ?? '';
      final reviewId = map['reviewId']?.toString() ?? '';
      if (serverId.isEmpty || reviewId.isEmpty) continue;
      final draft = WorkReviewDraft.fromJson(
        map,
        reviewId: reviewId,
        roundId: map['roundId']?.toString() ?? '1',
      );
      _drafts[identity(serverId, reviewId)] = draft;
    }
    for (final review in _reviews.values) {
      _ensurePublishedDraft(review);
    }
  }

  Future<void> _persist() => cache.write({
    'reviews': [
      for (final review in _reviews.values)
        {...review.toJson(), '_serverId': review.serverId},
    ],
    'drafts': [
      for (final entry in _drafts.entries)
        {
          ...entry.value.toCacheJson(),
          '_serverId': entry.key.substring(0, entry.key.indexOf('::')),
        },
    ],
  });

  void refresh({
    required String serverId,
    String? sessionId,
    bool includeArchived = false,
  }) {
    if (!supportsServer(serverId)) return;
    transport.send(serverId, {
      'type': 'work_review_list',
      'requestId': _requestId('list'),
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      'includeArchived': includeArchived,
    });
  }

  Future<WorkReview?> fetch(
    WorkReview review, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    final requestId = _requestId('get');
    final completer = Completer<WorkReview?>();
    _getCompleters[requestId] = completer;
    final sent = transport.send(review.serverId, {
      'type': 'work_review_get',
      'requestId': requestId,
      'reviewId': review.id,
    });
    if (!sent) {
      _getCompleters.remove(requestId);
      return Future.value(this.review(review.id, serverId: review.serverId));
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _getCompleters.remove(requestId);
        return this.review(review.id, serverId: review.serverId);
      },
    );
  }

  void handleServerMessage(String serverId, Map<String, dynamic> message) {
    final type = message['type']?.toString();
    switch (type) {
      case 'server_capabilities':
        final capability = message['workReviews'];
        _capabilityVersions[serverId] = capability is Map
            ? int.tryParse(capability['version']?.toString() ?? '') ?? 0
            : 0;
        notifyListeners();
        break;
      case 'work_review_snapshot':
        _handleSnapshot(serverId, message);
        break;
      case 'work_review_list_result':
        _handleList(serverId, message);
        break;
      case 'work_review_operation_result':
        _handleOperationResult(serverId, message);
        break;
      case 'work_review_card':
        _handleCard(serverId, message);
        break;
    }
  }

  void _handleSnapshot(String serverId, Map<String, dynamic> message) {
    final reviewMap = _extractReview(message);
    if (reviewMap == null) return;
    final review = WorkReview.fromJson(reviewMap, serverId: serverId);
    if (review.id.isEmpty) return;
    _upsertReview(review);
    final rawDraft = message['draft'];
    if (rawDraft is Map) {
      _acceptServerDraft(
        review,
        WorkReviewDraft.fromJson(
          Map<String, dynamic>.from(rawDraft),
          reviewId: review.id,
          roundId: review.roundId,
        ),
      );
    } else {
      _ensurePublishedDraft(review);
    }
    final requestId = message['requestId']?.toString();
    final completer = requestId == null
        ? null
        : _getCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(_reviews[identity(serverId, review.id)]);
    }
    unawaited(_persist());
    notifyListeners();
  }

  void _handleCard(String serverId, Map<String, dynamic> message) {
    final reviewMap = _extractReview(message);
    if (reviewMap == null) return;
    final review = WorkReview.fromJson(reviewMap, serverId: serverId);
    if (review.id.isEmpty) return;
    _upsertReview(review);
    _ensurePublishedDraft(review);
    unawaited(_persist());
    notifyListeners();
  }

  void _handleList(String serverId, Map<String, dynamic> message) {
    for (final raw
        in (message['reviews'] as List? ?? const []).whereType<Map>()) {
      final review = WorkReview.fromJson(
        Map<String, dynamic>.from(raw),
        serverId: serverId,
      );
      if (review.id.isNotEmpty) _upsertReview(review);
    }
    unawaited(_persist());
    notifyListeners();
  }

  void _handleOperationResult(String serverId, Map<String, dynamic> message) {
    final reviewId = message['reviewId']?.toString() ?? '';
    if (reviewId.isEmpty) return;
    final key = identity(serverId, reviewId);
    final operation = message['operation']?.toString();
    final requestId = message['requestId']?.toString();
    if (message['ok'] != true) {
      final failedMutation = requestId == null
          ? null
          : _draftRequestMutations.remove(requestId);
      if (operation == 'draft_update' && requestId != null) {
        _completeDraftRequest(
          key,
          requestId,
          failedMutation,
          retryIfNewer: true,
        );
      }
      _errors[key] =
          message['error']?.toString() ?? 'Could not save work review';
      if (operation == 'get') {
        final completer = requestId == null
            ? null
            : _getCompleters.remove(requestId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(null);
        }
      }
      if (operation == 'finish') _publishing.remove(key);
      notifyListeners();
      return;
    }
    _errors.remove(key);
    final reviewMap = _extractReview(message);
    if (reviewMap != null) {
      final review = WorkReview.fromJson(reviewMap, serverId: serverId);
      if (review.id.isNotEmpty) _upsertReview(review);
    }
    final rawDraft = message['draft'];
    final current = _drafts[key];
    if (rawDraft is Map && current != null) {
      final serverDraft = WorkReviewDraft.fromJson(
        Map<String, dynamic>.from(rawDraft),
        reviewId: reviewId,
        roundId: message['roundId']?.toString() ?? current.roundId,
      );
      // The acknowledgement advances the base revision without replacing
      // edits made while the request was in flight.
      _drafts[key] = current.copyWith(revision: serverDraft.revision);
    }
    if (operation == 'draft_update') {
      final acknowledgedMutation = requestId == null
          ? null
          : _draftRequestMutations.remove(requestId);
      if (acknowledgedMutation != null &&
          _drafts[key]?.mutationId == acknowledgedMutation) {
        _locallyDirty.remove(key);
      }
      if (requestId != null) {
        _completeDraftRequest(
          key,
          requestId,
          acknowledgedMutation,
          retryIfNewer: true,
        );
      }
    } else if (operation == 'finish') {
      _publishing.remove(key);
      _finishMutationIds.remove(key);
      _locallyDirty.remove(key);
    }
    unawaited(_persist());
    notifyListeners();
  }

  Map<String, dynamic>? _extractReview(Map<String, dynamic> message) {
    final nested = message['review'];
    final result = nested is Map
        ? Map<String, dynamic>.from(nested)
        : Map<String, dynamic>.from(message);
    final reviewId = message['reviewId'];
    final sessionId = message['sessionId'];
    if (reviewId != null) result.putIfAbsent('reviewId', () => reviewId);
    if (sessionId != null) result.putIfAbsent('sessionId', () => sessionId);
    result.remove('type');
    result.remove('requestId');
    result.remove('draft');
    return result;
  }

  void _upsertReview(WorkReview incoming) {
    final key = identity(incoming.serverId, incoming.id);
    final existing = _reviews[key];
    if (existing != null &&
        incoming.items.isEmpty &&
        existing.items.isNotEmpty) {
      final merged = <String, dynamic>{
        ...existing.toJson(),
        ...incoming.toJson(),
      };
      merged['items'] = existing.items.map((item) => item.toJson()).toList();
      _reviews[key] = WorkReview.fromJson(merged, serverId: incoming.serverId);
    } else {
      _reviews[key] = incoming;
    }
    final review = _reviews[key]!;
    final draft = _drafts.putIfAbsent(key, () => WorkReviewDraft.empty(review));
    if (review.items.any((item) => !draft.items.containsKey(item.id))) {
      _drafts[key] = draft.copyWith(
        items: {
          for (final item in review.items)
            item.id:
                draft.items[item.id] ?? WorkReviewItemDraft(itemId: item.id),
          ...draft.items,
        },
      );
    }
  }

  void _acceptServerDraft(WorkReview review, WorkReviewDraft serverDraft) {
    final key = identity(review.serverId, review.id);
    final local = _drafts[key];
    if (local == null ||
        (!_locallyDirty.contains(key) &&
            serverDraft.revision >= local.revision)) {
      final items = <String, WorkReviewItemDraft>{
        for (final item in review.items)
          item.id:
              serverDraft.items[item.id] ??
              WorkReviewItemDraft(itemId: item.id),
        ...serverDraft.items,
      };
      _drafts[key] = serverDraft.copyWith(items: items);
    }
  }

  void _ensurePublishedDraft(WorkReview review) {
    final result = review.result;
    if (review.status == WorkReviewStatus.open || result == null) return;
    final key = identity(review.serverId, review.id);
    final existing = _drafts[key];
    if (existing != null &&
        existing.items.values.any(
          (item) => item.disposition != null || item.notes.isNotEmpty,
        )) {
      return;
    }
    _drafts[key] = WorkReviewDraft.fromJson(
      {
        'revision': result['draftRevision'] ?? result['revision'] ?? 0,
        'updatedAt':
            result['publishedAt'] ?? review.updatedAt.toIso8601String(),
        if (result['overallNote'] != null) 'overallNote': result['overallNote'],
        'items': result['itemResults'] ?? const [],
      },
      reviewId: review.id,
      roundId: review.roundId,
    );
  }

  WorkReviewDraft ensureDraft(WorkReview review) {
    final key = identity(review.serverId, review.id);
    _reviews.putIfAbsent(key, () => review);
    _ensurePublishedDraft(review);
    return _drafts.putIfAbsent(key, () => WorkReviewDraft.empty(review));
  }

  void setCurrentItem(WorkReview review, String itemId) {
    _changeDraft(review, (draft) => draft.copyWith(currentItemId: itemId));
  }

  void setDisposition(
    WorkReview review,
    String itemId,
    WorkReviewDisposition disposition,
  ) {
    _changeDraft(review, (draft) {
      final items = Map<String, WorkReviewItemDraft>.from(draft.items);
      items[itemId] = (items[itemId] ?? WorkReviewItemDraft(itemId: itemId))
          .copyWith(disposition: disposition);
      return draft.copyWith(items: items);
    });
  }

  void setItemNotes(WorkReview review, String itemId, String notes) {
    _changeDraft(review, (draft) {
      final items = Map<String, WorkReviewItemDraft>.from(draft.items);
      items[itemId] = (items[itemId] ?? WorkReviewItemDraft(itemId: itemId))
          .copyWith(notes: notes);
      return draft.copyWith(items: items);
    });
  }

  void setOverallNotes(WorkReview review, String notes) {
    _changeDraft(review, (draft) => draft.copyWith(overallNotes: notes));
  }

  void _changeDraft(
    WorkReview review,
    WorkReviewDraft Function(WorkReviewDraft) update,
  ) {
    final key = identity(review.serverId, review.id);
    final current = ensureDraft(review);
    final changed = update(
      current,
    ).copyWith(mutationId: _mutationId(review.id), updatedAt: DateTime.now());
    _drafts[key] = changed;
    _locallyDirty.add(key);
    _errors.remove(key);
    _draftTimers[key]?.cancel();
    _draftTimers[key] = Timer(draftSyncDelay, () => _syncDraft(review));
    unawaited(_persist());
    notifyListeners();
  }

  bool _syncDraft(WorkReview review) {
    final key = identity(review.serverId, review.id);
    final draft = _drafts[key];
    if (draft == null || draft.mutationId.isEmpty) return false;
    // Serialize private draft snapshots per review. If the reviewer edits
    // again while one save is awaiting acknowledgement, the completion path
    // below sends the newest full snapshot with the advanced server revision.
    if (_draftInFlightRequests.containsKey(key)) return true;
    final requestId = _requestId('draft');
    _draftRequestMutations[requestId] = draft.mutationId;
    final sent = transport.send(review.serverId, {
      'type': 'work_review_draft_update',
      'requestId': requestId,
      'reviewId': review.id,
      'roundId': draft.roundId,
      'mutationId': draft.mutationId,
      'baseRevision': draft.revision,
      'draft': draft.toWireJson(),
    });
    if (!sent) {
      _draftRequestMutations.remove(requestId);
      _errors[key] =
          'Draft is saved on this device and will sync when connected';
      notifyListeners();
    } else {
      _draftInFlightRequests[key] = requestId;
      _draftIdleCompleters[key] = Completer<void>();
    }
    return sent;
  }

  Future<bool> finishReview(WorkReview review) async {
    final key = identity(review.serverId, review.id);
    var draft = ensureDraft(review);
    if (!draft.isComplete || _publishing.contains(key)) return false;
    _draftTimers.remove(key)?.cancel();
    final mutationId = _finishMutationIds.putIfAbsent(
      key,
      () => _mutationId('${review.id}_finish'),
    );
    _publishing.add(key);
    _errors.remove(key);
    notifyListeners();

    // A normal draft save may already be on the wire. Let its acknowledgement
    // advance our base revision before publishing. If the connection never
    // acknowledges it, Finish still sends the complete final snapshot without
    // a stale concurrency cursor; the server seals that snapshot atomically.
    final idle = _draftIdleCompleters[key];
    if (idle != null && !idle.isCompleted) {
      try {
        await idle.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // The complete Finish snapshot remains authoritative.
      }
    }
    _draftTimers.remove(key)?.cancel();
    draft = ensureDraft(review);
    final draftSaveStillInFlight = _draftInFlightRequests.containsKey(key);
    final sent = transport.send(review.serverId, {
      'type': 'work_review_finish',
      'requestId': _requestId('finish'),
      'reviewId': review.id,
      'roundId': draft.roundId,
      'mutationId': mutationId,
      if (!draftSaveStillInFlight) 'baseRevision': draft.revision,
      'draft': draft.toWireJson(),
    });
    if (!sent) {
      _publishing.remove(key);
      _errors[key] = 'Could not publish while the server is disconnected';
      notifyListeners();
    }
    return sent;
  }

  void _completeDraftRequest(
    String key,
    String requestId,
    String? completedMutation, {
    required bool retryIfNewer,
  }) {
    if (_draftInFlightRequests[key] != requestId) return;
    _draftInFlightRequests.remove(key);
    final idle = _draftIdleCompleters.remove(key);
    if (idle != null && !idle.isCompleted) idle.complete();

    final current = _drafts[key];
    final review = _reviews[key];
    if (retryIfNewer &&
        review != null &&
        current != null &&
        _locallyDirty.contains(key) &&
        current.mutationId != completedMutation &&
        !_publishing.contains(key)) {
      _draftTimers.remove(key)?.cancel();
      _draftTimers[key] = Timer(draftSyncDelay, () => _syncDraft(review));
    }
  }

  String _requestId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

  String _mutationId(String reviewId) =>
      '${reviewId}_${DateTime.now().microsecondsSinceEpoch}';

  @override
  void dispose() {
    for (final timer in _draftTimers.values) {
      timer.cancel();
    }
    for (final completer in _draftIdleCompleters.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _subscription?.cancel();
    for (final completer in _getCompleters.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    super.dispose();
  }
}
