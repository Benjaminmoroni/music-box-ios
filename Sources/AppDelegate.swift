import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // THIS IS THE WHOLE POINT OF THE NATIVE SHELL.
    //
    // `.playback` tells iOS the app's audio is primary content rather than an
    // incidental sound, and combined with UIBackgroundModes:audio in Info.plist
    // it keeps the audio session alive while backgrounded. A web page has no
    // way to ask for either — measured four ways on 2026-09-06, the session is
    // released a few seconds after the phone locks and will not come back
    // without a foreground gesture. See ~/music-box/README.md.
    //
    // Audio played by the WKWebView routes through this session, so nothing in
    // the web app changes.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    } catch {
      // Do not swallow it. If this fails the app still runs and still plays —
      // it just dies on lock exactly like the PWA, which is indistinguishable
      // from the bug we are fixing unless it is written down somewhere.
      NSLog("[MusicBox] AVAudioSession setup FAILED: \(error.localizedDescription) "
            + "— background audio will not survive locking.")
    }

    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = ViewController()
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
