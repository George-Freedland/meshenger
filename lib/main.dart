import 'package:flutter/material.dart';
import 'app.dart';
import 'core/services/transport_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    TransportLog.instance.log('Flutter error: ${details.exceptionAsString()}');
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    TransportLog.instance.log('Uncaught error: $error');
    debugPrintStack(stackTrace: stack, label: 'Uncaught error');
    return true;
  };
  runApp(const MeshengerApp());
}
