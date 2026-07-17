import 'package:app/screens/project_instructions_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joins Unix project instruction paths', () {
    expect(
      joinProjectInstructionPath('/home/user/project/', 'AGENTS.md'),
      '/home/user/project/AGENTS.md',
    );
  });

  test('joins Windows project instruction paths', () {
    expect(
      joinProjectInstructionPath(r'C:\Users\user\project\', 'CLAUDE.md'),
      r'C:\Users\user\project\CLAUDE.md',
    );
  });
}
