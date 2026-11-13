import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/model_store.dart';
import '../app/services.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;

  Future<void> _importModel() async {
    final store = AppScope.of(context).models;
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      var n = 0;
      for (final f in files) {
        final path = f.path;
        if (path == null) continue;
        final lower = f.name.toLowerCase();
        if (!lower.endsWith('.onnx') && !lower.endsWith('.json')) {
          messenger.showSnackBar(SnackBar(content: Text('${f.name} 不是 .onnx / .json 文件（.pth 需先用 tools/prepare_models.py 转换）')));
          continue;
        }
        await store.importFile(path);
        n++;
      }
      if (n > 0) messenger.showSnackBar(SnackBar(content: Text('已导入 $n 个文件')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final s = services.settings;
    final models = services.models.list();
    final theme = Theme.of(context);
    Future<void> set(void Function() change) async {
      await s.update((_) => change());
      setState(() {});
    }

    String sizeOf(ModelFile m) {
      try {
        return '${(m.sizeBytes / 1e6).toStringAsFixed(1)} MB';
      } catch (_) {
        return '';
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          ListTile(title: Text('分离模型', style: theme.textTheme.titleMedium)),
          for (final kind in ModelKind.values)
            ListTile(
              leading: Icon(services.models.pathFor(kind) != null ? Icons.check_circle : Icons.error_outline,
                  color: services.models.pathFor(kind) != null ? Colors.green : theme.colorScheme.error),
              title: Text('${kind.label}：${kind.recommended}'),
              subtitle: Text(services.models.pathFor(kind)?.split('/').last ?? '未导入'),
            ),
          for (final m in models)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 72, right: 8),
              title: Text(m.name),
              subtitle: Text('${m.kind.label} · ${sizeOf(m)}${m.hasSidecar ? ' · 含配置' : ''}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await services.models.delete(m);
                  setState(() {});
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _importModel,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.file_open_outlined),
              label: const Text('导入模型文件（.onnx 及同名 .json）'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'UVR-MDX-NET-Voc_FT.onnx 可直接导入；6_HP-Karaoke-UVR.pth 需要先在电脑上运行 '
              'tools/prepare_models.py 转成 .onnx + .json。也可以用“文件”App 或访达把它们拷到'
              '“YinTrace/models”文件夹。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          SwitchListTile(
            title: const Text('分离时尝试使用 Core ML 加速'),
            subtitle: const Text('不兼容时会自动回退到 CPU'),
            value: s.useCoreML,
            onChanged: (v) => set(() => s.useCoreML = v),
          ),
          const Divider(),
          ListTile(title: Text('练习', style: theme.textTheme.titleMedium)),
          ListTile(
            title: Text('音准容差 ±${s.toleranceCents} 音分'),
            subtitle: Slider(
              value: s.toleranceCents.toDouble(),
              min: 20,
              max: 100,
              divisions: 16,
              onChanged: (v) => set(() => s.toleranceCents = v.round()),
            ),
          ),
          SwitchListTile(
            title: const Text('忽略八度'),
            subtitle: const Text('男声唱女声歌（或反过来）时打开'),
            value: s.octaveTolerant,
            onChanged: (v) => set(() => s.octaveTolerant = v),
          ),
          ListTile(
            title: Text('延迟补偿 ${s.latencyOffsetMs} ms'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: s.latencyOffsetMs.toDouble(),
                  min: -300,
                  max: 300,
                  divisions: 60,
                  onChanged: (v) => set(() => s.latencyOffsetMs = v.round()),
                ),
                const Text('如果你的音高线总是比参考线晚（偏右），把数值调大；蓝牙耳机通常需要更大的补偿。'),
              ],
            ),
          ),
          ListTile(
            title: Text('麦克风门限 ${s.micGateDb.round()} dB'),
            subtitle: Slider(
              value: s.micGateDb,
              min: -70,
              max: -25,
              onChanged: (v) => set(() => s.micGateDb = v),
            ),
          ),
          ListTile(
            title: Text('练习视图宽度 ${s.practiceWindowSeconds.toStringAsFixed(0)} 秒'),
            subtitle: Slider(
              value: s.practiceWindowSeconds,
              min: 3,
              max: 12,
              divisions: 9,
              onChanged: (v) => set(() => s.practiceWindowSeconds = v),
            ),
          ),
          SwitchListTile(
            title: const Text('测量模式'),
            subtitle: const Text('关闭系统的自动增益等人声处理，音高更稳定（外放时音量可能变小）'),
            value: s.measurementMode,
            onChanged: (v) => set(() => s.measurementMode = v),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
