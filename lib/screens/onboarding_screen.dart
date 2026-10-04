import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import 'connect_computer_screen.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lost = context.read<ChatProvider>().savedComputersLost;
    return ConnectComputerScreen(
      firstRun: true,
      notice: lost
          ? 'This update could not read your saved computers. Scan each pairing code again.'
          : null,
    );
  }
}
