import 'dart:math' as math;
import 'dart:typed_data';

enum DiffOp { same, removed, added }

typedef DiffLine = ({DiffOp op, String text});

/// Larger tables fall back to a plain remove-all, add-all diff.
const _maxTableCells = 4000000;

/// Line diff of [oldText] against [newText] using a longest common
/// subsequence table. Shared prefix and suffix lines are trimmed first, so a
/// small change inside a long edit stays cheap. Removals come before
/// additions within each changed run.
List<DiffLine> lineDiff(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');

  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }

  final out = <DiffLine>[
    for (var i = 0; i < start; i++) (op: DiffOp.same, text: a[i]),
  ];
  final n = endA - start;
  final m = endB - start;

  if (n * m > _maxTableCells) {
    out.addAll([
      for (var i = start; i < endA; i++) (op: DiffOp.removed, text: a[i]),
      for (var j = start; j < endB; j++) (op: DiffOp.added, text: b[j]),
    ]);
  } else {
    // lcs[i][j] is the LCS length of the middle slices from i and j onward.
    final lcs = List.generate(n + 1, (_) => Int32List(m + 1));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = a[start + i] == b[start + j]
            ? lcs[i + 1][j + 1] + 1
            : math.max(lcs[i + 1][j], lcs[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && a[start + i] == b[start + j]) {
        out.add((op: DiffOp.same, text: a[start + i]));
        i++;
        j++;
      } else if (j == m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1])) {
        out.add((op: DiffOp.removed, text: a[start + i]));
        i++;
      } else {
        out.add((op: DiffOp.added, text: b[start + j]));
        j++;
      }
    }
  }

  return [
    ...out,
    for (var i = endA; i < a.length; i++) (op: DiffOp.same, text: a[i]),
  ];
}
