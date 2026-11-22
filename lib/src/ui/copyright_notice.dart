import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<bool> confirmCopyright(
  BuildContext context, {
  required String contents,
  required String action,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('版权提示'),
          content: Text(
            '$contents。请确认你有权按所选方式使用这些内容。'
            '分享前，请确认授权也涵盖接收人、用途和传播范围。',
          ),
          actions: [
            TextButton(
              onPressed: () => showUserTerms(dialogContext),
              child: const Text('用户协议'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> showUserTerms(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push<void>(MaterialPageRoute(builder: (_) => const _UserTermsPage()));

class _UserTermsPage extends StatelessWidget {
  const _UserTermsPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('用户协议')),
    body: FutureBuilder<String>(
      future: rootBundle.loadString('assets/legal/user-terms-zh.txt'),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('暂时无法读取用户协议。'));
        final text = snapshot.data;
        if (text == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            SelectableText(text, style: Theme.of(context).textTheme.bodyMedium),
          ],
        );
      },
    ),
  );
}
