import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/display_refresh.dart';

void main() {
  test('a measured rate near a screen rate is that rate', () {
    expect(DisplayRefresh.nearest(1000 / 16.7), 60);
    expect(DisplayRefresh.nearest(1000 / 8.4), 120);
    expect(DisplayRefresh.nearest(1000 / 6.95), 144);
    expect(DisplayRefresh.nearest(59.9), 60);
    expect(DisplayRefresh.nearest(84), 84);
  });
}
