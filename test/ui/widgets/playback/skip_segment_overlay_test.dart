import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/models/media_segment.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/playback/skip_segment_overlay.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
  });

  tearDown(() {
    PlatformDetection.setTvMode(false);
    return GetIt.instance.reset();
  });

  Future<(FocusNode, FocusNode)> show(WidgetTester tester) async {
    final skip = FocusNode();
    final other = FocusNode();
    addTearDown(skip.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(
            children: [
              Focus(focusNode: other, child: const SizedBox(width: 10)),
              SkipSegmentOverlay(
                segment: const MediaSegment(
                  id: 'intro',
                  itemId: 'item',
                  type: MediaSegmentType.intro,
                  start: Duration.zero,
                  end: Duration(seconds: 90),
                ),
                focusNode: skip,
                onSkip: () {},
                onDismiss: () {},
              ),
            ],
          ),
        ),
      ),
    );
    return (skip, other);
  }

  // The focus change lands during the first frame, and the redraw it asks for
  // needs a second one.
  Future<void> moveTo(WidgetTester tester, FocusNode node) async {
    node.requestFocus();
    await tester.pump();
    await tester.pump();
  }

  bool lit(WidgetTester tester) {
    final borders = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(SkipSegmentOverlay),
            matching: find.byType(Container),
          ),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.border)
        .whereType<Border>();
    final icon = tester.widget<Icon>(find.byIcon(Icons.skip_next_rounded).first);
    final orange = icon.color == AppColorScheme.accent;
    expect(borders.isNotEmpty, orange);
    return orange;
  }

  testWidgets('on TV the highlight follows focus', (tester) async {
    PlatformDetection.setTvMode(true);
    final (skip, other) = await show(tester);

    await moveTo(tester, skip);
    expect(lit(tester), isTrue);

    await moveTo(tester, other);
    expect(lit(tester), isFalse);

    await moveTo(tester, skip);
    expect(lit(tester), isTrue);
  });

  testWidgets('off TV the button stays lit without focus', (tester) async {
    await show(tester);
    await tester.pump();
    expect(lit(tester), isTrue);
  });
}
