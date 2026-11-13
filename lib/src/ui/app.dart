import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'library_page.dart';
import 'theme.dart';

class YinTraceApp extends StatelessWidget {
  const YinTraceApp({super.key});

  static ThemeData theme(Brightness b) => buildTheme(b);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YinTrace',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const LibraryPage(),
    );
  }
}

String formatDuration(double seconds) {
  if (seconds.isNaN || seconds < 0) return '–:––';
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String formatScore(double? score) => score == null || score.isNaN ? '–' : score.round().toString();
