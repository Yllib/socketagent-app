import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/chat_provider.dart';
import '../../services/kokoro_model_manager.dart';
import '../../services/moonshine_speech_service.dart';
import '../../services/tts_engine.dart';
import '../../widgets/speech_recognition_controls.dart';

class VoiceSpeechScreen extends StatelessWidget {
  const VoiceSpeechScreen({super.key});

  Future<void> _saveReport(BuildContext context) async {
    try {
      await MoonshineSpeechService.channel.invokeMethod<String>(
        'saveCrashReport',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Diagnostic report saved to Downloads.'),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the report. Please try again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Voice & Speech'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (Platform.isAndroid)
            PopupMenuButton<String>(
              tooltip: 'More options',
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'report',
                  child: Text('Save diagnostic report'),
                ),
              ],
              onSelected: (_) => _saveReport(context),
            ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Dictation'),
            Tab(text: 'Read aloud'),
          ],
        ),
      ),
      body: Consumer<ChatProvider>(
        builder: (context, provider, _) => TabBarView(
          children: [
            ListView(
              key: const PageStorageKey('dictation-settings'),
              padding: const EdgeInsets.all(20),
              children: [SpeechRecognitionControls(provider: provider)],
            ),
            _ReadAloudSettings(provider: provider),
          ],
        ),
      ),
    ),
  );
}

class _Choice<T> {
  const _Choice(this.value, this.title, this.detail);
  final T value;
  final String title;
  final String detail;
}

