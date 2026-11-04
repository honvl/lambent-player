import 'dart:async';

import 'package:moonfin/util/lambent_brand.dart';

/// Lambent ships without games (LambentBrand.enableGames), but the game code
/// stays, so its tests keep running.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LambentBrand.enableGames = true;
  await testMain();
}
