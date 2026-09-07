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
    activateSession()

    // AN AUDIO APP MUST HANDLE INTERRUPTIONS, AND THIS ONE DID NOT (2026-09-07).
    //
    // Ben: "that 40s one was because another backgrounded app took over the
    // play widget on the lock screen." When another app takes the audio
    // session, iOS sends an interruption; when it releases, iOS sends .ended.
    // We observed NEITHER and called setActive(true) exactly once, at launch —
    // so a session lost to any other app was lost for good, and the only thing
    // that brought it back was a foreground gesture.
    //
    // That is exactly the reported symptom: press play on the lock screen and
    // nothing happens, open the app and the music resumes instantly. And it
    // explains why the whole investigation looked intermittent — a podcast, a
    // video, Siri or a notification sound is enough, so it fires on the phone
    // and never on a test bench.
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                   name: AVAudioSession.interruptionNotification,
                   object: AVAudioSession.sharedInstance())
    // Rare, but it invalidates EVERY audio object in the process; the category
    // and the active flag both have to be set again from scratch.
    nc.addObserver(self, selector: #selector(mediaServicesReset(_:)),
                   name: AVAudioSession.mediaServicesWereResetNotification,
                   object: AVAudioSession.sharedInstance())

    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = ViewController()
    window.makeKeyAndVisible()
    self.window = window
    return true
  }

  /// The one place that claims the session, so every caller re-asserts it the
  /// same way. A failure is NEVER swallowed: the app still runs and still
  /// plays, it just dies on lock exactly like the PWA — indistinguishable from
  /// the bug we are fixing unless it is written down somewhere.
  private func activateSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    } catch {
      NSLog("[MusicBox] AVAudioSession activate FAILED: \(error.localizedDescription) "
            + "— background audio will not survive locking.")
    }
  }

  @objc private func sessionInterrupted(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

    switch type {
    case .began:
      // Someone else owns the session now. Nothing to do but notice — iOS has
      // already stopped our audio, and the page's own listeners see the pause.
      NSLog("[MusicBox] audio session interrupted — another app took it")
    case .ended:
      // RECLAIM IT UNCONDITIONALLY. This is the fix: without it the session
      // stays dead and every later play() runs into nothing.
      activateSession()
      let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      NSLog("[MusicBox] audio session interruption ended — reclaimed"
            + (opts.contains(.shouldResume) ? " (iOS says we may resume)" : ""))
      // DELIBERATELY NOT AUTO-RESUMING, even on .shouldResume. Restoring the
      // session makes the next press work, which is the reported failure;
      // starting music by itself in someone's pocket is a worse bug than the
      // one being fixed, and it would fire on every notification sound. The
      // option is logged so we can see whether iOS would have allowed it
      // before deciding to act on it.
      break
    @unknown default:
      break
    }
  }

  @objc private func mediaServicesReset(_ note: Notification) {
    NSLog("[MusicBox] media services were reset — rebuilding the audio session")
    activateSession()
  }
}