Future<T?> _choose<T>(
  BuildContext context, {
  required String title,
  required List<_Choice<T>> choices,
  required T? selected,
  bool searchable = false,
}) {
  var query = '';
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.black,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final filtered = choices
            .where(
              (c) => '${c.title} ${c.detail}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
            )
            .toList();
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (searchable)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search voices',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) => setState(() => query = value),
                    ),
                  ),
                Flexible(
                  child: filtered.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            query.isEmpty
                                ? 'No voices available.'
                                : 'No matching voices.',
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, index) {
                            final choice = filtered[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(choice.title),
                              subtitle: choice.detail.isEmpty
                                  ? null
                                  : Text(choice.detail),
                              trailing: choice.value == selected
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () => Navigator.pop(context, choice.value),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

String _sourceName(TtsEngineMode mode) => switch (mode) {
  TtsEngineMode.system => 'Device voices',
  TtsEngineMode.kokoroDevice => 'Kokoro · This device',
  TtsEngineMode.kokoroServer => 'Kokoro · Computer',
  TtsEngineMode.elevenLabs => 'ElevenLabs',
};

class _ReadAloudSettings extends StatefulWidget {
  const _ReadAloudSettings({required this.provider});
  final ChatProvider provider;
  @override
  State<_ReadAloudSettings> createState() => _ReadAloudSettingsState();
}

class _ReadAloudSettingsState extends State<_ReadAloudSettings> {
  bool _busy = false;
  bool _previewing = false;
  ChatProvider get provider => widget.provider;

  @override
  void dispose() {
    if (_previewing) {
      final currentProvider = provider;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(currentProvider.stopElevenLabsVoicePreview());
      });
    }
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() operation, {
    String failure = 'Could not update the voice settings. Please try again.',
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeSource() async {
    final mode = await _choose(
      context,
      title: 'Read-aloud voice source',
      selected: provider.ttsEngineMode,
      choices: const [
        _Choice(
          TtsEngineMode.system,
          'Device voices',
          'Use your device’s built-in voices.',
        ),
        _Choice(
          TtsEngineMode.kokoroDevice,
          'Kokoro · This device',
          'Download voices to read aloud offline.',
        ),
        _Choice(
          TtsEngineMode.kokoroServer,
          'Kokoro · Computer',
          'Your connected computer creates the speech.',
        ),
        _Choice(
          TtsEngineMode.elevenLabs,
          'ElevenLabs',
          'Online voices with your ElevenLabs account.',
        ),
      ],
    );
    if (mode == null || !mounted) return;
    if (mode == TtsEngineMode.elevenLabs && !provider.hasElevenLabsApiKey) {
      await _account();
    } else {
      await _run(
        () => mode == TtsEngineMode.elevenLabs
            ? provider.setElevenLabsEnabled(true)
            : provider.setTtsEngineMode(mode),
      );
    }
  }

  Future<void> _account() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ElevenLabsAccount(provider: provider),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _chooseVoice() async {
    if (provider.ttsEngineMode == TtsEngineMode.elevenLabs &&
        provider.elevenLabsVoices.isEmpty) {
      await _run(
        provider.refreshElevenLabsVoices,
        failure:
            'Could not load your voices. Check your connection and try again.',
      );
    }
    if (!mounted) return;
    final voices = provider.ttsEngineVoices;
    final voice = await _choose(
      context,
      title: 'Choose a voice',
      searchable: true,
      selected: provider.selectedTtsEngineVoice,
      choices: voices.map((v) => _Choice(v, v.name, v.locale ?? '')).toList(),
    );
    if (voice == null || !mounted) return;
    await _run(() async {
      switch (provider.ttsEngineMode) {
        case TtsEngineMode.system:
          final systemVoice = provider.ttsVoices
              .where((v) => v.name == voice.id)
              .firstOrNull;
          if (systemVoice != null) await provider.setTtsVoice(systemVoice);
        case TtsEngineMode.elevenLabs:
          await provider.setElevenLabsVoice(voice);
        case TtsEngineMode.kokoroDevice:
        case TtsEngineMode.kokoroServer:
          await provider.setKokoroVoice(voice);
      }
    });
  }

  Future<void> _preview() async {
    if (_previewing) return;
    setState(() => _previewing = true);
    try {
      final voice = provider.selectedTtsEngineVoice;
      switch (provider.ttsEngineMode) {
        case TtsEngineMode.system:
          final systemVoice = provider.selectedTtsVoice;
          if (systemVoice != null) await provider.previewTtsVoice(systemVoice);
        case TtsEngineMode.elevenLabs:
          if (voice != null) await provider.previewElevenLabsVoice(voice);
        case TtsEngineMode.kokoroDevice:
        case TtsEngineMode.kokoroServer:
          if (voice != null) await provider.previewKokoroVoice(voice);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not play this voice. Check that it is ready and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = provider.ttsEngineMode;
    final voice = provider.selectedTtsEngineVoice;
    return ListView(
      key: const PageStorageKey('read-aloud-settings'),
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Choose how replies sound.',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Read replies automatically'),
          value: provider.ttsEnabled,
          onChanged: provider.setTtsEnabled,
        ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.volume_up_outlined),
          title: const Text('Voice source'),
          subtitle: Text(_sourceName(mode)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _changeSource,
        ),
        if (mode == TtsEngineMode.kokoroDevice)
          _KokoroDownloads(provider: provider),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Voice'),
          subtitle: Text(voice?.name ?? 'Choose a voice'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _chooseVoice,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy || _previewing || voice == null ? null : _preview,
            icon: const Icon(Icons.play_arrow),
            label: Text(_previewing ? 'Playing preview…' : 'Preview voice'),
          ),
        ),
        if (mode == TtsEngineMode.elevenLabs) ...[
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Speaking style'),
            subtitle: Text(provider.elevenLabsModel.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy
                ? null
                : () async {
                    final model = await _choose(
                      context,
                      title: 'Speaking style',
                      selected: provider.elevenLabsModel,
                      choices: const [
                        _Choice(
                          ElevenLabsModel.flashV25,
                          'Flash v2.5',
                          'Quick, natural speech',
                        ),
                        _Choice(
                          ElevenLabsModel.v3,
                          'Eleven v3',
                          'More expressive speech',
                        ),
                      ],
                    );
                    if (model != null && mounted) {
                      await _run(() => provider.setElevenLabsModel(model));
                    }
                  },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Text('Speaking speed')),
              Text('${provider.elevenLabsSpeechRate.toStringAsFixed(2)}×'),
            ],
          ),
          Slider(
            value: provider.elevenLabsSpeechRate,
            min: 0.7,
            max: 1.2,
            divisions: 10,
            label: '${provider.elevenLabsSpeechRate.toStringAsFixed(2)}×',
            onChanged: _busy
                ? null
                : (value) => provider.setElevenLabsSpeechRate(value),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('ElevenLabs account'),
            subtitle: const Text('Connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _account,
          ),
          TextButton.icon(
            onPressed: _busy || provider.elevenLabsVoicesLoading
                ? null
                : () => _run(provider.refreshElevenLabsVoices),
            icon: const Icon(Icons.refresh),
            label: Text(
              provider.elevenLabsVoicesLoading
                  ? 'Refreshing voices…'
                  : 'Refresh voices',
            ),
          ),
          if (provider.elevenLabsVoicesError != null)
            const Text(
              'Voices could not be refreshed. Check your connection and try again.',
            ),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Updating…'),
          ),
      ],
    );
  }
}

