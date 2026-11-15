import 'package:flutter/material.dart';

import 'src/app/licenses.dart';
import 'src/app/picked_files.dart';
import 'src/app/services.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  final services = await AppServices.init();
  sweepPickedCopies(); // nothing picked is in use yet
  runApp(AppScope(services: services, child: const YinTraceApp()));
}
