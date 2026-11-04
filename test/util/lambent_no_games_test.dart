import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/game_cores.dart';
import 'package:moonfin/util/game_library.dart';
import 'package:moonfin/util/lambent_brand.dart';

void main() {
  setUp(() => LambentBrand.enableGames = false);
  tearDown(() => LambentBrand.enableGames = true);

  test('Lambent shows no game library and offers no cores', () {
    expect(isGameLibrary('1', 'mixed', 'Games'), isFalse);
    expect(supportsCoreDownloads, isFalse);
    expect(canToggleGameBackend, isFalse);
    expect(usesNativeGameBackend, isFalse);
    expect(bundlesGameCores, isFalse);
  });
}
