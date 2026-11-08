import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "YamsHubLinks") {
      IncomingLinksPlugin.register(with: registrar)
    }
  }
}

/// Hands URLs opened with the app (magnet:) to Dart over `dev.zenith.yams_hub/links`
/// (ARCHITECTURE §7.11). Dart asks for the launch link with `getInitialLink` and
/// receives later ones through `onLink`. Kept in this file so the Xcode project needs
/// no extra source entry.
final class IncomingLinksPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private let channel: FlutterMethodChannel
  private var initialLink: String?
  private var dartAskedForInitialLink = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.zenith.yams_hub/links", binaryMessenger: registrar.messenger())
    let instance = IncomingLinksPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getInitialLink":
      dartAskedForInitialLink = true
      result(initialLink)
      initialLink = nil
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func deliver(_ url: URL) {
    let link = url.absoluteString
    if dartAskedForInitialLink {
      channel.invokeMethod("onLink", arguments: link)
    } else {
      initialLink = link
    }
  }

  // Cold start through a scene.
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let url = connectionOptions?.urlContexts.first?.url {
      deliver(url)
      return true
    }
    return false
  }

  // Warm start through a scene.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    guard let url = URLContexts.first?.url else { return false }
    deliver(url)
    return true
  }

  // Fallback when no scene is used.
  func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    deliver(url)
    return true
  }
}
