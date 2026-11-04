import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/lambent_server.dart';

void main() {
  test('a Lambent Server id is told from a Jellyfin one', () {
    expect(isLambentServerId('6c616d6201234567890abcdef0000000'), isTrue);
    expect(isLambentServerId('6C616D6201234567890ABCDEF0000000'), isTrue);
    expect(isLambentServerId('f27b7d3c8e1a4c6e9b0d2a5f7c3e1b9d'), isFalse);
    expect(isLambentServerId(''), isFalse);
    expect(isLambentServerId(null), isFalse);
  });
}
