import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import '../models/inline_chat_media.dart';
import '../services/chat_image_loader.dart';
import '../services/chat_provider.dart';

typedef ChatImageFetch =
    Future<Uint8List> Function(ChatImageSource image, String? serverId);
typedef ChatImageSave =
    Future<bool> Function(ChatImageSource image, Uint8List bytes);

Widget buildChatMarkdownImage(
  Uri uri,
  String? title,
  String? alt,
  String? serverId,
) {
  try {
    final source = uri.scheme.isEmpty
        ? Uri.decodeFull(uri.toString())
        : uri.toString();
    return InlineChatImages(
      images: [ChatImageSource.parse(source, label: alt ?? '')],
      title: alt ?? title ?? '',
      sourceServerId: serverId,
    );
  } catch (_) {
    return const Text('Image snapshot pending or unavailable.');
  }
}

class ChatCompareSyntax extends md.FencedCodeBlockSyntax {
  const ChatCompareSyntax();
  @override
  md.Node parse(md.BlockParser parser) {
    final element = super.parse(parser) as md.Element;
    final code = element.children?.whereType<md.Element>().firstOrNull;
    return code?.attributes['class'] == 'language-socketagent-compare'
        ? md.Element('socketagent-compare', [md.Text(code!.textContent)])
        : element;
  }
}

class ChatCompareBuilder extends MarkdownElementBuilder {
  ChatCompareBuilder(this.serverId);
  final String? serverId;
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    try {
      final comparison = ChatImageComparison.parse(element.textContent);
      return InlineChatImages(
        title: comparison.title,
        images: comparison.images,
        sourceServerId: serverId,
      );
    } catch (_) {
      // The closing fence/JSON may not have arrived yet while the agent streams.
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Image comparison is loading or unavailable.'),
      );
    }
  }
}

class InlineChatImages extends StatefulWidget {
  const InlineChatImages({
    super.key,
    required this.images,
    this.title = '',
    required this.sourceServerId,
    this.loadImage,
    this.saveImage,
    this.fullscreen = false,
    this.initialIndex = 0,
  });
  final List<ChatImageSource> images;
  final String title;
  final String? sourceServerId;
  final ChatImageFetch? loadImage;
  final ChatImageSave? saveImage;
  final bool fullscreen;
  final int initialIndex;
  @override
  State<InlineChatImages> createState() => _InlineChatImagesState();
}

class _InlineChatImagesState extends State<InlineChatImages> {
  final _loads = <String, Future<Uint8List>>{};
  final _transform = TransformationController();
  late int _index;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  @override
  void didUpdateWidget(covariant InlineChatImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceServerId != widget.sourceServerId) _loads.clear();
    if (_index >= widget.images.length) _index = 0;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  ChatImageSource get _current => widget.images[_index];
  Future<Uint8List> _load(ChatImageSource image) {
    if (!_loads.containsKey(image.source) && _loads.length >= 3) {
      _loads.remove(_loads.keys.first);
    }
    return _loads.putIfAbsent(image.source, () {
      if (widget.loadImage != null) {
        return widget.loadImage!(image, widget.sourceServerId);
      }
      if (widget.sourceServerId == null) {
        return Future.error(StateError('The image’s computer is unavailable.'));
      }
      return ChatImageLoader.shared.load(
        image,
        widget.sourceServerId,
        context.read<ChatProvider>(),
      );
    });
  }

  void _select(int index) {
    if (index != _index) setState(() => _index = index);
  }

  Future<void> _save() async {
    final selected = _current;
    setState(() => _saving = true);
    try {
      final bytes = await _load(selected);
      final saved = await (widget.saveImage ?? ChatImageLoader.save)(
        selected,
        bytes,
      );
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Image saved')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save image. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _open() async {
    // The viewer keeps the original computer even if the underlying session
    // changes while it is open. Reuse previews already fetched by this card.
    final owner = widget.sourceServerId;
    final customLoad = widget.loadImage;
    final provider = customLoad == null && owner != null
        ? context.read<ChatProvider>()
        : null;
    final loaded = Map<String, Future<Uint8List>>.of(_loads);
    Future<Uint8List> loadForViewer(ChatImageSource image, String? server) {
      if (!loaded.containsKey(image.source) && loaded.length >= 3) {
        loaded.remove(loaded.keys.first);
      }
      return loaded.putIfAbsent(
        image.source,
        () => customLoad != null
            ? customLoad(image, owner)
            : ChatImageLoader.shared.load(image, owner, provider),
      );
    }

    final selected = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => InlineChatImages(
          images: widget.images,
          title: widget.title,
          sourceServerId: widget.sourceServerId,
          fullscreen: true,
          initialIndex: _index,
          loadImage: loadForViewer,
          saveImage: widget.saveImage,
        ),
      ),
    );
    if (mounted && selected != null) _select(selected);
  }

  Widget _selectors() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      children: [
        for (var i = 0; i < widget.images.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(
                widget.images[i].label.isEmpty
                    ? 'Image ${i + 1}'
                    : widget.images[i].label,
              ),
              selected: i == _index,
              onSelected: (_) => _select(i),
            ),
          ),
      ],
    ),
  );

  Widget _image() => FutureBuilder<Uint8List>(
    future: _load(_current),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      if (snapshot.hasError || snapshot.data == null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined),
              const Text('Image unavailable'),
              TextButton(
                onPressed: () => setState(() {
                  _loads.remove(_current.source);
                }),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      }
      return Image.memory(
        snapshot.data!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: widget.fullscreen ? null : 1200,
        gaplessPlayback: false,
        semanticLabel: _current.label,
        errorBuilder: (_, _, _) =>
            const Center(child: Text('Unsupported or invalid image')),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final compare = widget.images.length > 1;
    final name = widget.title.isNotEmpty
        ? widget.title
        : compare
        ? 'Compare'
        : _current.fileName;
    if (widget.fullscreen) {
      return Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent || !compare) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _select((_index + 1) % widget.images.length);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _select((_index - 1 + widget.images.length) % widget.images.length);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: BackButton(
              onPressed: () => Navigator.pop(context, _index),
            ),
            actions: [
              IconButton(
                tooltip: 'Reset zoom',
                onPressed: () => _transform.value = Matrix4.identity(),
                icon: const Icon(Icons.fit_screen),
              ),
              IconButton(
                tooltip: 'Download image',
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.download),
              ),
            ],
          ),
          body: Column(
            children: [
              if (compare) _selectors(),
              Expanded(
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 8,
                  child: _image(),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 110;
        return SizedBox(
          width: width.clamp(120, 900),
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (compare || widget.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                if (compare) _selectors(),
                SizedBox(
                  height: 240,
                  child: Semantics(
                    button: true,
                    label: 'Open image full screen',
                    child: InkWell(onTap: _open, child: _image()),
                  ),
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: _open,
                      icon: const Icon(Icons.fullscreen, size: 18),
                      label: const Text('Full screen'),
                    ),
                    IconButton(
                      tooltip: 'Download image',
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.download, size: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
