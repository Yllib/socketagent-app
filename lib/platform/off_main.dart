import 'dart:async';
import 'dart:isolate';

import 'app_platform.dart';

/// Runs [work] on a background isolate, or inline in a browser, which has
/// no isolates. Use it instead of Isolate.run in code the web build reaches.
Future<R> runOffMain<R>(FutureOr<R> Function() work) =>
    AppPlatform.isWeb ? Future.sync(work) : Isolate.run(work);
