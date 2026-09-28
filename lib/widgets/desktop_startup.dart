import 'package:flutter/material.dart';
import 'desktop_window_frame.dart';

/// Paint the native window controls before starting disk, plugin or network work.
class DesktopStartup extends StatefulWidget {
  const DesktopStartup({super.key, required this.initialize});
  final Future<Widget> Function() initialize;

  @override
  State<DesktopStartup> createState() => _DesktopStartupState();
}

class _DesktopStartupState extends State<DesktopStartup> {
  Widget? _app;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    setState(() => _failed = false);
    try {
      final app = await widget.initialize();
      if (mounted) setState(() => _app = app);
    } catch (error) {
      debugPrint('[Startup] Initialization failed: ${error.runtimeType}');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _app ??
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(surface: Colors.black),
        ),
        builder: (context, child) => Overlay.wrap(
          child: DesktopWindowFrame(child: child ?? const SizedBox.shrink()),
        ),
        home: Scaffold(
          body: Center(
            child: _failed
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not open SocketAgent'),
                      TextButton(
                        onPressed: _start,
                        child: const Text('Try again'),
                      ),
                    ],
                  )
                : const Text('Opening SocketAgent…'),
          ),
        ),
      );
}
