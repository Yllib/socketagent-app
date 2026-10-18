import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Re-provides a listenable provider such as `ChatProvider` to a tab that
/// can sit hidden in an [IndexedStack] or under another route. While hidden,
/// provider changes do not rebuild the tab, so a streaming reply does not
/// rebuild every tab each frame. The tab catches up with one rebuild when
/// shown again.
class PauseWhileHidden<T extends Listenable> extends StatefulWidget {
  const PauseWhileHidden({super.key, required this.child});

  final Widget child;

  @override
  State<PauseWhileHidden<T>> createState() => _PauseWhileHiddenState<T>();
}

class _PauseWhileHiddenState<T extends Listenable>
    extends State<PauseWhileHidden<T>> {
  late final T _provider = context.read<T>();
  final _changes = ValueNotifier(0);
  var _visible = true;
  var _missed = false;

  @override
  void initState() {
    super.initState();
    _provider.addListener(_forward);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // IndexedStack reports hidden tabs through Visibility; a covered route
    // has its tickers turned off.
    final visible =
        Visibility.of(context) && TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    if (visible && _missed) {
      _missed = false;
      _changes.value++;
    }
  }

  void _forward() {
    if (_visible) {
      _changes.value++;
    } else {
      _missed = true;
    }
  }

  @override
  void dispose() {
    _provider.removeListener(_forward);
    _changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InheritedProvider<T>.value(
      value: _provider,
      startListening: (element, _) {
        _changes.addListener(element.markNeedsNotifyDependents);
        return () => _changes.removeListener(element.markNeedsNotifyDependents);
      },
      child: widget.child,
    );
  }
}
