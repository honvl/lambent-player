import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which macOS keychain the app keeps tokens, keys and licences in.
///
/// The Mac App Store build is signed with a provisioning profile, so its app
/// ID is a keychain access group and the data protection keychain takes its
/// writes. That keychain never asks the user for their login password, even
/// when another build with the same bundle id (the Developer ID download from
/// getlambent.app, or a local test copy) saved items first.
///
/// The Developer ID build has no profile, so the data protection keychain
/// refuses every write; it keeps the file based keychain.
const MacOsOptions lambentMacKeychain = MacOsOptions(
  usesDataProtectionKeychain:
      String.fromEnvironment('DISTRIBUTION_CHANNEL') == 'macos_pkg',
);
