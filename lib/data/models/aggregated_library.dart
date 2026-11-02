class AggregatedLibrary {
  final String id;
  final String name;
  final String collectionType;
  final String serverId;
  final double? primaryImageAspectRatio;
  final Map<String, dynamic>? imageTags;
  final List<String>? backdropImageTags;

  /// Lambent Server's own kind for the library (`movies`, `tvshows`,
  /// `homevideos`, `folders`), which tells libraries apart that Jellyfin's
  /// CollectionType files under one kind.
  final String? lambentKind;

  const AggregatedLibrary({
    required this.id,
    required this.name,
    required this.collectionType,
    required this.serverId,
    this.primaryImageAspectRatio,
    this.imageTags,
    this.backdropImageTags,
    this.lambentKind,
  });
}
