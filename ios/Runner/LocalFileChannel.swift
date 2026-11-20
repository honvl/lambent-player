import AetherEngine
import Flutter
import UIKit
import UniformTypeIdentifiers

/// Video files that live on this device, outside the app's own downloads: picked in the system file
/// browser, or handed over with "Open in" from Files or the share sheet.
///
/// A file stays where it is. The app keeps a security-scoped bookmark to it, so a film on iCloud Drive or
/// a USB drive plays in place instead of being copied into the app first, and can be opened again later
/// from the list. `open` turns a bookmark back into a path and holds access to it until `release`.
///
/// The channel also reads a file's tracks with AetherEngine's probe, in the shape a Jellyfin item's
/// `MediaStreams` has, so the player's audio and subtitle pickers work as they do for a server item.
final class LocalFileChannel: NSObject, UIDocumentPickerDelegate {
  static let name = "org.moonfin/local_files"

  private let channel: FlutterMethodChannel
  private let rootProvider: () -> UIViewController?
  private var pickResult: FlutterResult?
  /// Files the system handed over before Dart asked for them.
  private var pending: [[String: Any]] = []
  /// Paths with security-scoped access held open, by path.
  private var held: [String: URL] = [:]

  init(messenger: FlutterBinaryMessenger, rootProvider: @escaping () -> UIViewController?) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    self.rootProvider = rootProvider
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "pick":
      pick(result: result)
    case "open":
      guard let data = args?["bookmark"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "args", message: "bookmark missing", details: nil))
        return
      }
      result(open(bookmark: data.data))
    case "release":
      if let path = args?["path"] as? String { release(path: path) }
      result(nil)
    case "probe":
      guard let path = args?["path"] as? String else {
        result(FlutterError(code: "args", message: "path missing", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let probed = Self.probe(path: path)
        DispatchQueue.main.async { result(probed) }
      }
    case "takePending":
      let files = pending
      pending.removeAll()
      result(files)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Picking

  /// What the picker offers: every movie type the system knows, plus the containers it has no type
  /// for (Matroska above all), which still match by extension.
  static var contentTypes: [UTType] {
    var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .mpeg2Video, .avi]
    for ext in ["mkv", "mk3d", "webm", "ts", "m2ts", "mts", "m4v", "wmv", "asf", "flv", "ogv", "vob", "rmvb", "3gp"] {
      if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
    }
    return types
  }

  private func pick(result: @escaping FlutterResult) {
    guard pickResult == nil else {
      result(FlutterError(code: "busy", message: "a picker is already open", details: nil))
      return
    }
    guard let root = rootProvider() else {
      result(FlutterError(code: "no_view", message: "nothing to present the picker from", details: nil))
      return
    }
    var presenter = root
    while let presented = presenter.presentedViewController { presenter = presented }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: false)
    // One file: a tap on it opens it, with no separate Open button to find.
    picker.allowsMultipleSelection = false
    picker.delegate = self
    pickResult = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let files = urls.compactMap { Self.describe($0, inPlace: true) }
    pickResult?(files)
    pickResult = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickResult?([])
    pickResult = nil
  }

  // MARK: - Open in

  /// A file the system handed over (Files' "Open in", the share sheet, AirDrop). `inPlace` is false
  /// when the system copied it into the app's Inbox, which the app then owns.
  func receive(_ url: URL, inPlace: Bool) {
    guard url.isFileURL, let file = Self.describe(url, inPlace: inPlace) else { return }
    pending.append(file)
    channel.invokeMethod("incoming", arguments: nil)
  }

  /// The bookmark, name and size of a file, read while access to it is held.
  private static func describe(_ url: URL, inPlace: Bool) -> [String: Any]? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    else { return nil }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
    let size = values?.totalFileSize ?? values?.fileSize ?? 0
    return [
      "bookmark": FlutterStandardTypedData(bytes: bookmark),
      "name": url.lastPathComponent,
      "path": url.path,
      "size": size,
      "owned": !inPlace,
    ]
  }

  // MARK: - Access

  private func open(bookmark: Data) -> [String: Any]? {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    else { return nil }
    let path = url.path
    if held[path] == nil {
      // False for a file inside the app's own container, which needs no scope.
      if url.startAccessingSecurityScopedResource() { held[path] = url }
    }
    guard FileManager.default.isReadableFile(atPath: path) else {
      release(path: path)
      return nil
    }
    var opened: [String: Any] = ["path": path]
    if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      opened["bookmark"] = FlutterStandardTypedData(bytes: fresh)
    }
    return opened
  }

  private func release(path: String) {
    held.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
  }

  // MARK: - Probe

  /// The file's streams as Jellyfin `MediaStreams`, indexed by FFmpeg stream index (Jellyfin's own
  /// index for a direct play), with its run time in ticks. Nil when the file can't be read.
  static func probe(path: String) -> [String: Any]? {
    let url = URL(fileURLWithPath: path)
    guard let probe = try? AetherEngine.probe(url: url) else { return nil }
    var streams: [[String: Any]] = []
    let used = Set(probe.audioTracks.map(\.id) + probe.subtitleTracks.map(\.id))
    // The probe reports no index for the picture; it is the first one no other track holds, which is
    // stream 0 in nearly every file.
    var videoIndex = 0
    while used.contains(videoIndex) { videoIndex += 1 }
    if probe.videoWidth > 0 {
      var video: [String: Any] = [
        "Index": videoIndex,
        "Type": "Video",
        "Codec": probe.videoCodecName ?? "",
        "Width": Int(probe.videoWidth),
        "Height": Int(probe.videoHeight),
        "IsDefault": true,
        "IsExternal": false,
      ]
      let (range, rangeType) = videoRange(probe.videoFormat)
      video["VideoRange"] = range
      video["VideoRangeType"] = rangeType
      if let fps = probe.videoFrameRate, fps > 0 {
        video["RealFrameRate"] = fps
        video["AverageFrameRate"] = fps
      }
      video["DisplayTitle"] = videoTitle(probe, rangeType: rangeType)
      streams.append(video)
    }
    for track in probe.audioTracks {
      var audio = common(track, type: "Audio")
      audio["Channels"] = track.channels
      if track.sampleRate > 0 { audio["SampleRate"] = track.sampleRate }
      if track.bitrate > 0 { audio["BitRate"] = Int(track.bitrate) }
      audio["DisplayTitle"] = displayTitle(track, detail: [track.codec.uppercased(), channelLabel(track.channels)])
      streams.append(audio)
    }
    for track in probe.subtitleTracks where !track.isExternal {
      var subtitle = common(track, type: "Subtitle")
      subtitle["IsTextSubtitleStream"] = textCodecs.contains(track.codec)
      subtitle["DeliveryMethod"] = "Embed"
      subtitle["DisplayTitle"] = displayTitle(track, detail: [track.codec.uppercased()])
      streams.append(subtitle)
    }
    var described: [String: Any] = ["MediaStreams": streams]
    if probe.durationSeconds.isFinite, probe.durationSeconds > 0 {
      described["RunTimeTicks"] = Int64(probe.durationSeconds * 10_000_000)
    }
    if let title = probe.metadata.title, !title.isEmpty { described["Title"] = title }
    return described
  }

  private static let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]

  private static func common(_ track: TrackInfo, type: String) -> [String: Any] {
    var stream: [String: Any] = [
      "Index": track.id,
      "Type": type,
      "Codec": track.codec,
      "IsDefault": track.isDefault,
      "IsForced": track.isForced,
      "IsHearingImpaired": track.isHearingImpaired,
      "IsExternal": false,
    ]
    if let language = track.language, !language.isEmpty, language != "und" { stream["Language"] = language }
    if !track.name.isEmpty { stream["Title"] = track.name }
    return stream
  }

  private static func displayTitle(_ track: TrackInfo, detail: [String]) -> String {
    let language = track.language.flatMap { $0 == "und" ? nil : Locale.current.localizedString(forLanguageCode: $0) }
    var parts = [language ?? (track.name.isEmpty ? nil : track.name)].compactMap { $0 }
    parts.append(contentsOf: detail.filter { !$0.isEmpty })
    if track.isForced { parts.append("Forced") }
    if track.isHearingImpaired { parts.append("SDH") }
    return parts.joined(separator: " - ")
  }

  private static func channelLabel(_ channels: Int) -> String {
    switch channels {
    case 0: return ""
    case 1: return "Mono"
    case 2: return "Stereo"
    case 6: return "5.1"
    case 8: return "7.1"
    default: return "\(channels)ch"
    }
  }

  private static func videoRange(_ format: VideoFormat) -> (String, String) {
    switch format {
    case .sdr: return ("SDR", "SDR")
    case .hdr10: return ("HDR", "HDR10")
    case .hdr10Plus: return ("HDR", "HDR10Plus")
    case .dolbyVision: return ("HDR", "DOVI")
    case .hlg: return ("HDR", "HLG")
    @unknown default: return ("SDR", "SDR")
    }
  }

  private static func videoTitle(_ probe: SourceProbe, rangeType: String) -> String {
    let height = Int(probe.videoHeight)
    let resolution: String
    switch height {
    case 2000...: resolution = "4K"
    case 1000...: resolution = "1080p"
    case 700...: resolution = "720p"
    default: resolution = "\(height)p"
    }
    return [resolution, rangeType == "SDR" ? nil : rangeType, probe.videoCodecName?.uppercased()]
      .compactMap { $0 }.joined(separator: " ")
  }
}
