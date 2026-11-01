/// The scores Lambent Server sends with a title (`LambentScores`, from Plex's agent): IMDb's, TMDB's and Rotten Tomatoes', keyed
/// the way [RatingsRow] names its sources. TMDB's keeps Plex's 0-10 (the `tmdb_episode` slot) so it reads "7.3" as in Plex;
/// Rotten Tomatoes' are percentages. Empty for any other server.
Map<String, double> serverScores(Map<String, dynamic> raw) {
  final list = raw['LambentScores'];
  if (list is! List) return const {};
  final scores = <String, double>{};
  for (final entry in list.whereType<Map>()) {
    final value = (entry['Value'] as num?)?.toDouble();
    if (value == null || value <= 0) continue;
    final critic = entry['Kind'] == 'critic';
    switch (entry['Source']) {
      case 'imdb':
        scores['imdb'] = value;
      case 'themoviedb':
        scores['tmdb_episode'] = value;
      case 'rottentomatoes':
        scores[critic ? 'tomatoes' : 'tomatoes_audience'] = value * 10;
    }
  }
  return scores;
}

/// Whether [raw] came with Lambent Server's scores, which then stand in for the community star.
bool hasServerScores(Map<String, dynamic> raw) => raw['LambentScores'] is List;
