import 'package:flutter_test/flutter_test.dart';
import 'package:oches_desktop/main.dart';

void main() {
  test('unconfigured transport is unavailable', () async {
    expect(
      await const UnavailableCoreTransport().availability(),
      CoreAvailability.unavailable,
    );
  });

  testWidgets('shell reports unavailable', (tester) async {
    await tester.pumpWidget(const OchesApp());
    await tester.pumpAndSettle();
    expect(find.text('Core is unavailable.'), findsOneWidget);
  });
}
