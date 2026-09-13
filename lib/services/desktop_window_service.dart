import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class DesktopWindowState {
  const DesktopWindowState({
    this.maximized = false,
    this.active = true,
    this.visible = true,
  });
  final bool maximized;
  final bool active;
  final bool visible;

  factory DesktopWindowState.fromMap(Map<Object?, Object?> data) =>
      DesktopWindowState(
        maximized: data['maximized'] == true,
        active: data['active'] == true,
        visible: data['visible'] == true,
      );
}

class DesktopWindowService extends ValueNotifier<DesktopWindowState> {
  DesktopWindowService({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.socketagent.app/desktop_window'),
      super(const DesktopWindowState());

  static final instance = DesktopWindowService();
  final MethodChannel _channel;

  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged' && call.arguments is Map) {
        value = DesktopWindowState.fromMap(call.arguments as Map);
      }
    });
    // Dart can start before the Windows runner finishes registering its
    // channels. Retry that specific startup race, without masking other errors.
    for (var attempt = 0; ; attempt++) {
      try {
        final state = await _channel.invokeMapMethod<Object?, Object?>(
          'getState',
        );
        if (state != null) value = DesktopWindowState.fromMap(state);
        return;
      } on MissingPluginException {
        if (attempt >= 99) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> show() => _channel.invokeMethod<void>('show');
  Future<void> hide() => _channel.invokeMethod<void>('hide');
  Future<void> minimize() => _channel.invokeMethod<void>('minimize');
  Future<void> toggleMaximize() =>
      _channel.invokeMethod<void>('toggleMaximize');
  Future<void> showMenu() => _channel.invokeMethod<void>('showMenu');
  Future<void> quit() => _channel.invokeMethod<void>('quit');
}
