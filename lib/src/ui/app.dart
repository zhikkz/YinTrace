import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'library_page.dart';

class YinTraceApp extends StatelessWidget {
  const YinTraceApp({super.key});

  static ThemeData theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3D6FB6), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      cardTheme: const CardThemeData(margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YinTrace',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
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
  if (seconds.isNaN || seconds < 0) return '--:--';
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String formatScore(double? score) => score == null || score.isNaN ? '--' : score.round().toString();
