import Foundation
import MediaPlayer
import WebKit

/// Owns the SYSTEM transport — lock screen, headphone buttons, Control Center.
///
/// WHY THIS EXISTS. A WKWebView inside a third-party app does NOT automatically
/// become the system Now Playing app. Safari and an installed PWA get that
/// wiring for free; a wrapper has to publish it itself. Measured on the device
/// 2026-09-07: with only UIBackgroundModes:audio, audio survives locking but
/// the lock screen never updates its play state and neither a headphone press
/// nor the lock-screen button resumes after ~30s — while unlocking to the app
/// resumes instantly. That pattern says the command never reached the page,
/// not that the page refused it.
///
/// So the native layer registers the remote commands and forwards them INTO the
/// web app, and publishes what the page reports back out to MPNowPlayingInfo.
///
/// BEHIND A SWITCH, DEFAULT OFF. Everything here is unverified — the open
/// question is whether evaluateJavaScript runs while backgrounded. With the
/// switch off this file registers nothing and the build behaves exactly like
/// the one already on the phone, which after a day of regressions is the
/// property worth having.
final class MediaBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "mb"
    private weak var webView: WKWebView?
    private var registered = false
    /// Last state the page reported, so the session is reclaimed on the
    /// paused->playing EDGE rather than on every ladder rung.
    private var lastPlaying = false

    /// Persisted so the choice survives relaunch. The page owns the UI for it
    /// (Settings -> Native transport) and posts it down here.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "MBNativeTransport") }
        set { UserDefaults.standard.set(newValue, forKey: "MBNativeTransport") }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        if MediaBridge.enabled { register() }
    }

    // MARK: - messages from the page

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "transport":
            // The page's Settings toggle. Applying it live means no relaunch to
            // A/B it, which is the whole point of it being a switch.
            let on = (body["enabled"] as? Bool) ?? false
            MediaBridge.enabled = on
            on ? register() : unregister()

        case "nowplaying":
            // THE SESSION IS RECLAIMED WHETHER OR NOT THE SWITCH IS ON, because
            // this is not transport — it is the only signal the shell gets that
            // playback is about to start. Measured 2026-09-07: a backgrounded
            // resume started, ran 1.6s and then the element PAUSED ITSELF,
            // which is what WebKit does when the session under it is dead. The
            // interruption observer cannot cover that case: a session that went
            // inactive without an interruption delivers no notification at all.
            //
            // On the false->true EDGE only. `restateSession` runs a five-rung
            // ladder per track, so acting on every message would call setActive
            // dozens of times a minute for nothing.
            let playing = (body["playing"] as? Bool) ?? false
            if playing && !lastPlaying { reclaimSession() }
            lastPlaying = playing

            guard MediaBridge.enabled else { return }
            publish(body)

        default:
            break
        }
    }

    // MARK: - out: what is playing

    private func publish(_ b: [String: Any]) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = (b["title"] as? String) ?? ""
        info[MPMediaItemPropertyArtist] = (b["artist"] as? String) ?? ""
        if let album = b["album"] as? String { info[MPMediaItemPropertyAlbumTitle] = album }
        if let dur = b["duration"] as? Double, dur.isFinite, dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        if let pos = b["position"] as? Double, pos.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos
        }
        // THE RATE IS WHAT THE LOCK SCREEN READS AS PLAY-VS-PAUSE, and it is
        // also what makes its clock tick. Publishing position without it leaves
        // a frozen timer, which this project has already chased once from the
        // web side.
        let playing = (b["playing"] as? Bool) ?? false
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    // MARK: - in: system commands

    private func register() {
        guard !registered else { return }
        registered = true
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in self?.call("play") ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in self?.call("pause") ?? .commandFailed }
        // A Bluetooth AVRCP button is ONE toggle, and the web side already
        // learned that the hard way: while "held" it only ever received pause.
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.call("toggle") ?? .commandFailed }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.call("next") ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.call("prev") ?? .commandFailed }

        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
         c.nextTrackCommand, c.previousTrackCommand].forEach { $0.isEnabled = true }
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
         c.nextTrackCommand, c.previousTrackCommand].forEach {
            $0.removeTarget(nil); $0.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Make sure the session is ours and active before the page starts audio.
    /// Cheap when it already is, and the failure is REPORTED rather than
    /// swallowed — into the page's own diagnostics, since NSLog needs a Mac to
    /// read and the only device that reproduces this is a phone.
    private func reclaimSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            log("reclaimed")
        } catch {
            log("reclaim-failed")
            NSLog("[MusicBox] setActive on play FAILED: \(error.localizedDescription)")
        }
    }

    /// Write into the page's diagnostics buffer, which is the only one readable
    /// on the device. Also the first real exercise of native->page
    /// evaluateJavaScript while backgrounded: if these lines appear in the log,
    /// that direction works and the transport bridge has a future; if they
    /// never do, it does not, and that is worth knowing either way.
    func log(_ tag: String) {
        guard let web = webView else { return }
        let js = "window.__mbLog && window.__mbLog('\(tag)')"
        DispatchQueue.main.async { web.evaluateJavaScript(js, completionHandler: nil) }
    }

    /// Forward a command into the page. THE OPEN QUESTION IS WHETHER THIS RUNS
    /// WHILE BACKGROUNDED — the app is legitimately alive (it holds the audio
    /// background mode), so it should, but "should" is what has been wrong all
    /// day. The page records what it receives, so the diagnostics will say.
    @discardableResult
    private func call(_ cmd: String) -> MPRemoteCommandHandlerStatus {
        guard let web = webView else { return .commandFailed }
        let js = "window.__mbNative && window.__mbNative.\(cmd) && window.__mbNative.\(cmd)()"
        DispatchQueue.main.async { web.evaluateJavaScript(js, completionHandler: nil) }
        return .success
    }
}
