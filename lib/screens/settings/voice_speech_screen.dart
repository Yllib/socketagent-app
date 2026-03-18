import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/chat_provider.dart';
import '../../services/tts_engine.dart';
import '../../services/kokoro_server_engine.dart';
import '../../services/kokoro_model_manager.dart';
import '../../services/kokoro_device_engine.dart';

class VoiceSpeechScreen extends StatelessWidget {
  const VoiceSpeechScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice & Speech'),
      ),
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
                subtitle: const Text('Hold mic button to record, release to stop'),
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
              value: provider.ttsEngineMode,
              decoration: const InputDecoration(
                labelText: 'TTS Engine',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
              items: const [
                DropdownMenuItem(
                  value: TtsEngineMode.system,
                  child: Text('System TTS'),
                ),
                DropdownMenuItem(
                  value: TtsEngineMode.kokoroServer,
                  child: Text('Kokoro (Server)'),
                ),
                DropdownMenuItem(
                  value: TtsEngineMode.kokoroDevice,
                  child: Text('Kokoro (On-Device)'),
                ),
              ],
              onChanged: (mode) {
                if (mode != null) provider.setTtsEngineMode(mode);
              },
            ),
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
            provider.kokoroModelManager.isModelVersionInstalled(KokoroModel.v019),
            provider.kokoroModelManager.isModelVersionInstalled(KokoroModel.v10),
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
                const Text('Model', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                for (final model in KokoroModel.values)
                  _KokoroModelTile(
                    model: model,
                    isInstalled: model == KokoroModel.v019 ? v019Installed : v10Installed,
                    isActive: active == model && (model == KokoroModel.v019 ? v019Installed : v10Installed),
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
            onLongPress: () => provider.previewKokoroVoice(voice),
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
                          Icon(Icons.check_circle, size: 18, color: Colors.green.shade400),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('ASR model installed', style: TextStyle(fontSize: 13)),
                          ),
                          TextButton(
                            onPressed: () async {
                              await provider.asrModelManager.deleteModel();
                            },
                            child: const Text('Delete', style: TextStyle(fontSize: 12)),
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
                ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5)
                : Border.all(color: Colors.grey.shade700, width: 0.5),
            color: isActive ? Theme.of(context).colorScheme.primary.withOpacity(0.08) : null,
          ),
          child: Row(
            children: [
              if (isActive)
                Icon(Icons.check_circle, size: 18, color: Colors.green.shade400)
              else if (isInstalled)
                Icon(Icons.circle_outlined, size: 18, color: Colors.grey.shade500)
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
                const Text('Tap to download', style: TextStyle(fontSize: 11, color: Colors.grey))
              else if (!isActive)
                const Text('Tap to activate', style: TextStyle(fontSize: 11, color: Colors.grey)),
              if (isInstalled && !isActive) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onDelete,
                  child: Icon(Icons.delete_outline, size: 16, color: Colors.grey.shade500),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
