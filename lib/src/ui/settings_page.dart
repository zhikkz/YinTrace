import 'package:flutter/material.dart';

import '../app/services.dart';
import '../app/settings.dart';
import '../app/test_build.dart';
import '../models/model_catalog.dart';
import '../models/model_manager.dart';
import 'about_page.dart';
import 'benchmark_page.dart';
import 'model_setup.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings? _settings;

  @override
  void dispose() {
    // A slider that was still being dragged when the page closed.
    _settings?.save();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final s = _settings = services.settings;
    final p = context.yt;
    Future<void> set(void Function() change) async {
      await s.update((_) => change());
      setState(() {});
    }

    // A slider changes the value while it is dragged and saves it when it
    // is let go (also after a tap, a key press or an accessibility action).
    void drag(void Function() change) {
      s.change((_) => change());
      setState(() {});
    }

    void dragEnd(double _) => s.save();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('设置')),
          SliverList.list(
            children: [
              const _Section('分离模型'),
              _Group(
                children: [
                  ListenableBuilder(
                    listenable: services.models,
                    builder: (context, _) => _ModelsRow(models: services.models),
                  ),
                  if (services.acceleration.supported)
                    ListenableBuilder(
                      listenable: services.acceleration,
                      builder: (context, _) => SwitchListTile(
                        title: const Text('用 GPU 加速人声分离'),
                        subtitle: Text(services.acceleration.status),
                        value: services.acceleration.active,
                        onChanged: services.acceleration.setEnabled,
                      ),
                    ),
                ],
              ),
              const _Footnote(
                '导入整首歌时，用 UVR 的人声分离模型在手机上提取人声。'
                '默认不去和声，只有在导入页打开“去和声”时才会使用去和声模型。'
                '删除模型不影响已经导入的歌。',
              ),
              const _Section('练习'),
              _Group(
                children: [
                  _SliderRow(
                    title: '音准容差',
                    value: '±${s.toleranceCents} 音分',
                    slider: Slider(
                      value: s.toleranceCents.toDouble(),
                      min: 20,
                      max: 100,
                      divisions: 16,
                      onChanged: (v) => drag(() => s.toleranceCents = v.round()),
                      onChangeEnd: dragEnd,
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
                      onChanged: (v) => drag(() => s.practiceWindowSeconds = v),
                      onChangeEnd: dragEnd,
                    ),
                  ),
                ],
              ),
              const _Section('麦克风与延迟'),
              _Group(
                children: [
                  _SliderRow(
                    title: '延迟补偿',
                    value: '${s.latencyOffsetMs >= 0 ? '+' : ''}${s.latencyOffsetMs} ms',
                    slider: Slider(
                      value: s.latencyOffsetMs.toDouble(),
                      min: -300,
                      max: 300,
                      divisions: 60,
                      onChanged: (v) => drag(() => s.latencyOffsetMs = v.round()),
                      onChangeEnd: dragEnd,
                    ),
                  ),
                  _SliderRow(
                    title: '麦克风门限',
                    value: '${s.micGateDb.round()} dB',
                    slider: Slider(
                      value: s.micGateDb,
                      min: -70,
                      max: -25,
                      onChanged: (v) => drag(() => s.micGateDb = v),
                      onChangeEnd: dragEnd,
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('测量模式'),
                    subtitle: const Text('关掉系统的自动增益，音高更稳；外放时音量可能变小'),
                    value: s.measurementMode,
                    onChanged: (v) => set(() => s.measurementMode = v),
                  ),
                ],
              ),
              _Footnote(
                '你的音高线总比原唱靠右，就把延迟补偿调大；蓝牙耳机通常要 +150 到 +250 ms。'
                '环境吵、音高线乱跳时，把麦克风门限调高。',
              ),
              // Test builds only (isTestBuild): not compiled into releases.
              if (isTestBuild) ...[
                const _Section('测试版'),
                _Group(
                  children: [
                    ListTile(
                      title: const Text('性能测试'),
                      subtitle: const Text('测这台手机分离人声的速度，生成一份报告'),
                      trailing: Icon(Icons.chevron_right_rounded, color: p.inkFaint),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const BenchmarkPage())),
                    ),
                    SwitchListTile(
                      title: const Text('音高检测改用 YIN 算法'),
                      subtitle: Text(services.pitchModelPath == null
                          ? '音高模型没能装上，现在用的就是 YIN'
                          : '和 AI 音高模型（SwiftF0）对比：练习、自由练习和之后导入的歌都用 YIN'),
                      value: s.yinPitch || services.pitchModelPath == null,
                      onChanged: services.pitchModelPath == null ? null : (v) => set(() => s.yinPitch = v),
                    ),
                    ListTile(
                      title: const Text('只用备用线路重新下载模型'),
                      subtitle: Text('删掉已下载的模型，再从 ${_backupRoute(services.models)} 下载一遍'
                          '（${formatMegabytes(services.models.totalBytes)}），看备用线路能不能用'),
                      trailing: Icon(Icons.chevron_right_rounded, color: p.inkFaint),
                      onTap: () => _redownloadFromBackup(context, services.models),
                    ),
                  ],
                ),
              ],
              const _Section('关于'),
              _Group(
                children: [
                  ListTile(
                    title: const Text('致谢与开源许可'),
                    trailing: Icon(Icons.chevron_right_rounded, color: p.inkFaint),
                    onTap: () =>
                        Navigator.of(context)
                            .push(MaterialPageRoute<void>(builder: (_) => const AboutPage())),
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ],
      ),
    );
  }
}

