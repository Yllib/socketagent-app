import 'package:app/widgets/pause_while_hidden.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Counter extends ChangeNotifier {
  int value = 0;

  void bump() {
    value++;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'a hidden tab skips provider rebuilds and catches up when shown',
    (tester) async {
      final counter = _Counter();
      var builds = 0;
      // One instance, so switching tabs alone never rebuilds the Consumer.
      final tab = PauseWhileHidden<_Counter>(
        child: Consumer<_Counter>(
          builder: (_, counter, _) {
            builds++;
            return Text('count ${counter.value}');
          },
        ),
      );
      Widget app(int index) => ChangeNotifierProvider.value(
        value: counter,
        child: MaterialApp(
          home: IndexedStack(index: index, children: [const SizedBox(), tab]),
        ),
      );

      await tester.pumpWidget(app(1));
      counter.bump();
      await tester.pump();
      expect(find.text('count 1'), findsOneWidget);

      await tester.pumpWidget(app(0));
      final hiddenBuilds = builds;
      counter.bump();
      await tester.pump();
      counter.bump();
      await tester.pump();
      expect(builds, hiddenBuilds);

      await tester.pumpWidget(app(1));
      expect(find.text('count 3'), findsOneWidget);
    },
  );
}
