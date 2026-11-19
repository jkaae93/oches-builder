import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:oches_desktop/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.oches.core/readiness');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native readiness cannot grant analysis availability', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'readiness');
          expect(call.arguments, isNull);
          return 'ready';
        });
    expect(
      await const MacOSCoreTransport().availability(),
      CoreAvailability.unavailable,
    );
  });

  test('missing native handler fails closed', () async {
    expect(
      await const MacOSCoreTransport().availability(),
      CoreAvailability.unavailable,
    );
  });
  test('unconfigured transport is unavailable', () async {
    expect(
      await const UnavailableCoreTransport().availability(),
      CoreAvailability.unavailable,
    );
  });

  testWidgets('shell reports unavailable', (tester) async {
    await tester.pumpWidget(const OchesApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Core is unavailable.'), findsOneWidget);
  });
}
