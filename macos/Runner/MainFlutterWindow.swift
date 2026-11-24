import Cocoa
import FlutterMacOS

/// Keeps Intel Macs on Skia. Impeller became the macOS default in Flutter 3.47
/// and garbles text, flickers and lags on Intel GPUs (flutter/flutter#191538).
/// enableImpeller is a private FlutterDartProject getter, but it's the only
/// per-architecture switch since the FLTEnableImpeller plist key applies to
/// every Mac and release builds ignore engine switches.
final class MoonfinDartProject: FlutterDartProject {
  /// The engine looks for icudtl.dat in the bundle of [self class], which is
  /// the app bundle once subclassed. Without ICU data, text wraps mid-word.
  @objc var ICUDataPath: String? {
    Bundle(for: FlutterDartProject.self).path(forResource: "icudtl", ofType: "dat")
  }

  #if arch(x86_64)
  @objc var enableImpeller: Bool { false }
  #endif
}

class MainFlutterWindow: NSWindow {
  private var sfSymbolChannel: FlutterMethodChannel?
  private var downloadDirChannel: FlutterMethodChannel?
  private var aetherVideoChannel: AetherVideoChannel?
  private var themeMusicChannel: AppleTvThemeMusicChannel?
  private var arcadeSoundChannel: AppleArcadeSoundChannel?
  private var previewChannel: AppleTvPreviewChannel?
  private var bonjourChannel: BonjourChannel?
  // Retained so the security-scoped access stays open for the session.
  private var accessedDownloadURL: URL?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController(project: MoonfinDartProject())
    let minimumWindowSize = NSSize(width: 1200, height: 760)
    self.minSize = minimumWindowSize

