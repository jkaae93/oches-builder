import 'package:flutter/material.dart';

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

class OchesApp extends StatelessWidget {
  const OchesApp({
    super.key,
    this.transport = const UnavailableCoreTransport(),
  });

  final CoreTransport transport;

  @override
  Widget build(BuildContext context) => MaterialApp(
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
