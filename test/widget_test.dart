import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/app.dart';

void main() {
  testWidgets('Onboarding shows identity choice buttons',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MeshengerApp());
    await tester.pumpAndSettle();

    expect(find.text('Meshenger'), findsOneWidget);
    expect(find.text('Create New Identity'), findsOneWidget);
    expect(find.text('Unlock Existing Identity'), findsOneWidget);

    // Choosing "Create New Identity" fades to the password + nickname form.
    await tester.tap(find.text('Create New Identity'));
    await tester.pumpAndSettle();
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Nickname (optional)'), findsOneWidget);

    // Back, then "Unlock Existing Identity" shows only the password field.
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock Existing Identity'));
    await tester.pumpAndSettle();
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Nickname (optional)'), findsNothing);
  });
}
