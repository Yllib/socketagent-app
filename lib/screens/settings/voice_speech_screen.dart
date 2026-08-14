import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/chat_provider.dart';
import '../../services/tts_engine.dart';
import '../../services/kokoro_server_engine.dart';
import '../../services/kokoro_model_manager.dart';

class VoiceSpeechScreen extends StatelessWidget {
  const VoiceSpeechScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice & Speech')),
      body: Consumer<ChatProvider>(
        builder: (context, provider, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _sectionHeader(context, 'Text-to-Speech'),
              const SizedBox(height: 8),
              _buildTtsSection(context, provider),
              const SizedBox(height: 24),
              _sectionHeader(context, 'Speech Recognition'),
              const SizedBox(height: 8),
              _buildAsrSection(context, provider),
              SwitchListTile(
                title: const Text('Push to talk'),
                subtitle: const Text(
                  'Hold mic button to record, release to stop',
                ),
                value: provider.pushToTalk,
                onChanged: (v) => provider.pushToTalk = v,
              ),
              const SizedBox(height: 24),
              _sectionHeader(context, 'Voice Input'),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Auto-start voice on AI button'),
                subtitle: const Text(
                  'When launched via Samsung AI button, automatically start listening',
                ),
                value: provider.autoVoiceOnAssist,
                onChanged: (val) => provider.setAutoVoiceOnAssist(val),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildTtsSection(BuildContext context, ChatProvider provider) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<TtsEngineMode>(
              initialValue: provider.ttsEngineMode,
              decoration: const InputDecoration(
                labelText: 'TTS Engine',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: TtsEngineMode.system,
                  child: Text('System TTS'),
                ),
                DropdownMenuItem(
                  value: TtsEngineMode.kokoroServer,
                  child: Text('Kokoro (Computer)'),
                ),
                DropdownMenuItem(
                  value: TtsEngineMode.kokoroDevice,
                  child: Text('Kokoro (On-Device)'),
                ),
                DropdownMenuItem(
                  value: TtsEngineMode.elevenLabs,
                  child: Text('ElevenLabs'),
                ),
              ],
              onChanged: (mode) async {
                if (mode == null) return;
                try {
                  await provider.setTtsEngineMode(mode);
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$error')),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 12),
            _ElevenLabsSettings(provider: provider),
            if (provider.ttsEngineMode == TtsEngineMode.kokoroDevice) ...[
              const SizedBox(height: 12),
              _buildKokoroModelSection(context, provider),
            ],
            if (provider.ttsEngineMode == TtsEngineMode.kokoroServer ||
                provider.ttsEngineMode == TtsEngineMode.kokoroDevice) ...[
              const SizedBox(height: 12),
              _buildKokoroVoiceList(context, provider),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildKokoroModelSection(BuildContext context, ChatProvider provider) {
    return ValueListenableBuilder<double?>(
      valueListenable: provider.kokoroModelManager.downloadProgress,
      builder: (context, progress, _) {
        if (progress != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: progress),
            ],
          );
        }
        return FutureBuilder<List<dynamic>>(
          future: Future.wait([
            provider.kokoroModelManager.isModelVersionInstalled(
              KokoroModel.v019,
            ),
            provider.kokoroModelManager.isModelVersionInstalled(
              KokoroModel.v10,
            ),
            provider.kokoroModelManager.activeModel,
          ]),
          builder: (context, snapshot) {
            final data = snapshot.data;
            final v019Installed = data?[0] as bool? ?? false;
            final v10Installed = data?[1] as bool? ?? false;
            final active = data?[2] as KokoroModel? ?? KokoroModel.v019;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Model',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                for (final model in KokoroModel.values)
                  _KokoroModelTile(
                    model: model,
                    isInstalled: model == KokoroModel.v019
                        ? v019Installed
                        : v10Installed,
                    isActive:
                        active == model &&
                        (model == KokoroModel.v019
                            ? v019Installed
                            : v10Installed),
                    onSelect: () => provider.setKokoroModel(model),
                    onDelete: () => provider.deleteKokoroModelVersion(model),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildKokoroVoiceList(BuildContext context, ChatProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Voice',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(180),
          ),
        ),
        const SizedBox(height: 8),
        ...kokoroVoices.map((voice) {
          final isSelected = provider.selectedTtsEngineVoice?.id == voice.id;
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface.withAlpha(100),
              size: 20,
            ),
            title: Text(
              voice.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            onTap: () => provider.setKokoroVoice(voice),
            onLongPress: () async {
              try {
                await provider.previewKokoroVoice(voice);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
          );
        }),
        const SizedBox(height: 4),
        Text(
          'Long-press a voice to preview it',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(100),
          ),
        ),
      ],
    );
  }

  Widget _buildAsrSection(BuildContext context, ChatProvider provider) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'On-device speech recognition using sherpa-onnx. '
              'Download the model to enable offline voice input.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<double?>(
              valueListenable: provider.asrModelManager.downloadProgress,
              builder: (context, progress, _) {
                return FutureBuilder<bool>(
                  future: provider.asrModelManager.isModelInstalled(),
                  builder: (context, snapshot) {
                    final installed = snapshot.data ?? false;
                    if (installed) {
                      return Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 18,
                            color: Colors.green.shade400,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'ASR model installed',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              await provider.asrModelManager.deleteModel();
                            },
                            child: const Text(
                              'Delete',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      );
                    }
                    if (progress != null) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Downloading model... ${(progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 13),
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: progress),
                        ],
                      );
                    }
                    return FilledButton.icon(
                      onPressed: () async {
                        try {
                          await provider.asrModelManager.downloadModel();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Download failed: $e')),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download Models (~187 MB)'),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ElevenLabsSettings extends StatefulWidget {
  const _ElevenLabsSettings({required this.provider});

  final ChatProvider provider;

  @override
  State<_ElevenLabsSettings> createState() => _ElevenLabsSettingsState();
}

class _ElevenLabsSettingsState extends State<_ElevenLabsSettings> {
  final TextEditingController _keyController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.provider.setElevenLabsApiKey(key);
      _keyController.clear();
      if (mounted) FocusScope.of(context).unfocus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ElevenLabs API key saved')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    try {
      await widget.provider.setElevenLabsEnabled(enabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('ElevenLabs'),
          value: provider.elevenLabsEnabled,
          onChanged: _setEnabled,
        ),
        if (provider.hasElevenLabsApiKey)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 18),
                SizedBox(width: 8),
                Text('API key saved'),
              ],
            ),
          ),
        TextField(
          controller: _keyController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _saveKey(),
          decoration: InputDecoration(
            labelText: 'API key',
            hintText: provider.hasElevenLabsApiKey
                ? 'Enter a new key to replace it'
                : 'Enter API key',
            border: const OutlineInputBorder(),
            suffixIcon: _saving
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Save API key',
                    onPressed: _saveKey,
                    icon: const Icon(Icons.save_outlined),
                  ),
          ),
        ),
        if (provider.hasElevenLabsApiKey)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: provider.deleteElevenLabsApiKey,
              child: const Text('Remove'),
            ),
          )
        else
          const SizedBox(height: 12),
        SegmentedButton<ElevenLabsModel>(
          segments: ElevenLabsModel.values
              .map(
                (model) => ButtonSegment<ElevenLabsModel>(
                  value: model,
                  label: Text(model.label),
                ),
              )
              .toList(),
          selected: {provider.elevenLabsModel},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            provider.setElevenLabsModel(selection.first);
          },
        ),
        if (provider.hasElevenLabsApiKey) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Voice',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              if (provider.elevenLabsVoicesLoading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Refresh voices',
                  onPressed: () async {
                    try {
                      await provider.refreshElevenLabsVoices();
                    } catch (_) {}
                  },
                  icon: const Icon(Icons.refresh, size: 20),
                ),
            ],
          ),
          DropdownButtonFormField<TtsEngineVoice>(
            key: ValueKey(
              '${provider.selectedElevenLabsVoice?.id}:'
              '${provider.elevenLabsVoices.length}',
            ),
            initialValue: provider.selectedElevenLabsVoice,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            items: provider.elevenLabsVoices
                .map(
                  (voice) => DropdownMenuItem<TtsEngineVoice>(
                    value: voice,
                    child: Text(
                      voice.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (voice) {
              if (voice != null) provider.setElevenLabsVoice(voice);
            },
          ),
          if (provider.elevenLabsVoicesError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                provider.elevenLabsVoicesError!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _KokoroModelTile extends StatelessWidget {
  final KokoroModel model;
  final bool isInstalled;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  const _KokoroModelTile({
    required this.model,
    required this.isInstalled,
    required this.isActive,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onSelect,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: isActive
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 1.5,
                  )
                : Border.all(color: Colors.grey.shade700, width: 0.5),
            color: isActive
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                : null,
          ),
          child: Row(
            children: [
              if (isActive)
                Icon(Icons.check_circle, size: 18, color: Colors.green.shade400)
              else if (isInstalled)
                Icon(
                  Icons.circle_outlined,
                  size: 18,
                  color: Colors.grey.shade500,
                )
              else
                const Icon(Icons.download, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  model.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (!isInstalled)
                const Text(
                  'Tap to download',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                )
              else if (!isActive)
                const Text(
                  'Tap to activate',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              if (isInstalled && !isActive) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onDelete,
                  child: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
