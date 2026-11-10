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

  test('a browser is named by its browser and system', () {
    const mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)';
    expect(browserDeviceName('$mac Chrome/130.0 Safari/537.36'), 'Chrome on Mac');
    expect(browserDeviceName('$mac Version/18.0 Safari/605.1.15'), 'Safari on Mac');
    expect(
      browserDeviceName('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0'),
      'Edge on Windows',
    );
    expect(
      browserDeviceName('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile Safari/604.1'),
      'Safari on iPhone',
    );
    expect(browserDeviceName(''), 'A browser');
  });

  test('a generic iOS name gives way to the model', () {
    expect(appleMobileDeviceName(name: 'iPhone', modelName: 'iPhone 16 Pro', model: 'iPhone'), 'iPhone 16 Pro');
    expect(appleMobileDeviceName(name: "Sam's iPad", modelName: 'iPad Air', model: 'iPad'), "Sam's iPad");
    expect(appleMobileDeviceName(name: '', modelName: '', model: 'iPhone'), 'iPhone');
  });
}
