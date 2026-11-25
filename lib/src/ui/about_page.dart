import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/licenses.dart';
import '../app/services.dart';
import '../app/update_check.dart';
import 'copyright_notice.dart';
import 'settings_group.dart';
import 'theme.dart';

/// Opens a web page outside the app; false when nothing could open it.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _launch(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

const _noticesUrl = '$appSourceUrl/blob/main/THIRD_PARTY_NOTICES.md';

/// The version and its updates, where the source is, credits for the work
/// YinTrace is built on, and the license texts.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.openUrl = _launch});

  final UrlOpener openUrl;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  UpdateChecker? _updates;

  /// A short note in place of a row's subtitle ("已复制"), by row.
  final _notes = <String, String>{};
  final _noteTimers = <String, Timer>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final updates = AppScope.of(context).updates;
    if (_updates == updates) return;
    _updates?.removeListener(_seen);
    _updates = updates..addListener(_seen);
    // Seen here, the news needs no dot on the way here any more.
    WidgetsBinding.instance.addPostFrameCallback((_) => _seen());
  }

  void _seen() {
    final updates = _updates;
    if (mounted && updates != null && updates.hasUnseenUpdate) scheduleMicrotask(() => unawaited(updates.markSeen()));
  }

  @override
  void dispose() {
    _updates?.removeListener(_seen);
    for (final timer in _noteTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _note(String row, String text) {
    _noteTimers[row]?.cancel();
    setState(() => _notes[row] = text);
    _noteTimers[row] = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notes.remove(row));
    });
  }

  Future<void> _copy(String row, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _note(row, '已复制到剪贴板');
  }

  /// Opens [url] in the browser, or copies it when there is none.
  Future<void> _open(String row, String url) async {
    if (await widget.openUrl(Uri.parse(url)) || !mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _note(row, '打不开浏览器，已复制地址');
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final settings = services.settings;
    final p = context.yt;
    final chevron = Icon(Icons.chevron_right_rounded, color: p.inkFaint);
    final external = Icon(Icons.open_in_new_rounded, size: 20, color: p.inkFaint);
    Widget credit(String what, String who) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(what, style: context.type.titleSmall),
          const SizedBox(height: 4),
          Text(who, style: context.type.bodyMedium),
        ],
      ),
    );
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('关于')),
          SliverList.list(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('音迹 $appVersion', style: context.type.titleLarge?.copyWith(fontFeatures: tabular)),
                    const SizedBox(height: 6),
                    Text(
                      '分离人声，画出每个字的音高，唱的时候看见自己哪里高了、哪里低了。所有处理都在这台设备上完成，'
                      '你的歌和录音不会上传。',
                      style: context.type.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SettingsSection('版本更新'),
              ListenableBuilder(
                listenable: Listenable.merge([services.updates, settings]),
                builder: (context, _) => SettingsGroup(
                  children: [
                    ..._updateRows(context, services.updates, external),
                    SwitchListTile(
                      title: const Text('自动检查更新'),
                      subtitle: const Text('每天最多查一次，只向 GitHub 查询最新的版本号'),
                      value: settings.autoCheckUpdates,
                      onChanged: (on) async {
                        await settings.update((s) => s.autoCheckUpdates = on);
                        unawaited(services.updates.checkAutomatically(enabled: on));
                      },
                    ),
                  ],
                ),
              ),
              const SettingsFootnote('有新版本时，曲库的设置按钮和这里会出现一个红点，不会弹窗打扰。'),
              const SettingsSection('源代码'),
              SettingsGroup(
                children: [
                  ListTile(
                    title: const Text('GitHub 仓库'),
                    subtitle: Text(
                      _notes['source'] ?? appSourceUrl.replaceFirst('https://', ''),
                      style: context.type.bodySmall?.copyWith(fontFeatures: tabular),
                    ),
                    trailing: IconButton(
                      tooltip: '复制仓库地址',
                      icon: Icon(Icons.copy_rounded, size: 20, color: p.inkSoft),
                      onPressed: () => _copy('source', appSourceUrl),
                    ),
                    onTap: () => _open('source', appSourceUrl),
                  ),
                ],
              ),
              const SettingsFootnote(
                '音迹是自由软件，按 GNU Affero 通用公共许可证第 3 版（AGPL-3.0）发布，不提供任何担保。'
                '你可以使用、修改和再分发它；分发它或用修改版对外提供网络服务时，要以同样的许可提供源代码。',
              ),
              const SettingsSection('致谢'),
              SettingsGroup(
                children: [
                  credit(
                    '分离模型',
                    'UVR-MDX-NET-Voc_FT 和 6_HP-Karaoke-UVR，由 Ultimate Vocal Remover 的开发者 Anjok07 和 aufr33 训练并公开发布。'
                        '音迹不附带模型，第一次导入整首歌时下载它们的原版文件。',
                  ),
                  credit(
                    '分离算法',
                    '移植自 Ultimate Vocal Remover GUI（MIT 许可）。其中 VR 架构来自 tsurumeso 的 vocal-remover，'
                        'MDX-Net 来自 Kuielab 和 Woosung Choi。',
                  ),
                  credit(
                    '音高检测',
                    '原唱的音高用 SwiftF0 音高模型测（Lars Nieradzik，2025，MIT 许可，随 App 附带）；'
                        '你唱的音高用 YIN 算法实时测（Alain de Cheveigné 与 Hideki Kawahara，2002）。',
                  ),
                  credit(
                    '逐句歌词对齐',
                    '对齐解码器移植自 wolfgitpr/HubertFA（Apache 2.0）。'
                        '模型权重及中、日文词典的适用许可待上游确认。英文词典衍生自 Carnegie Mellon Pronouncing Dictionary。',
                  ),
                  credit('拼音数据', '单字读音来自 Unicode Unihan。词组和补充读音改编自 CC-CEDICT（CC BY-SA 4.0）。'),
                  credit('其他', '音频引擎 miniaudio（David Reid）、推理引擎 ONNX Runtime（Microsoft）、界面 Flutter 及其开源插件。'),
                ],
              ),
              const SettingsSection('开源许可'),
              SettingsGroup(
                children: [
                  ListTile(
                    title: const Text('许可全文与开源组件'),
                    subtitle: const Text('音迹的 AGPL-3.0 全文，以及用到的每个开源组件的许可'),
                    trailing: chevron,
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: '音迹',
                      applicationVersion: appVersion,
                      applicationLegalese: appCopyright,
                    ),
                  ),
                  ListTile(
                    title: const Text('第三方声明'),
                    subtitle: Text(_notes['notices'] ?? '每个组件用在哪里、改了什么（THIRD_PARTY_NOTICES.md）'),
                    trailing: external,
                    onTap: () => _open('notices', _noticesUrl),
                  ),
                  ListTile(title: const Text('用户协议'), trailing: chevron, onTap: () => showUserTerms(context)),
                ],
              ),
              SettingsFootnote(appCopyright),
              const SizedBox(height: 40),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _updateRows(BuildContext context, UpdateChecker updates, Widget external) {
    final latest = updates.latest;
    final checkedAt = updates.checkedAt;
    final String status;
    if (updates.checking) {
      status = '正在检查…';
    } else if (updates.status == UpdateCheckStatus.failed) {
      status = '没能检查：${updates.error}';
    } else if (checkedAt == null) {
      status = '还没有检查过';
    } else if (updates.updateAvailable) {
      status = '${checkedTime(checkedAt)}检查';
    } else {
      status = '已是最新版本 · ${checkedTime(checkedAt)}检查';
    }
    return [
      if (updates.updateAvailable && latest != null)
        ListTile(
          leading: const UpdateDot(),
          minLeadingWidth: 8,
          title: Text('有新版本 ${latest.version}'),
          subtitle: Text(
            _notes['release'] ??
                [
                  if (latest.name.isNotEmpty && latest.name != latest.tag) latest.name,
                  if (latest.publishedAt != null) '${releaseDate(latest.publishedAt!)}发布',
                  '前往下载页',
                ].join(' · '),
          ),
          trailing: external,
          onTap: () => _open('release', latest.url),
        ),
      ListTile(
        title: const Text('检查更新'),
        subtitle: Text(status),
        trailing: updates.checking
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        onTap: updates.checking ? null : updates.check,
      ),
    ];
  }
}

/// "今天 14:03", "昨天 09:30" or "11 月 2 日", in local time.
String checkedTime(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(local);
  final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return '今天 $hm ';
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm ';
  if (day.year == today.year) return '${local.month} 月 ${local.day} 日';
  return '${local.year} 年 ${local.month} 月 ${local.day} 日';
}

/// "2026 年 11 月 25 日", in local time.
String releaseDate(DateTime at) {
  final local = at.toLocal();
  return '${local.year} 年 ${local.month} 月 ${local.day} 日';
}
