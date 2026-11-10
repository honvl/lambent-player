import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/repositories/offline_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/data/viewmodels/item_detail_view_model.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/detail/item_detail_screen.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ViewModel extends Mock implements ItemDetailViewModel {}

class _Sync extends Mock implements PluginSyncService {}

class _SeerrPrefs extends Mock implements SeerrPreferences {}

class _Users extends Mock implements UserRepository {}

class _Offline extends Mock implements OfflineRepository {}

class _Playback extends Mock implements PlaybackManager {}

class _Queue extends Mock implements QueueService {}

// A season's Play names the episode it plays, as the show's does and as
// Plex words it.
void main() {
  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));

    final sync = _Sync();
    when(() => sync.seerrAvailable).thenReturn(false);
    GetIt.instance.registerSingleton<PluginSyncService>(sync);

    final seerrPrefs = _SeerrPrefs();
    when(() => seerrPrefs.showRequestStatus).thenReturn(false);
    GetIt.instance.registerSingleton<SeerrPreferences>(seerrPrefs);

    final users = _Users();
    when(() => users.currentUserStream).thenAnswer((_) => const Stream.empty());
    GetIt.instance.registerSingleton<UserRepository>(users);

    final offline = _Offline();
    when(() => offline.getItem(any())).thenAnswer((_) async => null);
    when(() => offline.getSeasonEpisodes(any())).thenAnswer((_) async => []);
    GetIt.instance.registerSingleton<OfflineRepository>(offline);

    final queue = _Queue();
    final playback = _Playback();
    when(() => playback.queueService).thenReturn(queue);
    GetIt.instance.registerSingleton<PlaybackManager>(playback);
  });

  tearDown(() async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic);
    await GetIt.instance.reset();
  });

  AggregatedItem episode(int number, {bool played = false, int minutes = 0}) =>
      AggregatedItem(
        id: 'ep-$number',
        serverId: 'server-1',
        rawData: {
          'Id': 'ep-$number',
          'Type': 'Episode',
          'ParentIndexNumber': 2,
          'IndexNumber': number,
          'RunTimeTicks': const Duration(minutes: 24).inMicroseconds * 10,
          'UserData': {
            'Played': played,
            'PlaybackPositionTicks':
                Duration(minutes: minutes).inMicroseconds * 10,
            if (minutes > 0) 'PlayedPercentage': minutes / 24 * 100,
          },
        },
      );

  Future<void> pumpSeason(
    WidgetTester tester,
    List<AggregatedItem> episodes,
  ) async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.tv);
    final vm = _ViewModel();
    when(() => vm.item).thenReturn(
      AggregatedItem(
        id: 'season-2',
        serverId: 'server-1',
        rawData: const {'Id': 'season-2', 'Type': 'Season', 'IndexNumber': 2},
      ),
    );
    when(() => vm.episodes).thenReturn(episodes);
    when(() => vm.isSeerrOnly).thenReturn(false);
    when(() => vm.supportsPersonalRating).thenReturn(false);
    when(() => vm.searchesYouTubeForTrailer).thenReturn(false);
    when(() => vm.features).thenReturn(const []);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: SingleChildScrollView(
            child: DetailActionButtons(
              viewModel: vm,
              itemId: 'season-2',
              onSelectedMediaSourceChanged: (_) {},
              modernStyle: true,
              nouveauStyle: true,
            ),
          ),
        ),
      ),
    );
    // On a TV the row asks for Play's focus a moment after it is built.
    await tester.pump(const Duration(milliseconds: 100));
  }

  String playLabel(WidgetTester tester) => tester
      .widgetList<RichText>(find.byType(RichText))
      .map((text) => text.text.toPlainText())
      .firstWhere((text) => text.contains(' S2 E'));

  testWidgets('an unwatched season plays its first episode', (tester) async {
    await pumpSeason(tester, [episode(1), episode(2)]);
    expect(playLabel(tester), 'Play S2 E1');
  });

  testWidgets('a season under way names the next one', (tester) async {
    await pumpSeason(tester, [
      episode(1, played: true),
      episode(2, minutes: 10),
      episode(3),
    ]);
    expect(playLabel(tester), 'Resume S2 E2 • 14m left');
  });

  testWidgets('a watched season starts over', (tester) async {
    await pumpSeason(tester, [
      episode(1, played: true),
      episode(2, played: true),
    ]);
    expect(playLabel(tester), 'Replay S2 E1');
  });
}
