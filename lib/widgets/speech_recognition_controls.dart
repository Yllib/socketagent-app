import 'dart:io';
import 'package:flutter/material.dart';
import '../services/chat_provider.dart';
import '../services/moonshine_speech_service.dart';
import '../services/speech_recognition_settings.dart';

enum SpeechSettingsView { overview, models, tuning }

class SpeechRecognitionControls extends StatefulWidget {
  const SpeechRecognitionControls({
    super.key,
    required this.provider,
    this.view = SpeechSettingsView.overview,
  });
  final ChatProvider provider;
  final SpeechSettingsView view;
  @override
  State<SpeechRecognitionControls> createState() =>
      _SpeechRecognitionControlsState();
}

class _SpeechRecognitionControlsState extends State<SpeechRecognitionControls> {
  final Set<AsrModel> _installed = {};
  bool _busy = false;
  bool _ready = false;
  bool _moonshineAvailable = false;
  late SpeechRecognitionSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.provider.recognitionSettings;
    _refresh();
  }

  @override
  void didUpdateWidget(covariant SpeechRecognitionControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy) _settings = widget.provider.recognitionSettings;
  }

  Future<void> _refresh() async {
    final installed = <AsrModel>{};
    for (final model in AsrModel.values) {
      if (await widget.provider.asrModelManager.isModelInstalled(model)) {
        installed.add(model);
      }
    }
    var supported = false;
    if (Platform.isAndroid) {
      try {
        supported =
            await MoonshineSpeechService.channel.invokeMethod<bool>(
              'available',
            ) ??
            false;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _installed
        ..clear()
        ..addAll(installed);
      _moonshineAvailable = supported;
      _ready = true;
    });
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update dictation. Please try again.'),
          ),
        );
      }
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _settings = widget.provider.recognitionSettings;
          _busy = false;
        });
      }
    }
  }

  Future<void> _open(SpeechSettingsView view, String title) async {
    final provider = widget.provider;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(title),
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: AnimatedBuilder(
            animation: provider,
            builder: (_, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SpeechRecognitionControls(provider: provider, view: view),
              ],
            ),
          ),
        ),
      ),
    );
    await _refresh();
    if (mounted) setState(() => _settings = provider.recognitionSettings);
  }

  Future<void> _save(SpeechRecognitionSettings settings) =>
      _perform(() => widget.provider.setRecognitionSettings(settings));

  Future<void> _remove(AsrModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${model.label}?'),
        content: const Text('You can download it again whenever you need it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      if (_settings.model == model) {
        await widget.provider.setRecognitionSettings(_settings);
      }
      await widget.provider.asrModelManager.deleteModel(model);
    });
  }

  Widget _slider({
    required String title,
    required String detail,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required SpeechRecognitionSettings Function(double) update,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title)),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: _disabled
              ? null
              : (v) => setState(() => _settings = update(v)),
          onChangeEnd: _disabled ? null : (v) => _save(update(v)),
        ),
        Text(detail, style: const TextStyle(fontSize: 13)),
      ],
    ),
  );

  bool get _disabled => _busy || widget.provider.speech.busy;

  Widget _progress() => ValueListenableBuilder<double?>(
    valueListenable: widget.provider.asrModelManager.downloadProgress,
    builder: (_, progress, _) => progress == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Downloading ${widget.provider.asrModelManager.downloadingModel?.label ?? 'model'} · ${(progress * 100).round()}%',
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress),
              ],
            ),
          ),
  );

  @override
  Widget build(BuildContext context) => switch (widget.view) {
    SpeechSettingsView.overview => _overview(),
    SpeechSettingsView.models => _models(),
    SpeechSettingsView.tuning => _tuning(),
  };

  Widget _overview() {
    final provider = widget.provider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Turn your speech into a message.',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('Dictation stays on this device.'),
        const SizedBox(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.mic_none),
          title: const Text('Recognition model'),
          subtitle: Text(
            '${_settings.model.label}${_ready && !_installed.contains(_settings.model) ? ' · Download needed' : ''}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(SpeechSettingsView.models, 'Recognition model'),
        ),
        _progress(),
        const Divider(height: 32),
        const Text(
          'Microphone button',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Tap to talk')),
              ButtonSegment(value: true, label: Text('Hold to talk')),
            ],
            selected: {provider.pushToTalk},
            showSelectedIcon: false,
            onSelectionChanged: _disabled
                ? null
                : (values) {
                    provider.pushToTalk = values.first;
                    setState(() {});
                  },
          ),
        ),
        const SizedBox(height: 10),
        Text(
          provider.pushToTalk
              ? 'Hold the microphone while speaking. Release to finish.'
              : 'Tap once to start. Pause to finish, or tap again to stop.',
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fine-tune dictation'),
          subtitle: const Text('Pauses, sensitivity and word updates'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(SpeechSettingsView.tuning, 'Fine-tune dictation'),
        ),
        if (Platform.isAndroid) ...[
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Listen on assistant shortcut'),
            subtitle: const Text(
              'Start dictation when your phone’s assistant shortcut opens SocketAgent.',
            ),
            value: provider.autoVoiceOnAssist,
            onChanged: (value) => provider.setAutoVoiceOnAssist(value),
          ),
        ],
      ],
    );
  }

  Widget _models() {
    final manager = widget.provider.asrModelManager;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choose a model for English dictation. Download once, then use it offline.',
        ),
        const SizedBox(height: 16),
        for (final model in AsrModel.values) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _settings.model == model
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: Text(model.label),
            subtitle: Text(
              model.isMoonshine && _ready && !_moonshineAvailable
                  ? 'Not available on this device'
                  : '${model.description}${_installed.contains(model) ? ' · Downloaded' : ''}',
            ),
            trailing: !_ready
                ? null
                : _installed.contains(model)
                ? PopupMenuButton<String>(
                    tooltip: 'Download options',
                    enabled: !_disabled && !manager.isDownloading,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove download'),
                      ),
                    ],
                    onSelected: (_) => _remove(model),
                  )
                : const Icon(Icons.download_outlined),
            enabled:
                _ready &&
                !_disabled &&
                !manager.isDownloading &&
                (!model.isMoonshine || _moonshineAvailable),
            onTap: () => _perform(() async {
              if (!_installed.contains(model)) {
                await manager.downloadModel(model);
              }
              await widget.provider.setRecognitionSettings(
                _settings.copyWith(model: model),
              );
            }),
          ),
          const Divider(height: 1),
        ],
        _progress(),
        if (_busy && !manager.isDownloading)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Updating selection…'),
          ),
      ],
    );
  }

  Widget _tuning() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _settings.model.label,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 24),
      if (!_settings.model.isMoonshine) ...[
        const Text('Recognition effort'),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('Fast')),
            ButtonSegment(value: 4, label: Text('Balanced')),
            ButtonSegment(value: 8, label: Text('Careful')),
          ],
          selected: {_settings.searchPaths},
          showSelectedIcon: false,
          onSelectionChanged: _disabled
              ? null
              : (v) => _save(_settings.copyWith(searchPaths: v.first)),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Choose how carefully to interpret your words.'),
        ),
        _slider(
          title: 'Pause between sentences',
          detail: 'How long a pause separates two sentences.',
          value: _settings.endpointSilence,
          min: 0.4,
          max: 2.4,
          divisions: 10,
          label: '${_settings.endpointSilence.toStringAsFixed(1)} s',
          update: (v) => _settings.copyWith(endpointSilence: v),
        ),
      ] else ...[
        _slider(
          title: 'Background noise filtering',
          detail: 'Raise this if background sounds are picked up as speech.',
          value: _settings.vadThreshold,
          min: 0.2,
          max: 0.8,
          divisions: 12,
          label: _settings.vadThreshold < 0.4
              ? 'Light'
              : _settings.vadThreshold > 0.6
              ? 'Strong'
              : 'Medium',
          update: (v) => _settings.copyWith(vadThreshold: v),
        ),
        _slider(
          title: 'Word updates',
          detail: 'How often new words appear while you speak.',
          value: _settings.updateInterval,
          min: 0.25,
          max: 1.5,
          divisions: 5,
          label: '${_settings.updateInterval.toStringAsFixed(2)} s',
          update: (v) => _settings.copyWith(updateInterval: v),
        ),
      ],
      if (!widget.provider.pushToTalk)
        _slider(
          title: 'Finish after a pause',
          detail: 'Stop listening after this much silence.',
          value: _settings.stopAfterSilence,
          min: 2,
          max: 12,
          divisions: 10,
          label: '${_settings.stopAfterSilence.round()} s',
          update: (v) => _settings.copyWith(stopAfterSilence: v),
        ),
      TextButton(
        onPressed: _disabled
            ? null
            : () => _save(SpeechRecognitionSettings(model: _settings.model)),
        child: const Text('Restore defaults'),
      ),
    ],
  );
}
