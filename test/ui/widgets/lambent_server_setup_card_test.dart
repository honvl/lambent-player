import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/lambent_server_setup_card.dart';
import 'package:moonfin/ui/widgets/sign_in_qr_code.dart';
import 'package:moonfin/util/platform_detection.dart';

void main() {
  // `flutter test --dart-define=MOONFIN_FORCE_TV=true` runs the TV side.
  testWidgets('a TV gets a QR code and the address, other screens a button', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LambentServerSetupCard(foreground: Colors.white)),
      ),
    );
    final isTv = PlatformDetection.isTV;
    expect(
      find.text('Get Lambent Server'),
      isTv ? findsNothing : findsOneWidget,
    );
    expect(find.byType(SignInQrCode), isTv ? findsOneWidget : findsNothing);
    expect(
      find.text(lambentServerSetupAddress),
      isTv ? findsOneWidget : findsNothing,
    );
    expect(lambentServerSetupUrl, 'https://$lambentServerSetupAddress');
  });
}
