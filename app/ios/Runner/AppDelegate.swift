import UIKit
import Flutter
import UserNotifications
import app_links
import NetworkExtension
import AppIntents

@main
// FlutterAppDelegate 本身已 conform UNUserNotificationCenterDelegate（这一点在它的
// public header 里看不出来，只有编译器知道），所以下面三个回调是 override 而不是新实现。
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var methodChannel: FlutterMethodChannel?
  private var appleRemindersChannel: FlutterMethodChannel?
  private var appleCalendarChannel: FlutterMethodChannel?
  private var speechChannel: FlutterMethodChannel?
  private var audioInputChannel: FlutterMethodChannel?
  private var pttKeepAliveChannel: FlutterMethodChannel?
  private var watchChannel: FlutterMethodChannel?
  private var soundcoreWifiChannel: FlutterMethodChannel?
  private var plaudWifiChannel: FlutterMethodChannel?
  private let plaudWifiService = PlaudWifiService()
  private let soundcoreWifiService = SoundcoreWifiService()
  private let appleRemindersService = AppleRemindersService()
  private let appleCalendarService = AppleCalendarService()
  private let speechRecognitionHandler = SpeechRecognitionHandler()
  private let audioInputService = AudioInputService()
  private let pttBackgroundService = PttBackgroundService()
  private let watchSessionService = WatchSessionService()

  private var notificationTitleOnKill: String?
  private var notificationBodyOnKill: String?

  // 见 takeOverNotificationCenterDelegate() 的注释：这两个是被我们接管前的两个 delegate。
  private var firebaseNotificationDelegate: UNUserNotificationCenterDelegate?
  private var awesomeNotificationDelegate: UNUserNotificationCenterDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Background Watch deliveries may launch without a UI scene. The native
    // inbox persists files before a Flutter channel is available.
    watchSessionService.activate()
    if #available(iOS 16.0, *) {
      MemorionWatchShortcuts.updateAppShortcutParameters()
    }
    soundcoreWifiService.removeStaleConfigurations()
    plaudWifiService.removeStaleConfiguration()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // UIScene creates the Flutter engine after application launch. Register native
  // services with that engine rather than force-unwrapping the old app window.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    PhoneRecordingShortcutBridge.shared.configure(messenger: messenger)

    // With UIScene, the notification center can still point to AppDelegate.
    // Use the published plugin directly; capturing self would recurse on taps.
    firebaseNotificationDelegate = engineBridge.pluginRegistry.valuePublished(byPlugin: "FLTFirebaseMessagingPlugin")
      as? UNUserNotificationCenterDelegate
    // Apple 要求 delegate 在本方法返回前设好，否则冷启动那次点击可能不投递，所以先接管一次…
    takeOverNotificationCenterDelegate()
    // Reclaim the delegate after other plugins finish their deferred setup.
    DispatchQueue.main.async { [weak self] in
      self?.takeOverNotificationCenterDelegate()
    }

    methodChannel = FlutterMethodChannel(name: "me.memorion.api/notifyOnKill", binaryMessenger: messenger)
    methodChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.handleMethodCall(call, result: result)
    }
    
    // Create Apple Reminders method channel
    appleRemindersChannel = FlutterMethodChannel(name: "me.memorion.api/apple_reminders", binaryMessenger: messenger)
    appleRemindersChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.handleAppleRemindersCall(call, result: result)
    }

    // Create Apple Calendar method channel (只读日历，供 agent 了解行程)
    appleCalendarChannel = FlutterMethodChannel(name: "me.memorion.api/apple_calendar", binaryMessenger: messenger)
    appleCalendarChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.appleCalendarService.handleMethodCall(call, result: result)
    }

    // Create Speech Recognition method channel (for on-device STT)
    speechChannel = FlutterMethodChannel(name: "com.memorion.ios/speech", binaryMessenger: messenger)
    speechRecognitionHandler.setChannel(speechChannel!)
    speechChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.speechRecognitionHandler.handleMethodCall(call, result: result)
    }

    // Create Audio Input Device method channel (音频输入设备管理)
    audioInputChannel = FlutterMethodChannel(name: "com.memorion.ios/audio_input", binaryMessenger: messenger)
    audioInputService.setChannel(audioInputChannel!)
    audioInputChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.audioInputService.handleMethodCall(call, result: result)
    }

    // Create PTT keep-alive method channel (BLE 长按时维持后台音频保活)
    pttKeepAliveChannel = FlutterMethodChannel(name: "com.memorion.ios/ptt_keepalive", binaryMessenger: messenger)
    pttBackgroundService.setChannel(pttKeepAliveChannel!)
    pttKeepAliveChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.pttBackgroundService.handleMethodCall(call, result: result)
    }

    // Create Apple Watch method channel (接收 Watch 录音并交给 Flutter 上传)
    watchChannel = FlutterMethodChannel(name: "com.memorion.ios/watch", binaryMessenger: messenger)
    watchSessionService.setChannel(watchChannel!)
    watchChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.watchSessionService.handleMethodCall(call, result: result)
    }

    soundcoreWifiChannel = FlutterMethodChannel(name: "me.memorion.api/soundcore_wifi", binaryMessenger: messenger)
    soundcoreWifiChannel?.setMethodCallHandler { [weak self] call, result in
      self?.soundcoreWifiService.handle(call, result: result)
    }

    plaudWifiChannel = FlutterMethodChannel(name: "me.memorion.api/plaud_wifi", binaryMessenger: messenger)
    plaudWifiChannel?.setMethodCallHandler { [weak self] call, result in
      self?.plaudWifiService.handle(call, result: result)
    }

  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    NSLog("[FCM] APNs registration completed")
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NSLog("[FCM] APNs registration failed: %@", (error as NSError).domain)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // MARK: - Notification routing
  // Firebase receives remote taps; Awesome receives local taps. Keep a single
  // system delegate and forward once, including engines initialized by UIScene.
  fileprivate func takeOverNotificationCenterDelegate() {
    let center = UNUserNotificationCenter.current()
    let current = center.delegate
    if current === self { return }
    // register 之后设上来的那个就是 awesome（firebase 的那个已单独记下）。
    if let current = current, current !== firebaseNotificationDelegate {
      awesomeNotificationDelegate = current
    }
    center.delegate = self
  }

  private func isRemotePush(_ notification: UNNotification) -> Bool {
    return notification.request.content.userInfo["gcm.message_id"] != nil
  }

  // 刻意不调 super：父类的实现会把回调再转发给注册过的插件（firebase 就在里面），叠加
  // 我们下面的显式转发会让 onMessageOpenedApp 触发两次 → deep-link 连开两个页面。
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let target = isRemotePush(response.notification)
      ? firebaseNotificationDelegate
      : awesomeNotificationDelegate
    guard let target = target,
          target.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)))
    else {
      completionHandler()
      return
    }
    target.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  // Keep Awesome's existing foreground presentation policy for local alerts.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let target = awesomeNotificationDelegate ?? firebaseNotificationDelegate
    guard let target = target,
          target.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)))
    else {
      completionHandler([])
      return
    }
    target.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    openSettingsFor notification: UNNotification?
  ) {
    let target = awesomeNotificationDelegate ?? firebaseNotificationDelegate
    guard let target = target,
          target.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:)))
    else { return }
    target.userNotificationCenter?(center, openSettingsFor: notification)
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
      case "setNotificationOnKillService":
        handleSetNotificationOnKillService(call: call)
      default:
        result(FlutterMethodNotImplemented)
    }
  }

  private func handleSetNotificationOnKillService(call: FlutterMethodCall) {
    NSLog("handleMethodCall: setNotificationOnKillService")
    
    if let args = call.arguments as? Dictionary<String, Any> {
      notificationTitleOnKill = args["title"] as? String
      notificationBodyOnKill = args["description"] as? String
    }
    
  }
  
  private func handleAppleRemindersCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    appleRemindersService.handleMethodCall(call, result: result)
  }
    

  override func applicationWillTerminate(_ application: UIApplication) {
    soundcoreWifiService.disconnect()
    plaudWifiService.disconnect()
    // If title and body are nil, then we don't need to show notification.
    if notificationTitleOnKill == nil || notificationBodyOnKill == nil {
      return
    }

    let content = UNMutableNotificationContent()
    content.title = notificationTitleOnKill!
    content.body = notificationBodyOnKill!
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    let request = UNNotificationRequest(identifier: "notification on app kill", content: content, trigger: trigger)

    NSLog("Running applicationWillTerminate")

    UNUserNotificationCenter.current().add(request) { (error) in
      if let error = error {
        NSLog("Failed to show notification on kill service => error: \(error.localizedDescription)")
      } else {
        NSLog("Show notification on kill now")
      }
    }
  }
}