    var windowFrame = self.frame
    if windowFrame.size.width < minimumWindowSize.width ||
      windowFrame.size.height < minimumWindowSize.height {
      if let visibleFrame = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
        windowFrame.size.width = min(max(windowFrame.size.width, minimumWindowSize.width), visibleFrame.width)
        windowFrame.size.height = min(max(windowFrame.size.height, minimumWindowSize.height), visibleFrame.height)
        windowFrame.origin.x = visibleFrame.midX - (windowFrame.size.width / 2)
        windowFrame.origin.y = visibleFrame.midY - (windowFrame.size.height / 2)
      } else {
        windowFrame.size.width = max(windowFrame.size.width, minimumWindowSize.width)
        windowFrame.size.height = max(windowFrame.size.height, minimumWindowSize.height)
      }
    }

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.backgroundColor = NSColor(white: 0.04, alpha: 1.0)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let sfSymbolChannel = FlutterMethodChannel(
      name: "moonfin/sf_symbols",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.sfSymbolChannel = sfSymbolChannel
    sfSymbolChannel.setMethodCallHandler { (call, result) in
      guard call.method == "render",
        let args = call.arguments as? [String: Any],
        let name = args["name"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard #available(macOS 12.0, *) else {
        result(nil)
        return
      }
      let size = CGFloat(args["size"] as? Double ?? 18)
      let color = NSColor(
        red: CGFloat(args["r"] as? Double ?? 1),
        green: CGFloat(args["g"] as? Double ?? 1),
        blue: CGFloat(args["b"] as? Double ?? 1),
        alpha: CGFloat(args["a"] as? Double ?? 1)
      )
      let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
      guard
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
        let configured = symbol.withSymbolConfiguration(config)
      else {
        result(nil)
        return
      }
      let imageSize = configured.size
      let output = NSImage(size: imageSize)
      output.lockFocus()
      configured.draw(in: NSRect(origin: .zero, size: imageSize))
      color.set()
      NSRect(origin: .zero, size: imageSize).fill(using: .sourceAtop)
      output.unlockFocus()
      guard let tiff = output.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: png))
    }

    let downloadDirChannel = FlutterMethodChannel(
      name: "moonfin/macos_download_dir",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.downloadDirChannel = downloadDirChannel
    downloadDirChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "pickDirectory":
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          do {
            let data = try url.bookmarkData(
              options: .withSecurityScope,
              includingResourceValuesForKeys: nil,
              relativeTo: nil
            )
            result([
              "path": url.path,
              "bookmark": data.base64EncodedString(),
            ])
          } catch {
            result(
              FlutterError(
                code: "bookmark_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      case "startAccess":
        guard let args = call.arguments as? [String: Any],
          let b64 = args["bookmark"] as? String,
          let data = Data(base64Encoded: b64)
        else {
          result(nil)
          return
        }
        do {
          var stale = false
          let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
          )
          _ = url.startAccessingSecurityScopedResource()
          self?.accessedDownloadURL = url
          var response: [String: Any] = ["path": url.path]
          if stale,
            let fresh = try? url.bookmarkData(
              options: .withSecurityScope,
              includingResourceValuesForKeys: nil,
              relativeTo: nil
            )
          {
            response["bookmark"] = fresh.base64EncodedString()
          }
          result(response)
        } catch {
          result(
            FlutterError(
              code: "resolve_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // AetherEngine playback: control/event channels plus the AppKitView video
    // surface factory. Same channel names as iOS, so the Dart backend is
    // shared unchanged.
    let messenger = flutterViewController.engine.binaryMessenger
    let aetherChannel = AetherVideoChannel(messenger: messenger)
    self.aetherVideoChannel = aetherChannel
    let aetherRegistrar = flutterViewController.registrar(forPlugin: "moonfin_aether_video")
    aetherRegistrar.register(
      MacosAetherVideoViewFactory(
        messenger: messenger,
        wrapperProvider: { [weak aetherChannel] in
          aetherChannel?.player ?? AetherPlayerWrapper()
        }),
      withId: MacosAetherVideoViewFactory.viewType)

    // Trailers, row previews and theme music, on the same channels the other
    // Apple platforms use.
    self.themeMusicChannel = AppleTvThemeMusicChannel(messenger: messenger)
    self.arcadeSoundChannel = AppleArcadeSoundChannel(messenger: messenger)
    let previewRegistrar = flutterViewController.registrar(forPlugin: "moonfin_appletv_preview")
    self.previewChannel = AppleTvPreviewChannel(
      messenger: messenger, textures: previewRegistrar.textures)

    // Finding Lambent Server on the local network (server_discovery_service_io.dart).
    self.bonjourChannel = BonjourChannel(messenger: messenger)

    super.awakeFromNib()
  }
}

/// Bonjour browsing for Dart's server discovery, as on iOS (ios/Runner/AppDelegate.swift).
/// The multicast_dns package binds its own UDP socket, which the App Sandbox
/// refuses without com.apple.security.network.server, an entitlement App Review
/// rejects for an app that runs no server (guideline 2.4.5); the system's
/// Bonjour needs only the service type in NSBonjourServices. `browse` collects
/// what resolves within the timeout: name, IPv4 host, port and TXT fields.
final class BonjourChannel: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let channel: FlutterMethodChannel
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var found: [String: [String: Any]] = [:]
    private var pending: FlutterResult?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "org.moonfin/bonjour", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "browse",
            let args = call.arguments as? [String: Any],
            let type = args["type"] as? String
        else {
            result(FlutterMethodNotImplemented)
            return
        }
        // One browse at a time; a second caller gets what the first finds.
        if pending != nil {
            result([])
            return
        }
        pending = result
        found = [:]
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: type.hasSuffix(".") ? type : type + ".", inDomain: "local.")
        let seconds = Double(args["timeoutMs"] as? Int ?? 2000) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
    }

    private func finish() {
        browser?.stop()
        browser = nil
        resolving.forEach { $0.stop() }
        resolving = []
        pending?(Array(found.values))
        pending = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = Self.ipv4(of: sender) else { return }
        var txt: [String: String] = [:]
        if let record = sender.txtRecordData() {
            for (key, value) in NetService.dictionary(fromTXTRecord: record) {
                txt[key] = String(data: value, encoding: .utf8)
            }
        }
        found[sender.name] = ["name": sender.name, "host": host, "port": sender.port, "txt": txt]
    }

    private static func ipv4(of service: NetService) -> String? {
        for address in service.addresses ?? [] {
            let host: String? = address.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr_in>.size,
                    raw.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET)
                else { return nil }
                var addr = raw.load(as: sockaddr_in.self).sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let host { return host }
        }
        return nil
    }
}
