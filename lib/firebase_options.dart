import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

/// Lambent has no Firebase project of its own yet, so push messaging is off
/// (LambentBrand.enablePushMessaging) and no build carries a project id. Run
/// the FlutterFire CLI for Lambent's own project to bring push back.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => throw UnsupportedError(
    'Lambent has no Firebase project configured.',
  );
}
