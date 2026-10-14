import 'package:app/models/message.dart';
import 'package:app/models/session_folder_tree.dart';
import 'package:app/models/session_grouping.dart';
import 'package:app/models/session_projects.dart';
import 'package:flutter_test/flutter_test.dart';

SessionTreeNode chat(
  String id,
  String cwd, {
  String serverId = 'a',
  String lastActive = '2026-10-01T12:00:00Z',
}) => SessionTreeNode(
  Session(
    id: id,
    title: id,
    cwd: cwd,
    createdAt: DateTime.parse('2026-10-01T11:00:00Z'),
    lastActive: DateTime.parse(lastActive),
    messagePreview: '',
    serverId: serverId,
  ),
);

void main() {
  const computers = [(id: 'a', name: 'Desk'), (id: 'b', name: 'Laptop')];

  test('folders nest by working directory and merge single-child chains', () {
    final tree = buildSessionFolders([
      chat('one', '/home/billy/agents/socketagent'),
      chat(
        'two',
        '/home/billy/agents/socketagent',
        lastActive: '2026-10-02T12:00:00Z',
      ),
      chat('three', '/home/billy/agents/relay'),
      chat('four', '/home/billy/agents'),
    ], computers);

    expect(tree.map((f) => f.label), ['Desk'], reason: 'no empty computers');
    final agents = tree.single.folders.single;
    expect(agents.label, '/home/billy/agents');
    expect(agents.sessions.map((n) => n.session.id), ['four']);
    expect(agents.folders.map((f) => f.label), ['relay', 'socketagent']);
    expect(agents.folders.last.sessions.map((n) => n.session.id), [
      'two',
      'one',
    ], reason: 'newest first');
    expect(tree.single.sessionCount, 4);
  });

  test('Windows paths keep their separator and computers stay apart', () {
    final tree = buildSessionFolders([
      chat('w', r'C:\Users\billy\code', serverId: 'b'),
      chat('l', '/srv/app'),
    ], computers);
    expect(tree.map((f) => f.label), ['Desk', 'Laptop']);
    expect(tree.last.folders.single.label, r'C:\Users\billy\code');
    expect(tree.first.folders.single.label, '/srv/app');
  });

  test('deleting a project ungroups its chats', () {
    final projects = SessionProjects();
    final id = projects.create('Website');
    projects.assign(['s1', 's2'], id);
    expect(projects.projectOf('s1'), id);
    projects.delete(id);
    expect(projects.projectOf('s1'), isNull);
    expect(projects.members, isEmpty);
    final restored = SessionProjects.fromJson(projects.toJson());
    expect(restored.names, isEmpty);
  });
}
