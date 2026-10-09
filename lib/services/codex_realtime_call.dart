import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Microphone and speaker loudness, each 0..1.
typedef RealtimeLevels = ({double input, double output});

/// The media leg of a Codex voice call. The phone talks to OpenAI's realtime
/// servers directly over WebRTC; the server only carries the SDP exchange.
/// Abstracted so the service can be tested without a native peer connection.
abstract class RealtimeCall {
  /// Captures the microphone, gathers ICE candidates and returns the offer.
  Future<String> createOffer();

  Future<void> acceptAnswer(String sdp);

  /// Fires once when the media path connects, and again if it fails.
  ValueListenable<RealtimeCallState> get state;

  Future<RealtimeLevels> readLevels();

  Future<void> setMuted(bool muted);

  Future<void> setSpeakerphone(bool enabled);

  Future<void> close();
}

enum RealtimeCallState { negotiating, connected, failed, closed }

/// Realtime call over flutter_webrtc.
class WebRtcRealtimeCall implements RealtimeCall {
  RTCPeerConnection? _peer;
  MediaStream? _microphone;
  RTCDataChannel? _events;
  final _state = ValueNotifier<RealtimeCallState>(
    RealtimeCallState.negotiating,
  );

  @override
  ValueListenable<RealtimeCallState> get state => _state;

  @override
  Future<String> createOffer() async {
    if (!kIsWeb && Platform.isAndroid) {
      // Voice-call audio mode keeps hardware echo cancellation on and lets the
      // speakerphone toggle route audio.
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration(
          manageAudioFocus: true,
          androidAudioMode: AndroidAudioMode.inCommunication,
          androidAudioFocusMode: AndroidAudioFocusMode.gain,
          androidAudioStreamType: AndroidAudioStreamType.voiceCall,
          androidAudioAttributesUsageType:
              AndroidAudioAttributesUsageType.voiceCommunication,
          androidAudioAttributesContentType:
              AndroidAudioAttributesContentType.speech,
        ),
      );
    }
    // OpenAI answers with ice-lite host candidates on public addresses, so no
    // STUN or TURN server is needed on this side.
    final peer = await createPeerConnection({
      'iceServers': <Map<String, Object>>[],
      'sdpSemantics': 'unified-plan',
    });
    _peer = peer;
    peer.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _state.value = RealtimeCallState.connected;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _state.value = RealtimeCallState.failed;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _state.value = RealtimeCallState.closed;
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          break;
      }
    };
    final microphone = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    _microphone = microphone;
    for (final track in microphone.getAudioTracks()) {
      await peer.addTrack(track, microphone);
    }
    // The realtime API expects its events channel in the offer even though
    // Codex drives the session through its own sideband socket.
    _events = await peer.createDataChannel(
      'oai-events',
      RTCDataChannelInit()..ordered = true,
    );
    final gathered = Completer<void>();
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await peer.createOffer({'offerToReceiveAudio': true});
    await peer.setLocalDescription(offer);
    if (peer.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      // The answer is ice-lite, so every candidate must ride in the offer.
      // A slow interface should not hold the call hostage though.
      await gathered.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
    }
    final local = await peer.getLocalDescription();
    final sdp = local?.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('Could not build the WebRTC offer');
    }
    return sdp;
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    final peer = _peer;
    if (peer == null) throw StateError('The call has no peer connection');
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  Future<RealtimeLevels> readLevels() async {
    final peer = _peer;
    if (peer == null) return (input: 0.0, output: 0.0);
    var input = 0.0;
    var output = 0.0;
    for (final report in await peer.getStats()) {
      final Object? kind = report.values['kind'] ?? report.values['mediaType'];
      if (kind != 'audio') continue;
      final Object? level = report.values['audioLevel'];
      if (level is! num) continue;
      final value = level.toDouble().clamp(0.0, 1.0);
      if (report.type == 'inbound-rtp' && value > output) output = value;
      if (report.type == 'media-source' && value > input) input = value;
    }
    return (input: input, output: output);
  }

  @override
  Future<void> setMuted(bool muted) async {
    for (final track in _microphone?.getAudioTracks() ?? const []) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setSpeakerphone(bool enabled) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    await Helper.setSpeakerphoneOn(enabled);
  }

  @override
  Future<void> close() async {
    final microphone = _microphone;
    _microphone = null;
    for (final track in microphone?.getAudioTracks() ?? const []) {
      await track.stop();
    }
    await microphone?.dispose();
    await _events?.close();
    _events = null;
    final peer = _peer;
    _peer = null;
    await peer?.close();
    await peer?.dispose();
    if (_state.value != RealtimeCallState.failed) {
      _state.value = RealtimeCallState.closed;
    }
  }
}
