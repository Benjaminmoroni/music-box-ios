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

    /// WE GIVE THE SESSION UP; NOBODY TAKES IT (Ben, 2026-09-07).
    ///
    /// That correction is what this exists for. Measured: with a real pause we
    /// release and another app has the slot within seconds — five
    /// `sess-interrupted` in eight. With the hold we release nothing and NOTHING
    /// interrupts us at all, yet resume still dies somewhere between 20 and 27
    /// seconds. **A steal announces itself and that one never did**, so the
    /// ceiling is not a rogue app; the session simply lapses under us because
    /// `playbackRate = 0` renders NO SAMPLES and iOS reclaims a session nobody
    /// is using.
    ///
    /// The page already tried to fix this at its own layer and could not:
    /// mute-hold kept `rate 1` and muted, and lapsed identically, because
    /// WebKit does not count a muted element as playing audio either. The shell
    /// can do what the page cannot — render REAL silence through our own
    /// session, which iOS does count.
    private var keepAlive: AVAudioPlayer?
    private var release: DispatchWorkItem?

    /// Bounded, and the bound is the point (Ben): "give it a few minutes of
    /// holding onto the session (maybe 5), and then ACTIVELY release it so that
    /// it is clear that music-box is no longer resumable from the lock screen."
    ///
    /// Holding forever would make us the app everyone else's audio has to fight
    /// — precisely the rudeness this whole investigation has been complaining
    /// about from the other side. And an unbounded hold has no honest end
    /// state: the widget keeps offering a play button that does nothing. A
    /// deliberate release ends it cleanly instead of decaying into a lie.
    private static let holdWindow: TimeInterval = 300

    static var keepAliveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "MBHoldSession") }
        set { UserDefaults.standard.set(newValue, forKey: "MBHoldSession") }
    }

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
        case "keepalive":
            let on = (body["enabled"] as? Bool) ?? false
            MediaBridge.keepAliveEnabled = on
            if !on { stopHolding() }

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
            if playing != lastPlaying {
                if playing {
                    stopHolding()      // real audio is coming; silence is done
                    reclaimSession()
                } else {
                    startHolding()     // paused: keep the session genuinely busy
                }
            }
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
        } catch let e as NSError {
            log("reclaim-" + MediaBridge.reason(e.code))
            NSLog("[MusicBox] setActive on play FAILED (\(e.code)): \(e.localizedDescription)")
        }
    }

    /// AVAudioSession errors are OSStatus four-character codes, and a bare
    /// number is unreadable on the one screen that can show it. Only the ones
    /// that mean something different to us are named; anything else keeps its
    /// number so an unknown case is still identifiable rather than lumped in.
    ///
    /// `cannot-interrupt` is the one worth watching for: it means ANOTHER app
    /// holds an active non-mixable session and a BACKGROUNDED app is not
    /// allowed to take it. That would make this failure about the other app's
    /// mere existence, not about anything we did — and it would be fixed by
    /// force-quitting that app, not by more code here.
    static func reason(_ code: Int) -> String {
        switch code {
        case 560557684: return "cannot-interrupt"      // '!int'
        case 560030580: return "cannot-start-playing"  // '!pla'
        case 561015905: return "cannot-start-record"   // '!rec'
        case 560161140: return "bad-param"             // '-50'
        case 561017449: return "session-not-active"    // '!ina'
        default:        return "failed-\(code)"
        }
    }

    // MARK: - holding the session across a pause

    private func startHolding() {
        guard MediaBridge.keepAliveEnabled, keepAlive == nil else { return }
        do {
            // Zero-amplitude SAMPLES, not volume 0 and not muted — the
            // distinction is the whole lesson from mute-hold. The audio unit
            // has to actually render for iOS to count us as playing.
            let p = try AVAudioPlayer(data: MediaBridge.silence())
            p.numberOfLoops = -1
            p.play()
            keepAlive = p
            log("holding")
        } catch let e as NSError {
            log("hold-" + MediaBridge.reason(e.code))
            NSLog("[MusicBox] keep-alive FAILED (\(e.code)): \(e.localizedDescription)")
        }
        let work = DispatchWorkItem { [weak self] in self?.releaseSession() }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MediaBridge.holdWindow,
                                      execute: work)
    }

    private func stopHolding() {
        release?.cancel(); release = nil
        guard keepAlive != nil else { return }
        keepAlive?.stop(); keepAlive = nil
        log("hold-ended")
    }

    /// The honest end of the window. Deactivating with
    /// `.notifyOthersOnDeactivation` is what tells iOS and every other app that
    /// we are done, so the lock screen stops offering a Music Box that cannot
    /// come back — and the page is told too, so its own state stops claiming a
    /// hold it no longer has.
    private func releaseSession() {
        release = nil
        keepAlive?.stop(); keepAlive = nil
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            log("released")
        } catch let e as NSError {
            log("release-" + MediaBridge.reason(e.code))
        }
        guard let web = webView else { return }
        DispatchQueue.main.async {
            web.evaluateJavaScript("window.__mbRelease && window.__mbRelease()",
                                   completionHandler: nil)
        }
    }

    /// One second of PCM zeroes, looped. Built rather than shipped as a
    /// resource: a silent WAV is a header and a run of zeroes, and a binary
    /// asset for that is one more thing the build can silently drop — which
    /// this project has already been bitten by once.
    private static func silence(seconds: Double = 1, rate: Int = 44_100) -> Data {
        let frames = Int(Double(rate) * seconds)
        let bytes = frames * 2                       // mono, 16-bit
        func le(_ v: Int, _ n: Int) -> Data {
            var x = UInt32(v).littleEndian
            return Data(bytes: &x, count: n)
        }
        var d = Data("RIFF".utf8)
        d.append(le(36 + bytes, 4)); d.append(Data("WAVEfmt ".utf8))
        d.append(le(16, 4))                          // fmt chunk size
        d.append(le(1, 2)); d.append(le(1, 2))       // PCM, mono
        d.append(le(rate, 4)); d.append(le(rate * 2, 4))
        d.append(le(2, 2)); d.append(le(16, 2))      // block align, bits
        d.append(Data("data".utf8)); d.append(le(bytes, 4))
        d.append(Data(count: bytes))
        return d
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
