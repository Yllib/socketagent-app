# bonsoir_windows, patched

A copy of [`bonsoir_windows`](https://pub.dev/packages/bonsoir_windows) 7.3.0
with its discovery threading fixed. `pubspec.yaml` in the app points at this
folder through `dependency_overrides`.

## Why

Windows runs the DNS-SD browse and resolve callbacks on its own threads. The
published plugin let those callbacks read and change the discovery's service
list while the platform thread was changing it too, and it cancelled a browse
from inside that browse's own callback. The desktop app starts and stops a
discovery on every route search, so it crashed inside
`bonsoir_windows_plugin.dll` (access violation, heap corruption) or froze with
the platform thread waiting in `DnsServiceBrowseCancel`.

## What changed

- `windows/bonsoir_action.*`: `postToPlatformThread` runs a task on the
  platform thread for an action named by a number. A task for a disposed
  action is dropped.
- `windows/bonsoir_discovery.*`: the callbacks copy what Windows gave them,
  free it, and post it. All discovery state is used on the platform thread
  only, so the mutex is gone. Each resolve is tracked by ID and a service is
  not resolved twice at once. A failed start no longer disposes the discovery
  before Dart has stopped it. Errors with no details send a null value where
  the original passed `nullptr` to a string.

## Still open

Every `DnsServiceResolve` call leaves one thread-pool thread and two handles
behind until the process exits, with this patch or without it. Browsing does
not. The app avoids the resolve on Windows, where the browse result already
carries the TXT record; see `needsResolve` in `lib/services/local_route.dart`.

Nothing else differs from 7.3.0. Drop this folder and the override once a
published release fixes the same races.
