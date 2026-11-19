import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/core_client.dart';
import 'state/vertical_flow_controller.dart';
import 'ui/vertical_flow_shell.dart';

void main() => runApp(const OchesApp());

/// A placeholder cannot authenticate a peer or dispatch protected requests.
abstract interface class CoreTransport {
  Future<CoreAvailability> availability();
}

enum CoreAvailability { unavailable }

class UnavailableCoreTransport implements CoreTransport {
  const UnavailableCoreTransport();

  @override
  Future<CoreAvailability> availability() async => CoreAvailability.unavailable;
}

class MacOSCoreTransport implements CoreTransport {
  const MacOSCoreTransport({
    this.channel = const MethodChannel('com.oches.core/readiness'),
  });

  final MethodChannel channel;

  @override
  Future<CoreAvailability> availability() async {
    try {
      await channel
          .invokeMethod<String>('readiness')
          .timeout(const Duration(seconds: 5));
    } on Exception {
      return CoreAvailability.unavailable;
    }
    return CoreAvailability.unavailable;
  }
}

class OchesApp extends StatelessWidget {
  const OchesApp({
    super.key,
    this.transport = const MacOSCoreTransport(),
    this.coreClient,
  });

  final CoreTransport transport;
  final OchesCoreClient? coreClient;

  @override
  Widget build(BuildContext context) {
    final client = coreClient;
    if (client == null) {
      return MaterialApp(
        title: 'Oches Builder',
        home: Scaffold(
          appBar: AppBar(title: const Text('Oches Builder')),
          body: Center(
            child: FutureBuilder<CoreAvailability>(
              future: transport.availability(),
              builder: (context, snapshot) => Text(
                snapshot.connectionState == ConnectionState.done
                    ? 'Core is unavailable.'
                    : 'Checking Core availability…',
              ),
            ),
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'Oches Builder',
      home: VerticalFlowShell(
        controller: VerticalFlowController(client: client),
      ),
    );
  }
}
