import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/features/shared/peer_info_sheet.dart';

void main() {
  const address = 'k3Y9xQ2mVb7Tn4Lp8Rw1Zs6Hd0Fg5Jc2Ae9Uo3Iy7Mq=';
  String? clipboard;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    IdentityScope.setActive('my-address');
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  testWidgets('a short address copies the whole key', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: CopyableAddress(address))),
    ));

    expect(find.text('k3Y9xQ…7Mq='), findsOneWidget);
    await tester.tap(find.byType(CopyableAddress));
    await tester.pump();

    expect(clipboard, address);
    expect(find.text('Copied full public address'), findsOneWidget);
  });

  testWidgets('details show the full address and copy it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showPeerInfoSheet(context, address: address, name: 'Alice'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text(address), findsOneWidget);
    await tester.tap(find.text('Copy address'));
    await tester.pump();

    expect(clipboard, address);
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
  });
}