// PLAUD uses a factory SSID. Remember exact ownership instead of deleting every
// matching prefix; an existing configuration must not be overwritten or removed.
private final class PlaudWifiService {
  private let ownedKey = "memorion.plaud.wifi.ownedSSID"
  private var joiningSSID: String?
  private var activeSSID: String?
  private var cancelJoin: (() -> Void)?

  private func removeOwned(_ ssid: String) {
    guard UserDefaults.standard.string(forKey: ownedKey) == ssid else { return }
    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    UserDefaults.standard.removeObject(forKey: ownedKey)
  }

  func removeStaleConfiguration() {
    if let ssid = UserDefaults.standard.string(forKey: ownedKey),
       ssid != joiningSSID && ssid != activeSSID { removeOwned(ssid) }
  }

  func disconnect() {
    cancelJoin?()
    if let ssid = activeSSID { removeOwned(ssid) }
    activeSSID = nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: String], let ssid = args["ssid"],
          ssid.hasPrefix("PLAUD"), ssid.utf8.count == 9,
          ssid.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
      result(FlutterError(code: "invalid_hotspot", message: nil, details: nil)); return
    }
    if call.method == "leave" {
      if joiningSSID == ssid { cancelJoin?() }
      removeOwned(ssid)
      if activeSSID == ssid { activeSSID = nil }
      result(nil); return
    }
    guard call.method == "join" else { result(FlutterMethodNotImplemented); return }
    guard joiningSSID == nil, activeSSID == nil, let password = args["password"],
          password.utf8.count == 8, password.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
      result(FlutterError(code: "hotspot_busy", message: nil, details: nil)); return
    }
    joiningSSID = ssid
    var completed = false
    var deadline: DispatchWorkItem?
    let finish: (FlutterError?) -> Void = { error in
      guard !completed else { return }
      completed = true
      deadline?.cancel()
      deadline = nil
      self.joiningSSID = nil
      self.cancelJoin = nil
      if error != nil { self.removeOwned(ssid) }
      result(error)
    }
    cancelJoin = { finish(FlutterError(code: "hotspot_join_cancelled", message: nil, details: nil)) }
    let timeout = DispatchWorkItem {
      finish(FlutterError(code: "hotspot_join_timeout", message: nil, details: nil))
    }
    deadline = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    NEHotspotConfigurationManager.shared.getConfiguredSSIDs { previous in
      DispatchQueue.main.async {
        guard !completed else { return }
        if previous.contains(ssid) && UserDefaults.standard.string(forKey: self.ownedKey) != ssid {
          finish(FlutterError(code: "hotspot_configuration_exists", message: nil, details: nil)); return
        }
        // Record ownership before apply, including crash/timeout/cancel paths.
        self.removeStaleConfiguration()
        UserDefaults.standard.set(ssid, forKey: self.ownedKey)
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = false
        config.lifeTimeInDays = 1
        NEHotspotConfigurationManager.shared.apply(config) { error in
          DispatchQueue.main.async {
            guard !completed else {
              // Do not delete a newer active attempt using this same factory SSID.
              if self.joiningSSID != ssid && self.activeSSID != ssid {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                self.removeOwned(ssid)
              }
              return
            }
            if let error = error as NSError?,
               !(error.domain == NEHotspotConfigurationErrorDomain &&
                 error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
              finish(FlutterError(code: "hotspot_join_failed", message: nil, details: error.code))
            } else {
              self.activeSSID = ssid
              finish(nil)
            }
          }
        }
      }
    }
  }
}

