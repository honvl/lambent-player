import Flutter
import GameController
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
    private var sfSymbolChannel: AppleTvSfSymbolChannel?
    private var gameChannel: AppleTvGameChannel?

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
        sfSymbolChannel = AppleTvSfSymbolChannel(
            messenger: flutterViewController.binaryMessenger)
        gameChannel = AppleTvGameChannel(
            messenger: flutterViewController.binaryMessenger,
            textures: flutterViewController,
            rootViewController: flutterViewController)

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
