import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../services/work_review_repository.dart';
import '../ui_variant.dart';
import 'shell/ui_c_nav.dart';
import 'shell/ui_c_shell.dart';
import 'state/live_ui_c_store.dart';
import 'state/ui_c_store.dart';
import 'theme/ui_c_theme.dart';

/// Entry point of redesign C, the Switchboard. Adapts the app's ChatProvider
/// into the interface's store, loads the saved theme, and hands over to
/// [UiCHost].
class UiCRoot extends StatefulWidget {
  const UiCRoot({super.key});

  @override
  State<UiCRoot> createState() => _UiCRootState();
}

class _UiCRootState extends State<UiCRoot> {
  LiveUiCStore? _store;
  UiCThemeController _theme = UiCThemeController();

  @override
  void initState() {
    super.initState();
    UiCThemeController.load().then((loaded) {
      if (!mounted) return;
      setState(() => _theme = loaded);
    });
  }

  @override
  Widget build(BuildContext context) {
    _store ??= LiveUiCStore(
      context.read<ChatProvider>(),
      context.read<WorkReviewRepository>(),
    );
    return UiCHost(
      store: _store!,
      theme: _theme,
      openRequests: context.read<UiVariantController>().sessionOpenRequests,
    );
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }
}

/// Everything below the data layer. Tests mount this with a fake store.
class UiCHost extends StatefulWidget {
  const UiCHost({
    super.key,
    required this.store,
    required this.theme,
    this.openRequests,
    this.forceDesktop,
  });

  final UiCStore store;
  final UiCThemeController theme;

  /// Bumped by the app when a notification tap made a session current.
  final ValueListenable<int>? openRequests;
  final bool? forceDesktop;

  @override
  State<UiCHost> createState() => _UiCHostState();
}

class _UiCHostState extends State<UiCHost> {
  late final UiCNav _nav = UiCNav(widget.store);

  @override
  void initState() {
    super.initState();
    widget.openRequests?.addListener(_onOpenRequest);
  }

  @override
  void didUpdateWidget(UiCHost old) {
    super.didUpdateWidget(old);
    if (old.openRequests != widget.openRequests) {
      old.openRequests?.removeListener(_onOpenRequest);
      widget.openRequests?.addListener(_onOpenRequest);
    }
  }

  void _onOpenRequest() => _nav.showCurrentSession();

  @override
  void dispose() {
    widget.openRequests?.removeListener(_onOpenRequest);
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<UiCStore>.value(value: widget.store),
        ChangeNotifierProvider<UiCNav>.value(value: _nav),
        ChangeNotifierProvider<UiCThemeController>.value(value: widget.theme),
      ],
      child: Consumer<UiCThemeController>(
        builder: (context, theme, _) => Theme(
          data: buildUiCThemeData(theme.id),
          child: UiCShell(forceDesktop: widget.forceDesktop),
        ),
      ),
    );
  }
}
