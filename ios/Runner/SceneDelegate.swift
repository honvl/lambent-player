import Flutter
import UIKit

/// Shows in any extra window scene: the single shared FlutterEngine can only
/// render into one window at a time (multiple scenes are enabled for CarPlay,
/// which also enables iPad multi-window).
private final class SecondaryWindowViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let label = UILabel()
    label.text = "Moonfin is already open in another window"
    label.textColor = .secondaryLabel
    label.font = .preferredFont(forTextStyle: .body)
    label.numberOfLines = 0
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])
  }
}

class SceneDelegate: FlutterSceneDelegate {
  private var registeredEngine: FlutterEngine?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate
    else {
      super.scene(scene, willConnectTo: session, options: connectionOptions)
      return
    }

    appDelegate.startEngineIfNeeded()
    let engine = appDelegate.sharedEngine

    let newWindow = UIWindow(windowScene: windowScene)
    if let attached = engine.viewController,
      attached.viewIfLoaded?.window != nil,
      attached.viewIfLoaded?.window?.windowScene !== windowScene
    {
      newWindow.rootViewController = SecondaryWindowViewController()
    } else {
      // Detach any view controller left over from a disconnected scene before
      // attaching a fresh one.
      engine.viewController = nil
      newWindow.rootViewController = FlutterViewController(
        engine: engine, nibName: nil, bundle: nil)
      // With multiple scenes enabled, Flutter cannot associate the engine with
      // the scene during the connection phase on its own; without this, launch
      // connection options (deep links, shortcuts) never reach plugins.
      registerSceneLifeCycle(with: engine)
      registeredEngine = engine
    }
    window = newWindow
    newWindow.makeKeyAndVisible()

    // A cold start from Files' "Open in" carries the file here rather than in
    // openURLContexts.
    receiveFiles(connectionOptions.urlContexts, appDelegate: appDelegate)

    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let appDelegate = UIApplication.shared.delegate as? AppDelegate
    let links = receiveFiles(URLContexts, appDelegate: appDelegate)
    if !links.isEmpty { super.scene(scene, openURLContexts: links) }
  }

  /// Hands video files to the local files channel and returns the other
  /// contexts (app links), which go on to the plugins.
  @discardableResult
  private func receiveFiles(
    _ contexts: Set<UIOpenURLContext>, appDelegate: AppDelegate?
  ) -> Set<UIOpenURLContext> {
    var links = Set<UIOpenURLContext>()
    for context in contexts {
      if context.url.isFileURL, let files = appDelegate?.localFileChannel {
        files.receive(context.url, inPlace: context.options.openInPlace)
      } else {
        links.insert(context)
      }
    }
    return links
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    (UIApplication.shared.delegate as? AppDelegate)?.downloadKeepAlive?.appBecameActive()
    super.sceneDidBecomeActive(scene)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    (UIApplication.shared.delegate as? AppDelegate)?.downloadKeepAlive?.appEnteredBackground()
    // Each background is a chance to (re)submit the auto-download refresh
    // request; a pending one with the same identifier is simply replaced.
    (UIApplication.shared.delegate as? AppDelegate)?.backgroundRefresh?.scheduleNextIfEnabled()
    super.sceneDidEnterBackground(scene)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    if let engine = registeredEngine {
      unregisterSceneLifeCycle(with: engine)
      registeredEngine = nil
      if engine.viewController === window?.rootViewController {
        engine.viewController = nil
      }
    }
    super.sceneDidDisconnect(scene)
  }
}
