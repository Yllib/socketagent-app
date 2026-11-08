import 'package:flutter_test/flutter_test.dart';

import 'multi_client_prompt_test.dart' show withSession;

/// A Codex session's picker shows the list Codex itself reports, with the
/// SKILL.md scan filling in only names Codex did not mention.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Codex supported commands merge into the slash command picker',
    () async {
      await withSession((provider, send) async {
        await send({'type': 'session_created', 'backend': 'codex'});
        await send({
          'type': 'skills_list',
          'projectCwd': '/repo',
          'codexSlashCommands': [
            {'name': 'status', 'description': 'Show Codex session status.'},
          ],
          'skills': [
            {
              'name': 'unslop',
              'description': 'scan copy',
              'agent': 'codex',
              'scope': 'user',
              'format': 'skill',
              'filePath': '/scan/unslop/SKILL.md',
            },
            {
              'name': 'local-only',
              'description': 'only the scan saw this',
              'agent': 'codex',
              'scope': 'project',
              'format': 'skill',
              'filePath': '/repo/.codex/skills/local-only/SKILL.md',
            },
          ],
        });
        await send({
          'type': 'supported_commands',
          'commands': [
            {
              'name': 'goal',
              'description': 'Goal',
              'kind': 'command',
              'agent': 'codex',
            },
            {
              'name': 'unslop',
              'description': 'Cut AI tells',
              'kind': 'skill',
              'agent': 'codex',
              'path': '/home/me/.codex/skills/unslop/SKILL.md',
              'scope': 'user',
            },
            {
              'name': 'plugin-management',
              'description': 'Manage plugins',
              'kind': 'skill',
              'agent': 'codex',
              'pluginName': 'Plugin Management',
            },
          ],
        });

        expect(provider.activeSessionBackend, 'codex');
        expect(provider.activeServerId, 'multi-client-server');
        final commands = provider.slashCommands;
        expect(commands.map((c) => c['name']).toList(), [
          'goal',
          'status',
          'local-only',
          'plugin-management',
          'unslop',
        ]);
        final unslop = commands.singleWhere((c) => c['name'] == 'unslop');
        expect(unslop['description'], 'Cut AI tells');
        expect(unslop['kind'], 'skill');
        final plugin = commands.singleWhere(
          (c) => c['name'] == 'plugin-management',
        );
        expect(plugin['pluginName'], 'Plugin Management');
        expect(
          commands.singleWhere((c) => c['name'] == 'local-only')['kind'],
          'skill',
        );
      });
    },
  );
}