/// Only manages temporary Soundcore configurations created by this App.
/// A persistent configuration keeps navigation/background transitions from
/// triggering joinOnce's automatic disconnect; explicit batch teardown removes it.
private final class SoundcoreWifiService {
  private var joining = false
  private var joiningSSID: String?
  private var activeSSID: String?
  private var cancelJoin: (() -> Void)?

  func removeStaleConfigurations() {
    NEHotspotConfigurationManager.shared.getConfiguredSSIDs { [weak self] previous in
      DispatchQueue.main.async {
        guard let self = self else { return }
        for name in previous where name.hasPrefix("Memorion-SC-") &&
            name != self.joiningSSID && name != self.activeSSID {
          NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: name)
        }
      }
    }
  }

  func disconnect() {
    cancelJoin?()
    if let ssid = activeSSID {
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
      activeSSID = nil
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: String],
          let ssid = args["ssid"], ssid.hasPrefix("Memorion-SC-"),
          ssid.utf8.count <= 32 else {
      result(FlutterError(code: "invalid_hotspot", message: nil, details: nil))
      return
    }
    if call.method == "leave" {
      if joiningSSID == ssid { cancelJoin?() }
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
      if activeSSID == ssid { activeSSID = nil }
      result(nil)
      return
    }
    guard call.method == "join" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard !joining, let password = args["password"],
          (8...63).contains(password.utf8.count) else {
      result(FlutterError(code: "hotspot_busy", message: nil, details: nil))
      return
    }
    joining = true
    joiningSSID = ssid
    var completed = false
    var deadline: DispatchWorkItem?
    let finish: (FlutterError?) -> Void = { [weak self] error in
      guard !completed else { return }
      completed = true
      deadline?.cancel()
      deadline = nil
      self?.joining = false
      self?.joiningSSID = nil
      self?.cancelJoin = nil
      result(error)
    }
    cancelJoin = {
      finish(FlutterError(code: "hotspot_join_cancelled", message: nil, details: nil))
    }
    let timeout = DispatchWorkItem {
      guard !completed else { return }
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
      finish(FlutterError(code: "hotspot_join_timeout", message: nil, details: nil))
    }
    deadline = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    // Clean up configurations left by a previous App termination.
    NEHotspotConfigurationManager.shared.getConfiguredSSIDs { previous in
      DispatchQueue.main.async {
        guard !completed else { return }
        for name in previous where name.hasPrefix("Memorion-SC-") && name != ssid {
          NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: name)
        }
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        // joinOnce disconnects on sleep or after 15 seconds in background,
        // even while the recorder is still exporting. The batch owns cleanup;
        // launch also removes configurations left by an ungraceful termination.
        configuration.joinOnce = false
        configuration.lifeTimeInDays = 1
        NEHotspotConfigurationManager.shared.apply(configuration) { error in
          DispatchQueue.main.async {
            // An apply callback may arrive after timeout/cancellation. Remove
            // this attempt's configuration without completing Flutter twice.
            guard !completed else {
              NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
              return
            }
            if let error = error as NSError?,
               !(error.domain == NEHotspotConfigurationErrorDomain &&
                 error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
              NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
              finish(FlutterError(code: "hotspot_join_failed", message: nil, details: error.code))
            } else {
              self.activeSSID = ssid
              finish(nil)
            }
          }
        }
      }
    }
  }
}

// here
func registerPlugins(registry: FlutterPluginRegistry) {
  GeneratedPluginRegistrant.register(with: registry)
}

// Flutter 3.41's cold scene fallback calls didFinishLaunchingWithOptions, not
// application(open:) or application(continue:). app_links 6.4 implements only
// the latter two, so it does not receive a cold link from super.scene(...).
// FlutterDeepLinkingEnabled is false: explicitly deliver that cold link once.
// Warm links retain Flutter's legacy open/continue forwarding.
@objc class MemorionSceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let url = connectionOptions.urlContexts.first?.url {
      AppLinks.shared.handleLink(url: url)
    } else if let url = connectionOptions.userActivities.first(where: { $0.webpageURL != nil })?.webpageURL {
      AppLinks.shared.handleLink(url: url)
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    (UIApplication.shared.delegate as? AppDelegate)?.takeOverNotificationCenterDelegate()
  }
}
