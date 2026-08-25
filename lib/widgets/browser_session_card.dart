import 'package:flutter/material.dart';

import '../models/message.dart';
import '../screens/browser_session_screen.dart';

class BrowserSessionCard extends StatelessWidget {
  const BrowserSessionCard({super.key, required this.message, this.serverId});

  final ChatMessage message;
  final String? serverId;

  @override
  Widget build(BuildContext context) {
    final input = message.toolInput ?? const <String, dynamic>{};
    final profile = input['profile'] as String? ?? '';
    final label = input['label'] as String? ?? profile;
    final url = input['url'] as String? ?? '';
    final width = (input['width'] as num?)?.toInt() ?? 430;
    final height = (input['height'] as num?)?.toInt() ?? 860;
    final runtimeRequired = input['runtimeRequired'] == true;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.black,
        border: Border(
          top: BorderSide(color: Color(0xFF333333)),
          bottom: BorderSide(color: Color(0xFF333333)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.public, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  runtimeRequired
                      ? 'Browser component required on this computer.'
                      : 'Remote browser. Passwords and MFA stay out of chat.',
                  style: const TextStyle(
                    color: Color(0xFFAAAAAA),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: profile.isEmpty || url.isEmpty
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BrowserSessionScreen(
                        profile: profile,
                        label: label,
                        initialUrl: url,
                        browserWidth: width,
                        browserHeight: height,
                        serverId: serverId,
                        initialRuntimeRequired: runtimeRequired,
                      ),
                    ),
                  ),
            child: Text(runtimeRequired ? 'Install' : 'Open'),
          ),
        ],
      ),
    );
  }
}
