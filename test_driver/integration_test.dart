// Host side of `flutter drive` for the integration tests: writes the data a
// test reports (binding.reportData) to build/integration_response_data.json.
// The device benchmark can take long (Core ML compiles each model once).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(timeout: const Duration(minutes: 90));
