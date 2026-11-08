import 'package:flutter/material.dart';

/// [showModalBottomSheet] with its content kept above the system navigation
/// bar. The app draws edge to edge, and a sheet's own safe area covers only
/// the top and sides, so without this the last row sits under the Android
/// buttons. The sheet's background still runs to the screen edge.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  Color? backgroundColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    shape: shape,
    constraints: constraints,
    routeSettings: routeSettings,
    builder: (sheetContext) =>
        SafeArea(top: false, child: builder(sheetContext)),
  );
}
