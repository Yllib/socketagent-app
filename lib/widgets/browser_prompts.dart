import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';

/// Every prompt route carries this name, so a prompt the page withdraws can
/// be closed without touching anything else on the navigator.
const browserPromptRouteName = 'browser-prompt';
const _promptRoute = RouteSettings(name: browserPromptRouteName);

/// The viewer's answer to a browser prompt. `accept: false` cancels it.
typedef BrowserPromptAnswer = ({
  bool accept,
  String? value,
  String? username,
  String? password,
});

const BrowserPromptAnswer _cancelled = (
  accept: false,
  value: null,
  username: null,
  password: null,
);

BrowserPromptAnswer _accepted([String? value]) =>
    (accept: true, value: value, username: null, password: null);

/// Closes whatever prompt is showing, for when the page no longer needs it.
void closeBrowserPrompts(BuildContext context) {
  Navigator.of(
    context,
  ).popUntil((route) => route.settings.name != browserPromptRouteName);
}

/// Shows the phone's own control for a dropdown, picker, dialog, or sign-in
/// the page asked for, and returns the answer. File choosers are handled by
/// the caller, which has to upload the files.
Future<BrowserPromptAnswer> showBrowserPrompt(
  BuildContext context,
  Map<String, dynamic> prompt,
) async {
  return switch (prompt['kind']) {
    'select' => _select(context, prompt),
    'picker' => _picker(context, prompt),
    'dialog' => _dialog(context, prompt),
    'auth' => _auth(context, prompt),
    _ => _cancelled,
  };
}

Future<BrowserPromptAnswer> _select(
  BuildContext context,
  Map<String, dynamic> prompt,
) async {
  final options = (prompt['options'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final value = await showModalBottomSheet<String>(
    context: context,
    routeSettings: _promptRoute,
    backgroundColor: Colors.black,
    isScrollControlled: true,
    builder: (sheetContext) {
      String? lastGroup;
      final rows = <Widget>[];
      for (final option in options) {
        final group = option['group'] as String?;
        if (group != null && group != lastGroup) {
          rows.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                group,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }
        lastGroup = group;
        final disabled = option['disabled'] == true;
        final selected = option['selected'] == true;
        rows.add(
          ListTile(
            dense: true,
            enabled: !disabled,
            contentPadding: EdgeInsets.only(
              left: group == null ? 16 : 28,
              right: 16,
            ),
            title: Text(option['label'] as String? ?? ''),
            trailing: selected ? const Icon(Icons.check) : null,
            onTap: () =>
                Navigator.pop(sheetContext, option['value'] as String? ?? ''),
          ),
        );
      }
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: ListView(shrinkWrap: true, children: rows),
        ),
      );
    },
  );
  return value == null ? _cancelled : _accepted(value);
}

Future<BrowserPromptAnswer> _picker(
  BuildContext context,
  Map<String, dynamic> prompt,
) async {
  final type = prompt['inputType'] as String? ?? 'date';
  final value = prompt['value'] as String? ?? '';
  if (type == 'color') return _color(context, value);
  if (type == 'time') {
    final time = await _pickTime(context, value);
    return time == null ? _cancelled : _accepted(_formatTime(time));
  }
  final firstDate = _parseDate(prompt['min'] as String?) ?? DateTime(1900);
  final lastDate = _parseDate(prompt['max'] as String?) ?? DateTime(2100);
  final current = _parseDate(value) ?? DateTime.now();
  final date = await showDatePicker(
    context: context,
    routeSettings: _promptRoute,
    firstDate: firstDate,
    lastDate: lastDate,
    initialDate: current.isBefore(firstDate)
        ? firstDate
        : current.isAfter(lastDate)
        ? lastDate
        : current,
    initialDatePickerMode: type == 'month'
        ? DatePickerMode.year
        : DatePickerMode.day,
  );
  if (date == null) return _cancelled;
  switch (type) {
    case 'month':
      return _accepted('${_pad(date.year, 4)}-${_pad(date.month)}');
    case 'week':
      return _accepted(isoWeek(date));
    case 'datetime-local':
      if (!context.mounted) return _cancelled;
      final timePart = value.contains('T') ? value.split('T').last : '';
      final time = await _pickTime(context, timePart);
      if (time == null) return _cancelled;
      return _accepted('${_formatDate(date)}T${_formatTime(time)}');
    default:
      return _accepted(_formatDate(date));
  }
}

Future<TimeOfDay?> _pickTime(BuildContext context, String value) {
  final parts = value.split(':');
  final hour = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
  final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
  return showTimePicker(
    context: context,
    routeSettings: _promptRoute,
    initialTime: hour != null && minute != null
        ? TimeOfDay(hour: hour, minute: minute)
        : TimeOfDay.now(),
  );
}

