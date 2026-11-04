/// Lambent Server's Jellyfin server ids start with "lamb" in hex (Lambent's
/// `jellyfin::dto::server_id`), so a title says where it came from without
/// asking the server.
const _lambentServerIdPrefix = '6c616d62';

/// Whether [serverId] (an item's `ServerId`) is a Lambent Server's.
bool isLambentServerId(String? serverId) =>
    serverId != null &&
    serverId.toLowerCase().startsWith(_lambentServerIdPrefix);
