import 'package:flutter/material.dart';

import '../app/licenses.dart';
import 'theme.dart';

/// Credits for the work YinTrace is built on, and the license texts.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    Widget credit(String what, String who) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            sliver: SliverList.list(children: [
              Text('YinTrace $appVersion', style: context.type.bodyLarge?.copyWith(fontFeatures: tabular)),
              const SizedBox(height: 4),
              Text('分离人声，画出每个字的音高，唱的时候看见自己哪里高了、哪里低了。所有处理都在这台设备上完成，'
                  '你的歌和录音不会上传。', style: context.type.bodyMedium),
              const SizedBox(height: 28),
              Text('致谢', style: context.type.titleLarge),
              const SizedBox(height: 14),
              credit('分离模型',
                  'UVR-MDX-NET-Voc_FT 和 6_HP-Karaoke-UVR，由 Ultimate Vocal Remover 的开发者 Anjok07 和 aufr33 训练并公开发布。'
                      'YinTrace 不附带模型，而是从 UVR 的官方模型库下载。'),
              credit('分离算法',
                  '移植自 Ultimate Vocal Remover GUI（MIT 许可）。其中 VR 架构来自 tsurumeso 的 vocal-remover，'
                      'MDX-Net 来自 Kuielab 和 Woosung Choi。'),
              credit('音高检测', 'YIN 算法，Alain de Cheveigné 与 Hideki Kawahara，2002。'),
              credit('其他', '音频引擎 miniaudio（David Reid）；推理引擎 ONNX Runtime（Microsoft）；'
                  '拼音数据 pypinyin（mozillazg）；界面 Flutter。'),
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'YinTrace',
                  applicationVersion: appVersion,
                ),
                child: Row(children: [
                  const Expanded(child: Text('开源许可')),
                  Icon(Icons.chevron_right_rounded, color: p.inkFaint),
                ]),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
