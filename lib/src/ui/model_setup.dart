import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/picked_files.dart';
import '../app/screen_awake.dart';
import '../app/test_build.dart';
import '../app/services.dart';
import '../models/model_catalog.dart';
import '../models/model_manager.dart';
import 'theme.dart';

/// Makes sure the two separation models are on the device, offering to
/// download them if they are not. Returns whether they are ready.
Future<bool> ensureModels(BuildContext context) async {
  final models = AppScope.of(context).models;
  if (models.isReady) return true;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const ModelSetupSheet(),
  );
  return models.isReady;
}

/// Download (or pick from Files) the two UVR models. The download belongs
/// to the app, not to this sheet: closing the sheet does not stop it.
class ModelSetupSheet extends StatefulWidget {
  const ModelSetupSheet({super.key});

  @override
  State<ModelSetupSheet> createState() => _ModelSetupSheetState();
}

class _ModelSetupSheetState extends State<ModelSetupSheet> {
  ModelManager? _models;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final models = AppScope.of(context).models;
    if (_models != models) {
      _models?.removeListener(_changed);
      _models = models..addListener(_changed);
    }
  }

  @override
  void dispose() {
    _models?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    final models = _models!;
    // The download's own hold: it goes on after this sheet is closed, and
    // its end must not switch off what the page then open keeps on.
    final awake = ScreenAwake()..hold();
    try {
      await models.install();
    } finally {
      awake.release();
    }
  }

  Future<void> _pick() async {
    final models = _models!;
    final files = await FilePicker.pickFiles(type: FileType.any);
    final paths = [
      for (final f in files)
        if (f.path != null) f.path!
    ];
    if (paths.isEmpty) return;
    try {
      await models.importFiles(paths);
    } finally {
      // The models are installed from the picker's copies (194 MB); only
      // these, not the song that may be waiting on the import page.
      for (final path in paths) {
        discardPickedCopy(path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = _models!;
    final p = context.yt;
    final phase = models.phase;
    final working = models.busy;
    final ready = phase == ModelPhase.ready;
    final partial = !working && !ready && models.receivedBytes > 0;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 4, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ready ? '模型已就绪' : '下载分离模型', style: context.type.headlineSmall),
            const SizedBox(height: 8),
            Text(
              ready
                  ? '现在可以导入整首歌了。'
                  : '导入整首歌时，YinTrace 用这两个模型在手机上把主唱分出来。'
                      '一共 ${formatMegabytes(models.totalBytes)}，只需下载一次，建议连 Wi‑Fi。',
              style: context.type.bodyMedium,
            ),
            const SizedBox(height: 18),
            for (final spec in models.specs) _ModelLine(spec: spec, models: models),
            const SizedBox(height: 14),
            if (working || partial) ...[
              LinearProgressIndicator(
                value: phase == ModelPhase.downloading || partial ? models.progress : null,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 8),
              Text(_status(models, partial), style: context.type.bodySmall?.copyWith(fontFeatures: tabular)),
              const SizedBox(height: 14),
            ],
            if (models.error != null && !working) ...[
              Text(models.error!, style: context.type.bodyMedium?.copyWith(color: p.cinnabar)),
              // What each route answered: for testers.
              if (isTestBuild && models.errorDetail != null) ...[
                const SizedBox(height: 4),
                Text(models.errorDetail!, style: context.type.bodySmall?.copyWith(color: p.cinnabar)),
              ],
              const SizedBox(height: 14),
            ],
            SizedBox(
              width: double.infinity,
              child: ready
                  ? FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('好'))
                  : working
                      ? OutlinedButton(
                          onPressed: phase == ModelPhase.downloading ? models.cancel : null,
                          style: OutlinedButton.styleFrom(alignment: Alignment.center),
                          child: const Text('暂停'),
                        )
                      : FilledButton(
                          onPressed: _download,
                          child: Text(models.error != null
                              ? '重试'
                              : partial
                                  ? '继续下载'
                                  : '下载'),
                        ),
            ),
            if (!ready && !working)
              Center(
                child: TextButton(
                  onPressed: _pick,
                  child: Text('已经有这两个文件？从“文件”里选',
                      style: context.type.labelMedium?.copyWith(color: p.inkSoft)),
                ),
              ),
            const SizedBox(height: 4),
            Text('模型由 Ultimate Vocal Remover 项目（Anjok07、aufr33）训练并公开发布。', style: context.type.labelSmall),
          ],
        ),
      ),
    );
  }

  static String _status(ModelManager m, bool partial) {
    final got = '${(m.receivedBytes / 1e6).toStringAsFixed(0)} / ${formatMegabytes(m.totalBytes)}';
    if (partial) return '已下载 $got';
    switch (m.phase) {
      case ModelPhase.downloading:
        // The route switches by itself; only test builds say which one is used.
        final route = isTestBuild && m.onBackupRoute ? '备用线路 ${m.route}，' : '';
        final speed = m.bytesPerSecond;
        if (speed <= 0) return '$route$got';
        final remain = ((m.totalBytes - m.receivedBytes) / speed).round();
        final eta = remain >= 60 ? '还要约 ${remain ~/ 60} 分钟' : '还要约 $remain 秒';
        return '$route$got，${(speed / 1e6).toStringAsFixed(1)} MB/秒，$eta';
      case ModelPhase.verifying:
        return '正在校验文件…';
      case ModelPhase.preparing:
        return '正在生成去和声模型…';
      case ModelPhase.missing:
      case ModelPhase.ready:
      case ModelPhase.failed:
        return got;
    }
  }
}

class _ModelLine extends StatelessWidget {
  const _ModelLine({required this.spec, required this.models});
  final ModelSpec spec;
  final ModelManager models;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final installed = models.isInstalled(spec);
    final active = models.current == spec;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: installed
                ? Icon(Icons.check_rounded, size: 18, color: p.malachite)
                : active
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.circle, size: 6, color: p.staffStrong),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spec.title, style: context.type.bodyLarge),
                Text(spec.purpose, style: context.type.bodySmall),
              ],
            ),
          ),
          Text(formatMegabytes(spec.bytes), style: context.type.bodySmall?.copyWith(fontFeatures: tabular)),
        ],
      ),
    );
  }
}