Future<BrowserPromptAnswer> _color(BuildContext context, String value) async {
  var color = parseColorHex(value) ?? const Color(0xFF000000);
  final accepted =
      await ColorPicker(
        color: color,
        onColorChanged: (next) => color = next,
        pickersEnabled: const {
          ColorPickerType.wheel: true,
          ColorPickerType.both: true,
          ColorPickerType.primary: false,
          ColorPickerType.accent: false,
        },
        pickerTypeLabels: const {
          ColorPickerType.wheel: 'Any',
          ColorPickerType.both: 'Swatches',
        },
        enableShadesSelection: true,
        showColorCode: true,
        colorCodeHasColor: true,
      ).showPickerDialog(
        context,
        backgroundColor: Colors.black,
        routeSettings: _promptRoute,
        constraints: const BoxConstraints(maxWidth: 360),
      );
  return accepted ? _accepted(colorHex(color)) : _cancelled;
}

Future<BrowserPromptAnswer> _dialog(
  BuildContext context,
  Map<String, dynamic> prompt,
) async {
  final type = prompt['dialogType'] as String? ?? 'alert';
  final message = prompt['message'] as String? ?? '';
  final controller = TextEditingController(
    text: prompt['defaultText'] as String? ?? '',
  );
  final leaving = type == 'beforeunload';
  final answer = await showDialog<BrowserPromptAnswer>(
    context: context,
    routeSettings: _promptRoute,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Colors.black,
      title: leaving ? const Text('Leave this page?') : null,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.isNotEmpty) SelectableText(message),
          if (leaving && message.isEmpty)
            const Text('Changes you made may not be saved.'),
          if (type == 'prompt')
            TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (text) =>
                  Navigator.pop(dialogContext, _accepted(text)),
            ),
        ],
      ),
      actions: [
        if (type != 'alert')
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, _cancelled),
            child: Text(leaving ? 'Stay' : 'Cancel'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            _accepted(type == 'prompt' ? controller.text : null),
          ),
          child: Text(leaving ? 'Leave' : 'OK'),
        ),
      ],
    ),
  );
  controller.dispose();
  return answer ?? _cancelled;
}

Future<BrowserPromptAnswer> _auth(
  BuildContext context,
  Map<String, dynamic> prompt,
) async {
  final origin = prompt['origin'] as String? ?? '';
  final realm = prompt['realm'] as String?;
  final proxy = prompt['proxy'] == true;
  final username = TextEditingController();
  final password = TextEditingController();
  var obscure = true;
  final answer = await showDialog<BrowserPromptAnswer>(
    context: context,
    routeSettings: _promptRoute,
    barrierDismissible: false,
    builder: (dialogContext) {
      void submit() => Navigator.pop(dialogContext, (
        accept: true,
        value: null,
        username: username.text,
        password: password.text,
      ));
      return StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.black,
          title: Text(proxy ? 'Proxy sign-in' : 'Sign in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(origin),
              if (realm != null) Text(realm),
              TextField(
                controller: username,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: password,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    onPressed: () => setDialogState(() => obscure = !obscure),
                    icon: Icon(
                      obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
                onSubmitted: (_) => submit(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, _cancelled),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: submit, child: const Text('Sign in')),
          ],
        ),
      );
    },
  );
  username.dispose();
  password.dispose();
  return answer ?? _cancelled;
}

DateTime? _parseDate(String? value) {
  if (value == null || value.isEmpty) return null;
  final week = RegExp(r'^(\d{4})-W(\d{2})$').firstMatch(value);
  if (week != null) {
    // ISO week 1 holds January 4, and weeks start on Monday. The day count
    // goes through the constructor, since adding 24 hour Durations across a
    // daylight saving change lands at 23:00 the day before.
    final year = int.parse(week[1]!);
    final jan4 = DateTime(year, 1, 4);
    return DateTime(
      year,
      1,
      4 - (jan4.weekday - 1) + (int.parse(week[2]!) - 1) * 7,
    );
  }
  final month = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(value);
  if (month != null) {
    return DateTime(int.parse(month[1]!), int.parse(month[2]!));
  }
  return DateTime.tryParse(value.split('T').first);
}

/// The ISO week holding [date], as a week input wants it: 2026-W41.
String isoWeek(DateTime date) {
  // UTC, so a daylight saving change cannot shorten a day and shift the count.
  final day = DateTime.utc(date.year, date.month, date.day);
  final thursday = day.add(Duration(days: 4 - day.weekday));
  final week =
      (thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7) + 1;
  return '${_pad(thursday.year, 4)}-W${_pad(week)}';
}

/// A color input's #rrggbb value as a color, or null if it is not one.
Color? parseColorHex(String value) {
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value);
  return match == null
      ? null
      : Color(0xFF000000 | int.parse(match[1]!, radix: 16));
}

/// [color] as a color input wants it: #rrggbb.
String colorHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String _formatDate(DateTime date) =>
    '${_pad(date.year, 4)}-${_pad(date.month)}-${_pad(date.day)}';

String _formatTime(TimeOfDay time) => '${_pad(time.hour)}:${_pad(time.minute)}';

String _pad(int value, [int width = 2]) => value.toString().padLeft(width, '0');