class _KokoroDownloads extends StatefulWidget {
  const _KokoroDownloads({required this.provider});
  final ChatProvider provider;
  @override
  State<_KokoroDownloads> createState() => _KokoroDownloadsState();
}

class _KokoroDownloadsState extends State<_KokoroDownloads> {
  final Set<KokoroModel> _installed = {};
  KokoroModel _active = KokoroModel.v019;
  bool _busy = false;
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final manager = widget.provider.kokoroModelManager;
    final installed = <KokoroModel>{};
    for (final model in KokoroModel.values) {
      if (await manager.isModelVersionInstalled(model)) installed.add(model);
    }
    final active = await manager.activeModel;
    if (mounted) {
      setState(() {
        _installed
          ..clear()
          ..addAll(installed);
        _active = active;
        _ready = true;
      });
    }
  }

  Future<void> _change(KokoroModel model, {bool remove = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (remove) {
        await widget.provider.deleteKokoroModelVersion(model);
      } else {
        await widget.provider.setKokoroModel(model);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not update the download. Connect to your computer and try again.',
            ),
          ),
        );
      }
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double?>(
    valueListenable: widget.provider.kokoroModelManager.downloadProgress,
    builder: (_, progress, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text(
          'Voice downloads',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        for (final model in KokoroModel.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _active == model && _installed.contains(model)
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: Text(model == KokoroModel.v019 ? 'English' : 'Multilingual'),
            subtitle: Text(
              _installed.contains(model)
                  ? 'Downloaded'
                  : 'Download from your computer',
            ),
            trailing: !_installed.contains(model)
                ? const Icon(Icons.download_outlined)
                : _active == model
                ? null
                : IconButton(
                    tooltip: 'Remove download',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy || progress != null
                        ? null
                        : () => _change(model, remove: true),
                  ),
            onTap: !_ready || _busy || progress != null
                ? null
                : () => _change(model),
          ),
        if (progress != null) ...[
          Text('Downloading · ${(progress * 100).round()}%'),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
        ],
      ],
    ),
  );
}

class _ElevenLabsAccount extends StatefulWidget {
  const _ElevenLabsAccount({required this.provider});
  final ChatProvider provider;
  @override
  State<_ElevenLabsAccount> createState() => _ElevenLabsAccountState();
}

class _ElevenLabsAccountState extends State<_ElevenLabsAccount> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy || _key.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.provider.setElevenLabsApiKey(_key.text.trim());
      await widget.provider.setElevenLabsEnabled(true);
      _key.clear();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not connect. Check your access key and internet connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect ElevenLabs?'),
        content: const Text(
          'Your saved access key will be removed. Read aloud will use your device’s voices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep connected'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.provider.deleteElevenLabsApiKey();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not disconnect. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: const Text('ElevenLabs account'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          widget.provider.hasElevenLabsApiKey
              ? 'Your account is connected.'
              : 'Connect your ElevenLabs account.',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          'Use an API key from your ElevenLabs account. Read-aloud text is sent to ElevenLabs, and your account’s usage limits apply.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _key,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _connect(),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: widget.provider.hasElevenLabsApiKey
                ? 'New access key'
                : 'Access key',
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _key.text.trim().isEmpty ? null : _connect,
          child: Text(
            _busy
                ? 'Connecting…'
                : widget.provider.hasElevenLabsApiKey
                ? 'Update connection'
                : 'Connect',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!),
          ),
        if (widget.provider.hasElevenLabsApiKey)
          TextButton(
            onPressed: _busy ? null : _disconnect,
            child: const Text('Disconnect'),
          ),
      ],
    ),
  );
}
