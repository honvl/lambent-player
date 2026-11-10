import Flutter
import GameController
import TVServices
import UIKit

/// Hosts the Flutter view so a game controller can be kept away from the UI.
///
/// The one switch tvOS offers is this view controller's
/// `controllerUserInteractionEnabled`, honored for whatever sits in its
/// responder chain, so it has to be an ancestor of the Flutter view rather
/// than a sibling. Off routes controller input to the GameController profiles
/// instead of the responder chain, and that covers more devices than a
/// gamepad: the Siri Remote is a microGamepad, a paired keyboard is a
/// GCKeyboard, and a third party remote reaches tvOS as one or the other. It
/// therefore starts on, matching the Apple TV preference default, until Dart
/// sends the stored value.
final class GamepadNavigationHostViewController: GCEventViewController {
    let flutterViewController: FlutterViewController

    init(flutterViewController: FlutterViewController) {
        self.flutterViewController = flutterViewController
        super.init(nibName: nil, bundle: nil)
        controllerUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(flutterViewController)
        flutterViewController.view.frame = view.bounds
        flutterViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(flutterViewController.view)
        flutterViewController.didMove(toParent: self)
    }
}

@main
class AppDelegate: FlutterAppDelegate {
    /// The root the scene's window shows, made at launch with the channels it
    /// carries; the window itself comes with the scene (SceneDelegate).
    fileprivate var gamepadHost: GamepadNavigationHostViewController?
    private var nativeApplePlayerChannel: NativeApplePlayerChannel?
    private var aetherVideoChannel: AetherVideoChannel?
    private var topShelfChannel: TopShelfChannel?
    private var previewChannel: AppleTvPreviewChannel?
    private var systemChannel: AppleTvSystemChannel?
    private var audioChannel: AppleTvAudioChannel?
    private var themeMusicChannel: AppleTvThemeMusicChannel?
    private var arcadeSoundChannel: AppleArcadeSoundChannel?
    private var sfSymbolChannel: AppleTvSfSymbolChannel?
    private var gameChannel: AppleTvGameChannel?
    private var bonjourChannel: AppleTvBonjourChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let flutterViewController = FlutterViewController(project: nil, nibName: nil, bundle: nil)
        let gamepadHost = GamepadNavigationHostViewController(
            flutterViewController: flutterViewController)
        self.gamepadHost = gamepadHost

        // FlutterAppDelegate only hands out registrars when the window's root
        // is a FlutterViewController, and the host sits there now, so plugins
        // register against the controller directly.
        GeneratedPluginRegistrant.register(with: flutterViewController)

        nativeApplePlayerChannel = NativeApplePlayerChannel(
            messenger: flutterViewController.binaryMessenger,
            textures: flutterViewController,
            rootProvider: { [weak flutterViewController] in flutterViewController })
        // The Flutter player option draws its own controls over this video view.
        let aetherChannel = AetherVideoChannel(messenger: flutterViewController.binaryMessenger)
        aetherVideoChannel = aetherChannel
        flutterViewController.registrar(forPlugin: "moonfin_aether_video")?.register(
            AetherVideoViewFactory(
                messenger: flutterViewController.binaryMessenger,
                wrapperProvider: { [weak aetherChannel] in
                    aetherChannel?.player ?? AetherPlayerWrapper()
                }),
            withId: AetherVideoViewFactory.viewType)
        topShelfChannel = TopShelfChannel(
            messenger: flutterViewController.binaryMessenger)
        previewChannel = AppleTvPreviewChannel(
            messenger: flutterViewController.binaryMessenger,
            textures: flutterViewController)
        systemChannel = AppleTvSystemChannel(
            messenger: flutterViewController.binaryMessenger,
            gamepadHost: gamepadHost)
        audioChannel = AppleTvAudioChannel(
            messenger: flutterViewController.binaryMessenger)
        themeMusicChannel = AppleTvThemeMusicChannel(
            messenger: flutterViewController.binaryMessenger)
        arcadeSoundChannel = AppleArcadeSoundChannel(
            messenger: flutterViewController.binaryMessenger)
        sfSymbolChannel = AppleTvSfSymbolChannel(
            messenger: flutterViewController.binaryMessenger)
        gameChannel = AppleTvGameChannel(
            messenger: flutterViewController.binaryMessenger,
            textures: flutterViewController,
            rootViewController: flutterViewController)

        bonjourChannel = AppleTvBonjourChannel(
            messenger: flutterViewController.binaryMessenger)

        if let launchUrl = launchOptions?[.url] as? URL {
            topShelfChannel?.deliverDeepLink(launchUrl, isLaunch: true)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        topShelfChannel?.deliverDeepLink(url, isLaunch: false)
        return true
    }

    /// A remote's Guide button, which only the Live TV player acts on.
    override func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == TVUserActivityTypeBrowsingChannelGuide else {
            return super.application(
                application, continue: userActivity, restorationHandler: restorationHandler)
        }
        handleGuideButton()
        return true
    }

    /// The Guide button, from the scene or the app.
    fileprivate func handleGuideButton() {
        nativeApplePlayerChannel?.handleGuideButton()
    }

    fileprivate func deliverDeepLink(_ url: URL, isLaunch: Bool) {
        topShelfChannel?.deliverDeepLink(url, isLaunch: isLaunch)
    }
}

/// The app's one window scene. Apps built with the tvOS 27 SDK must adopt the
/// scene life cycle or they are refused at launch, so the window the app
/// delegate used to make is made here, around the root it already set up, and
/// Top Shelf deep links that now arrive through the scene are handed on.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
            let appDelegate = UIApplication.shared.delegate as? AppDelegate,
            let root = appDelegate.gamepadHost
        else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        appDelegate.window = window
        if let url = connectionOptions.urlContexts.first?.url {
            appDelegate.deliverDeepLink(url, isLaunch: true)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url,
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
        else { return }
        appDelegate.deliverDeepLink(url, isLaunch: false)
    }

    // A scene app gets the remote's Guide button here, not at the app delegate.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == TVUserActivityTypeBrowsingChannelGuide,
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
        else { return }
        appDelegate.handleGuideButton()
    }
}

/// Bonjour browsing for Dart's server discovery. The multicast_dns package
/// sends its own multicast packets, which tvOS only allows an app holding
/// Apple's multicast entitlement; the system's Bonjour needs only the service
/// type in NSBonjourServices. `browse` collects what resolves within the
/// timeout: name, IPv4 host, port and TXT fields.
final class AppleTvBonjourChannel: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
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

@MainActor
final class AppleTvSfSymbolChannel: NSObject {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "moonfin/sf_symbols", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "render",
            let args = call.arguments as? [String: Any],
            let name = args["name"] as? String
        else {
            result(FlutterMethodNotImplemented)
            return
        }
        let size = CGFloat(args["size"] as? Double ?? 18)
        let scale = CGFloat(args["scale"] as? Double ?? 2)
        let color = UIColor(
            red: CGFloat(args["r"] as? Double ?? 1),
            green: CGFloat(args["g"] as? Double ?? 1),
            blue: CGFloat(args["b"] as? Double ?? 1),
            alpha: CGFloat(args["a"] as? Double ?? 1))
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else {
            result(nil)
            return
        }
        let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: tinted.size, format: format)
        let data = renderer.pngData { _ in tinted.draw(at: .zero) }
        result(FlutterStandardTypedData(bytes: data))
    }
}
