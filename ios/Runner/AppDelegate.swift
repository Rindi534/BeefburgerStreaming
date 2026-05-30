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

    // Register our hand-written AVPlayer bridge alongside the
    // generated Flutter plugins. It registers a UiKitView factory
    // that Dart spawns via `UiKitView(viewType: "beefburger/native_player")`.
    if let registrar = engineBridge.pluginRegistry
        .registrar(forPlugin: "NativePlayerPlugin") {
      NativePlayerPlugin.register(with: registrar)
    }

    // Second video backend: MobileVLCKit-based player for container/
    // codec combinations that AVPlayer can't decode (.mkv, .avi, …).
    // Registered under a distinct viewType — Dart picks the right one
    // based on file extension. Two factories coexist peacefully because
    // each owns its own MethodChannel namespace.
    if let registrar = engineBridge.pluginRegistry
        .registrar(forPlugin: "VLCPlayerPlugin") {
      VLCPlayerPlugin.register(with: registrar)
    }
  }
}
