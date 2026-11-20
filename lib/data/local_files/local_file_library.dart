import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../util/platform_detection.dart';
import '../models/aggregated_item.dart';

/// A video file on this device that came from outside the app: picked in the
/// system file browser or handed over with "Open in". The file stays where it
/// is; [bookmark] is the platform's lasting reference to it.
class LocalFile {
  final String id;
  final String name;
  final Uint8List bookmark;
  final int size;

  /// True when the system copied the file into the app (an "Open in" that
  /// could not open in place), so forgetting it also deletes that copy.
  final bool owned;
  final DateTime addedAt;
  final DateTime? lastPlayedAt;
  final int positionTicks;
  final int? runTimeTicks;

  /// The file's tracks as Jellyfin `MediaStreams`, read once on first play.
  final List<Map<String, dynamic>>? mediaStreams;

  const LocalFile({
    required this.id,
    required this.name,
    required this.bookmark,
    required this.size,
    required this.owned,
    required this.addedAt,
    this.lastPlayedAt,
    this.positionTicks = 0,
    this.runTimeTicks,
    this.mediaStreams,
  });

  /// The name without its extension, which is what a title is shown as.
  String get title {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  double get progress {
    final total = runTimeTicks ?? 0;
    if (total <= 0 || positionTicks <= 0) return 0;
    return (positionTicks / total).clamp(0.0, 1.0);
  }

  LocalFile copyWith({
    Uint8List? bookmark,
    DateTime? lastPlayedAt,
    int? positionTicks,
    int? runTimeTicks,
    List<Map<String, dynamic>>? mediaStreams,
  }) => LocalFile(
    id: id,
    name: name,
    bookmark: bookmark ?? this.bookmark,
    size: size,
    owned: owned,
    addedAt: addedAt,
    lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
    positionTicks: positionTicks ?? this.positionTicks,
    runTimeTicks: runTimeTicks ?? this.runTimeTicks,
    mediaStreams: mediaStreams ?? this.mediaStreams,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'bookmark': base64Encode(bookmark),
    'size': size,
    'owned': owned,
    'addedAt': addedAt.toIso8601String(),
    if (lastPlayedAt != null) 'lastPlayedAt': lastPlayedAt!.toIso8601String(),
    'positionTicks': positionTicks,
    if (runTimeTicks != null) 'runTimeTicks': runTimeTicks,
    if (mediaStreams != null) 'mediaStreams': mediaStreams,
  };

  static LocalFile? fromJson(Map<String, dynamic> json) {
    try {
      return LocalFile(
        id: json['id'] as String,
        name: json['name'] as String,
        bookmark: base64Decode(json['bookmark'] as String),
        size: (json['size'] as num?)?.toInt() ?? 0,
        owned: json['owned'] as bool? ?? false,
        addedAt: DateTime.parse(json['addedAt'] as String),
        lastPlayedAt: DateTime.tryParse(json['lastPlayedAt'] as String? ?? ''),
        positionTicks: (json['positionTicks'] as num?)?.toInt() ?? 0,
        runTimeTicks: (json['runTimeTicks'] as num?)?.toInt(),
        mediaStreams: (json['mediaStreams'] as List?)
            ?.map((s) => (s as Map).cast<String, dynamic>())
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// What a local file plays from: its path, with access held until [release].
class OpenedLocalFile {
  final LocalFile file;
  final String path;
  const OpenedLocalFile(this.file, this.path);
}

/// The video files on this device the viewer opened from outside the app,
/// newest first, with where each was left.
///
/// Each one plays as an [AggregatedItem] whose id starts with [idPrefix], so
/// it goes through the same player, local-first resolver and progress
/// tracking as a download, and never reaches a server.
class LocalFileLibrary extends ChangeNotifier {
  static const idPrefix = 'local-file-';
  static const _channel = MethodChannel('org.moonfin/local_files');

  /// Phones and tablets, iOS and Android, where the native side (picker,
  /// lasting access, track probe) exists. Not televisions: their file
  /// browsers are no use with a remote.
  static bool get isSupported =>
      !kIsWeb &&
      PlatformDetection.isMobile &&
      !PlatformDetection.isAppleTV;

  /// Android reads a file's tracks with the Media3 player's own extractors,
  /// so the probe sees them in the order the player will.
  static const _androidProbe = MethodChannel('moonfin/media3_probe');

  /// Set while a local file plays with no server signed in, so the router
  /// lets the player open for it.
  static bool signedOutPlayback = false;

  static bool isLocalFileId(String? id) =>
      id != null && id.startsWith(idPrefix);

  static bool isLocalFileItem(dynamic item) {
    try {
      if (item is AggregatedItem) return isLocalFileId(item.id);
      if (item is Map) return isLocalFileId(item['Id']?.toString());
    } catch (_) {}
    return false;
  }

  final List<LocalFile> _files = [];
  final _incoming = StreamController<List<LocalFile>>.broadcast();
  Future<void>? _loading;
  File? _store;

  LocalFileLibrary() {
    if (isSupported) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'incoming') await _takePending();
      });
    }
  }

  List<LocalFile> get files => List.unmodifiable(_files);

  /// Files the system handed over ("Open in"), already added to the library.
  Stream<List<LocalFile>> get incoming => _incoming.stream;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (!isSupported) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _store = File('${dir.path}/Moonfin/local_files.json');
      if (await _store!.exists()) {
        final list = jsonDecode(await _store!.readAsString()) as List;
        _files
          ..clear()
          ..addAll(
            list
                .map((e) => LocalFile.fromJson((e as Map).cast()))
                .whereType<LocalFile>(),
          );
        _sort();
      }
    } catch (e) {
      debugPrint('[LocalFiles] load failed: $e');
    }
    notifyListeners();
  }

  /// Asks for files the system handed over while Dart wasn't listening (a
  /// cold start from Files).
  Future<void> checkPending() async {
    if (!isSupported) return;
    await load();
    await _takePending();
  }

  Future<void> _takePending() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('takePending');
      final added = await _addAll(raw ?? const []);
      if (added.isNotEmpty) _incoming.add(added);
    } catch (e) {
      debugPrint('[LocalFiles] takePending failed: $e');
    }
  }

  /// Opens the system file browser. Returns the files picked, already added.
  Future<List<LocalFile>> pick() async {
    if (!isSupported) return const [];
    await load();
    final raw = await _channel.invokeListMethod<Map>('pick');
    return _addAll(raw ?? const []);
  }

  Future<List<LocalFile>> _addAll(List<Map> raw) async {
    await load();
    final added = <LocalFile>[];
    for (final entry in raw) {
      final map = entry.cast<String, dynamic>();
      final bookmark = map['bookmark'];
      final name = map['name'] as String?;
      if (bookmark is! Uint8List || name == null) continue;
      final size = (map['size'] as num?)?.toInt() ?? 0;
      // The same file picked again keeps its place and its resume point.
      final existing = _files.indexWhere(
        (f) => f.name == name && f.size == size,
      );
      final LocalFile file;
      if (existing >= 0) {
        file = _files.removeAt(existing).copyWith(bookmark: bookmark);
      } else {
        file = LocalFile(
          id: '$idPrefix${DateTime.now().microsecondsSinceEpoch}-${added.length}',
          name: name,
          bookmark: bookmark,
          size: size,
          owned: map['owned'] as bool? ?? false,
          addedAt: DateTime.now(),
        );
      }
      _files.insert(0, file);
      added.add(file);
    }
    if (added.isNotEmpty) {
      _sort();
      await _save();
      notifyListeners();
    }
    return added;
  }

  LocalFile? byId(String id) {
    for (final f in _files) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Turns the file's bookmark back into a path and reads its tracks the
  /// first time. Null when the file is gone or can't be reached (a drive
  /// that was unplugged).
  Future<OpenedLocalFile?> open(String id) async {
    await load();
    final found = byId(id);
    if (found == null) return null;
    var file = found;
    final opened = await _channel.invokeMapMethod<String, dynamic>('open', {
      'bookmark': file.bookmark,
    });
    final path = opened?['path'] as String?;
    if (path == null) return null;
    final fresh = opened?['bookmark'];
    if (fresh is Uint8List) file = file.copyWith(bookmark: fresh);
    if (file.mediaStreams == null) {
      try {
        final probed = PlatformDetection.isAndroid
            ? await _androidProbe.invokeMapMethod<String, dynamic>('probe', {
                'url': path,
              })
            : await _channel.invokeMapMethod<String, dynamic>('probe', {
                'path': path,
              });
        if (probed != null) {
          file = file.copyWith(
            mediaStreams: (probed['MediaStreams'] as List?)
                ?.map((s) => (s as Map).cast<String, dynamic>())
                .toList(),
            runTimeTicks: (probed['RunTimeTicks'] as num?)?.toInt(),
          );
        }
      } catch (e) {
        debugPrint('[LocalFiles] probe failed: $e');
      }
    }
    _replace(file.copyWith(lastPlayedAt: DateTime.now()));
    _sort();
    await _save();
    notifyListeners();
    return OpenedLocalFile(byId(id)!, path);
  }

  Future<void> release(String path) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('release', {'path': path});
    } catch (_) {}
  }

  /// Where playback was left. Saved at most every few seconds by the player's
  /// progress reports, and on stop.
  Future<void> updatePosition(String id, int positionTicks) async {
    final file = byId(id);
    if (file == null) return;
    // Within the last few minutes counts as finished, as on a server.
    final total = file.runTimeTicks ?? 0;
    final finished = total > 0 && positionTicks >= total * 0.92;
    _replace(file.copyWith(positionTicks: finished ? 0 : positionTicks));
    await _save();
    notifyListeners();
  }

  /// Takes the file off the list. The file itself is left alone, unless it
  /// was the app's own copy.
  Future<void> remove(String id) async {
    final index = _files.indexWhere((f) => f.id == id);
    if (index < 0) return;
    final file = _files.removeAt(index);
    await _save();
    notifyListeners();
    // Android keeps a lasting read grant per picked file; give it back.
    try {
      await _channel.invokeMethod('forget', {'bookmark': file.bookmark});
    } catch (_) {}
    if (!file.owned) return;
    try {
      final opened = await _channel.invokeMapMethod<String, dynamic>('open', {
        'bookmark': file.bookmark,
      });
      final path = opened?['path'] as String?;
      if (path != null) {
        await release(path);
        await File(path).delete();
      }
    } catch (_) {}
  }

  /// The item the player and the rest of the app see for [file].
  AggregatedItem itemFor(LocalFile file, {String serverId = ''}) {
    return AggregatedItem(
      id: file.id,
      serverId: serverId,
      rawData: {
        'Id': file.id,
        'Name': file.title,
        // Jellyfin's type for a home video: not a Movie, so no rule written
        // for films and episodes (remove watched, next up) applies to it.
        'Type': 'Video',
        'MediaType': 'Video',
        'IsFolder': false,
        'LocationType': 'FileSystem',
        'ImageTags': const <String, dynamic>{},
        'RunTimeTicks': ?file.runTimeTicks,
        'UserData': {
          'PlaybackPositionTicks': file.positionTicks,
          'Played': false,
        },
        'MediaSources': [
          {
            'Id': file.id,
            'Name': file.title,
            'Protocol': 'File',
            'Size': file.size,
            'MediaStreams': file.mediaStreams ?? const [],
            'RunTimeTicks': ?file.runTimeTicks,
          },
        ],
        'MediaStreams': file.mediaStreams ?? const [],
      },
    );
  }

  void _replace(LocalFile file) {
    final index = _files.indexWhere((f) => f.id == file.id);
    if (index >= 0) _files[index] = file;
  }

  void _sort() {
    DateTime recency(LocalFile f) => f.lastPlayedAt ?? f.addedAt;
    _files.sort((a, b) => recency(b).compareTo(recency(a)));
  }

  Future<void> _save() async {
    final store = _store;
    if (store == null) return;
    try {
      await store.parent.create(recursive: true);
      final temp = File('${store.path}.part');
      await temp.writeAsString(
        jsonEncode([for (final f in _files) f.toJson()]),
      );
      await temp.rename(store.path);
    } catch (e) {
      debugPrint('[LocalFiles] save failed: $e');
    }
  }
}