String _backupRoute(ModelManager models) =>
    {for (final s in models.specs) ...s.mirrors.map(routeName)}.join('、');

/// Test builds: removes the models and downloads them again over the backup
/// route only.
Future<void> _redownloadFromBackup(BuildContext context, ModelManager models) async {
  if (models.busy) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('只用备用线路重新下载？'),
      content: Text(
        '已下载的模型会被删掉，再只从备用线路 ${_backupRoute(models)} 下载 ${formatMegabytes(models.totalBytes)}。'
        '已经导入的歌不受影响。',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删掉并重新下载')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await models.deleteAll();
  models.backupOnly = true;
  if (context.mounted) await ensureModels(context);
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
        Row(
          children: [
            Text(title, style: context.type.bodyLarge),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(value, style: context.type.bodyMedium?.copyWith(fontFeatures: tabular)),
            ),
          ],
        ),
        slider,
      ],
    ),
  );
}

/// Status of the two separation models, with download / delete.
class _ModelsRow extends StatelessWidget {
  const _ModelsRow({required this.models});
  final ModelManager models;

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分离模型？'),
        content: Text(
          '可以腾出 ${formatMegabytes(models.installedBytes)}。已经导入的歌不受影响；'
          '下次导入整首歌时要重新下载。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await models.deleteAll();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final ready = models.isReady;
    final busy = models.busy;
    // Usually just 人声分离: 去和声 is downloaded the first time an import
    // uses it.
    final partial = !ready && !busy && models.installedBytes > 0;
    final String status;
    if (ready) {
      status = '已下载，占用 ${formatMegabytes(models.installedBytes)}';
    } else if (busy) {
      status = models.phase == ModelPhase.downloading
          ? '正在${isTestBuild && models.onBackupRoute ? '从备用线路' : ''}下载，${(models.progress * 100).floor()}%'
          : '正在准备…';
    } else if (partial) {
      status = '已下载部分模型，占用 ${formatMegabytes(models.installedBytes)}';
    } else {
      status = '还没有下载（${formatMegabytes(models.totalBytes)}）';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: ready ? p.malachite : p.gamboge),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('人声分离和去和声', style: context.type.bodyLarge),
                Text(status, style: context.type.bodySmall?.copyWith(fontFeatures: tabular)),
              ],
            ),
          ),
          // What is there can be deleted without downloading the rest first.
          if (partial) TextButton(onPressed: () => _delete(context), child: const Text('删除')),
          TextButton(
            onPressed: () => ready ? _delete(context) : ensureModels(context),
            child: Text(ready ? '删除' : (busy ? '查看' : '下载')),
          ),
        ],
      ),
    );
  }
}
