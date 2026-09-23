import 'dart:convert';

class ChatImageSource {
  const ChatImageSource._({required this.source, required this.label});
  final String source;
  final String label;

  static ChatImageSource parse(String source, {String label = ''}) {
    final uri = Uri.tryParse(source.trim());
    final id = uri?.queryParameters['id'] ?? '';
    if (uri?.scheme != 'socketagent' ||
        uri?.host != 'image' ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(id)) {
      throw const FormatException('Image snapshot is not available yet.');
    }
    return ChatImageSource._(source: uri.toString(), label: label.trim());
  }

  String get fileName =>
      Uri.parse(source).queryParameters['name'] ?? 'image.png';
}

class ChatImageComparison {
  const ChatImageComparison({required this.title, required this.images});
  final String title;
  final List<ChatImageSource> images;

  factory ChatImageComparison.parse(String json) {
    final value = jsonDecode(json);
    final items = value is List
        ? value
        : value is Map
        ? value['images']
        : null;
    if (items is! List || items.isEmpty || items.length > 12) {
      throw const FormatException('Compare needs an array of 1–12 images.');
    }
    final images = <ChatImageSource>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final source = item is String
          ? item
          : item is Map
          ? item['src']
          : null;
      final label = item is Map ? item['label'] : null;
      if (source is! String || (label != null && label is! String)) {
        throw const FormatException(
          'Each image needs a src string and an optional label.',
        );
      }
      images.add(
        ChatImageSource.parse(
          source,
          label: label is String && label.isNotEmpty ? label : 'Image ${i + 1}',
        ),
      );
    }
    final title = value is Map ? value['title'] : null;
    return ChatImageComparison(
      title: title is String ? title : 'Compare',
      images: List.unmodifiable(images),
    );
  }
}
