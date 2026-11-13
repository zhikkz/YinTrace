import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/model_store.dart';
import '../app/services.dart';
import 'theme.dart';

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
          messenger.showSnackBar(SnackBar(
              content: Text('${f.name} 不是 .onnx 或 .json。.pth 要先在电脑上用 tools/prepare_models.py 转换。')));
          continue;
        }
        await store.importFile(path);
        n++;
      }
      if (n > 0) messenger.showSnackBar(SnackBar(content: Text('导入了 $n 个文件')));
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
    final p = context.yt;
    Future<void> set(void Function() change) async {
      await s.update((_) => change());
      setState(() {});
    }

    Future<void> delete(ModelFile m) async {
      await services.models.delete(m);
      if (mounted) setState(() {});
    }

    String sizeOf(ModelFile m) {
      try {
        return '${(m.sizeBytes / 1e6).toStringAsFixed(0)} MB';
      } catch (_) {
        return '';
      }
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('设置')),
          SliverList.list(children: [
            const _Section('分离模型'),
            _Group(children: [
              for (final kind in ModelKind.values)
                _ModelRow(
                  kind: kind,
                  file: models.where((m) => m.path == services.models.pathFor(kind)).firstOrNull,
                  size: sizeOf,
                  onDelete: delete,
                ),
              for (final m in models.where((m) => m.path != services.models.pathFor(m.kind)))
                _ModelRow(kind: m.kind, file: m, size: sizeOf, onDelete: delete, spare: true),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _importModel,
                style: OutlinedButton.styleFrom(alignment: Alignment.center),
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.file_open_outlined),
                label: const Text('导入模型文件'),
              ),
            ),
            _Footnote('UVR-MDX-NET-Voc_FT.onnx 可以直接导入。6_HP-Karaoke-UVR.pth 要先在电脑上运行 '
                'tools/prepare_models.py，转成 .onnx 和同名 .json 后一起导入；'
                '也可以用“文件”App 或访达把它们拷进 YinTrace 的 models 文件夹。'),
            _Group(children: [
              SwitchListTile(
                title: const Text('分离时用 Core ML 加速'),
                subtitle: const Text('不兼容时自动改用 CPU'),
                value: s.useCoreML,
                onChanged: (v) => set(() => s.useCoreML = v),
              ),
            ]),
            const _Section('练习'),
            _Group(children: [
              _SliderRow(
                title: '音准容差',
                value: '±${s.toleranceCents} 音分',
                slider: Slider(
                  value: s.toleranceCents.toDouble(),
                  min: 20,
                  max: 100,
                  divisions: 16,
                  onChanged: (v) => set(() => s.toleranceCents = v.round()),
                ),
              ),
              SwitchListTile(
                title: const Text('忽略八度'),
                subtitle: const Text('男声唱女声的歌（或反过来）时打开'),
                value: s.octaveTolerant,
                onChanged: (v) => set(() => s.octaveTolerant = v),
              ),
              _SliderRow(
                title: '练习画面宽度',
                value: '${s.practiceWindowSeconds.toStringAsFixed(0)} 秒',
                slider: Slider(
                  value: s.practiceWindowSeconds,
                  min: 3,
                  max: 12,
                  divisions: 9,
                  onChanged: (v) => set(() => s.practiceWindowSeconds = v),
                ),
              ),
            ]),
            const _Section('麦克风与延迟'),
            _Group(children: [
              _SliderRow(
                title: '延迟补偿',
                value: '${s.latencyOffsetMs >= 0 ? '+' : ''}${s.latencyOffsetMs} ms',
                slider: Slider(
                  value: s.latencyOffsetMs.toDouble(),
                  min: -300,
                  max: 300,
                  divisions: 60,
                  onChanged: (v) => set(() => s.latencyOffsetMs = v.round()),
                ),
              ),
              _SliderRow(
                title: '麦克风门限',
                value: '${s.micGateDb.round()} dB',
                slider: Slider(
                  value: s.micGateDb,
                  min: -70,
                  max: -25,
                  onChanged: (v) => set(() => s.micGateDb = v),
                ),
              ),
              SwitchListTile(
                title: const Text('测量模式'),
                subtitle: const Text('关掉系统的自动增益，音高更稳；外放时音量可能变小'),
                value: s.measurementMode,
                onChanged: (v) => set(() => s.measurementMode = v),
              ),
            ]),
            _Footnote('你的音高线总比原唱靠右，就把延迟补偿调大；蓝牙耳机通常要 +150 到 +250 ms。'
                '环境吵、音高线乱跳时，把麦克风门限调高。'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              child: Text('YinTrace 的人声分离基于 Ultimate Vocal Remover 的模型。',
                  style: context.type.labelSmall?.copyWith(color: p.inkFaint)),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
        child: Text(title, style: context.type.titleSmall?.copyWith(color: context.yt.inkSoft)),
      );
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        child: Text(text, style: context.type.bodySmall),
      );
}

/// An inset group of rows on a white surface, separated by hairlines.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const Divider(indent: 16));
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: rows),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.title, required this.value, required this.slider});
  final String title;
  final String value;
  final Widget slider;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Text(title, style: context.type.bodyLarge),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(value, style: context.type.bodyMedium?.copyWith(fontFeatures: tabular)),
              ),
            ]),
            slider,
          ],
        ),
      );
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.kind, required this.file, required this.size, required this.onDelete, this.spare = false});
  final ModelKind kind;
  final ModelFile? file;
  final String Function(ModelFile) size;
  final void Function(ModelFile) onDelete;
  final bool spare;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final f = file;
    final ready = f != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: spare ? p.staffStrong : (ready ? p.malachite : p.cinnabar),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spare ? '备用：${kind.label}' : kind.label, style: context.type.bodyLarge),
                Text(
                  ready ? '${f.name}，${size(f)}${f.hasSidecar ? '' : '，没有配置文件'}' : '需要 ${kind.recommended}',
                  style: context.type.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (ready)
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.delete_outline_rounded, color: p.inkFaint),
              onPressed: () => onDelete(f),
            ),
        ],
      ),
    );
  }
}
