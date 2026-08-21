import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // No platform secure storage in widget tests: report an empty registry
    // so onboarding lands on the "create identity" stage.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'read') return null;
        if (call.method == 'readAll') return <String, String>{};
        return null;
      },
    );
  });

  testWidgets('onboarding with no identities shows the create form',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MeshengerApp());
    await tester.pumpAndSettle();

    expect(find.text('Meshenger'), findsOneWidget);
    expect(find.text('Pick an avatar'), findsOneWidget);
    expect(find.text('Nickname (optional)'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Create Identity'), findsOneWidget);

    // With zero saved identities there is no picker to go back to.
    expect(find.text('Back'), findsNothing);
  });

  testWidgets('weak passwords are rejected with the policy message',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MeshengerApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'weak');
    await tester.tap(find.text('Create Identity'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Password must be ≥ 11 characters'),
      findsOneWidget,
    );
  });
}
