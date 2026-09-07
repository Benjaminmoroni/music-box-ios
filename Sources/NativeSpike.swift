import AVFoundation
import Foundation
import UIKit
import MediaPlayer
import WebKit

/// PHASE 0. One hardcoded track, played by AVPlayer, and one question:
///
///   **does a lock-screen press resume it after five minutes?**
///
/// Everything else about native playback is only worth building if the answer
/// is yes. See ~/music-box/docs/native-playback-plan.md.
///
/// WHAT THIS TESTS, precisely. A backgrounded iOS app cannot START audio — the
/// single exemption is responding to a remote control event, and that exemption
/// belongs to whoever owns the playing element. WebKit owns it in the web app,
/// and we proved four ways that we cannot take it from WebKit: registering
/// MPRemoteCommandCenter natively produced zero `nat-*` entries, and
/// un-registering the page's own handlers so native could win transferred
/// nothing at all.
///
/// Here nothing in the web view is playing, so there is nothing to lose the
/// routing to. If `spike-cmd-play` appears in the log, the native handler is
/// receiving the event — the thing that has never once happened — and the
/// premise holds.
final class NativeSpike: NSObject {

    /// Persisted so a spike survives relaunch; the page owns the switch.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "MBSpike") }
        set { UserDefaults.standard.set(newValue, forKey: "MBSpike") }
    }

    /// A real, active track. Any id works: the test pauses, and paused audio
    /// does not advance, so the track's length is irrelevant to a five-minute
    /// wait.
    static let trackId = 1

    private weak var webView: WKWebView?
    private let log: (String) -> Void
    private var player: AVPlayer?
    private var registered = false
    private var ticker: Any?
    /// KVO is removed explicitly before anything is replaced. An observer left
    /// on a deallocated object, or removed when it was never added, is a crash
    /// — not a silent bug, so it is tracked rather than assumed.
    private var observedItem: AVPlayerItem?
    private var observingRate = false
    /// WHAT THE PAGE SAYS IS PLAYING. It rides along with the load command
    /// rather than arriving as a separate message: the page knows the track at
    /// the moment it asks for it, so sending them together is atomic with the
    /// track change and cannot race it. Phase 0 hardcoded "Native spike" here
    /// and the lock screen dutifully said that for every song.
    private var meta: [String: Any] = [:]
    private var artwork: MPMediaItemArtwork?
    /// Captured with the asset's cookies so artwork can be fetched through
    /// Cloudflare Access too — a bare request comes back as a login page, which
    /// decodes to no image and looks exactly like "this track has no art".
    private var cookieHeader = ""

    init(webView: WKWebView, log: @escaping (String) -> Void) {
        self.webView = webView
        self.log = log
        super.init()
    }

    // MARK: - driven by the page

    /// The page decides WHAT plays; this only executes it. No queue, no
    /// ordering, no "what is next" — if a rule is ever needed it stays in the
    /// page and is sent down, which is the line the deleted offline-shuffle
    /// duplicate was removed for crossing.
    func handle(_ body: [String: Any]) {
        switch (body["cmd"] as? String) ?? "" {
        case "load":
            meta = body
            artwork = nil          // never show the previous track's cover
            let raw = body["id"]
            let id = (raw as? Int) ?? Int((raw as? String) ?? "") ?? 0
            if id > 0 { start(trackId: id) }
        case "play":  player?.play();  after("np-play")
        case "pause": player?.pause(); after("np-pause")
        case "seek":
            if let at = body["at"] as? Double {
                player?.seek(to: CMTime(seconds: at, preferredTimescale: 600))
                after(nil)
            }
        default: break
        }
    }

    // MARK: - start

    func start(trackId: Int = NativeSpike.trackId) {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "MBAppURL") as? String,
              let url = URL(string: base.hasSuffix("/") ? "\(base)audio?id=\(trackId)"
                                                        : "\(base)/audio?id=\(trackId)")
        else { log("spike-no-url"); return }

        // CLOUDFLARE ACCESS IS THE FIRST THING THAT CAN KILL THIS, and it is
        // invisible if unhandled: AVPlayer makes its own HTTP requests, does
        // not share the web view's cookie jar, and a 302 to a login page
        // arrives as an unplayable asset rather than an error anyone would
        // recognise. AVURLAssetHTTPCookiesKey is the documented way to hand
        // them over; the cookies themselves come from the web view's store,
        // which is where Access put them when the page logged in.
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] jar in
            guard let self = self else { return }
            let host = url.host ?? ""
            let mine = jar.filter { host.hasSuffix($0.domain.hasPrefix(".") ? String($0.domain.dropFirst())
                                                                           : $0.domain) }
            self.log("spike-cookies-\(mine.count)")
            self.cookieHeader = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            self.loadArt(base: base, trackId: trackId)
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: mine])
            self.play(AVPlayerItem(asset: asset))
        }
    }

    private func play(_ item: AVPlayerItem) {
        // A second load must REPLACE, not stack. Two AVPlayers would each hold
        // the session and both would render.
        teardown()
        // WE ARE THE ONLY OWNER OF THE SESSION DURING THE SPIKE. The keep-alive
        // and the play-edge reclaim were removed for exactly this reason:
        // `sess-reclaimed -> sess-interrupted` inside one second appears in four
        // logs, and one AVAudioSession with two owners is the likeliest
        // explanation. A spike run against that noise would not be evidence.
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default)
            try s.setActive(true)
        } catch let e as NSError {
            log("spike-session-\(MediaBridge.reason(e.code))")
        }

        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p
        register()

        // A failed load must SAY so. An Access redirect lands here, and without
        // it the symptom is silence with no line in any log — the exact shape
        // that cost this project four wrong diagnoses.
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
                let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self?.log("spike-failed-\(e?.code ?? 0)")
            }
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        observedItem = item
        // EXTERNALLY-DRIVEN PAUSES REPORT NOTHING OTHERWISE. A call, an alarm or
        // a route change stops the player without any command passing through
        // us, so the page would keep believing it was playing and the in-app
        // glyph would go stale again — the same failure as the missing state
        // push, arriving by a different door.
        p.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
        observingRate = true

        // POSITION MUST COME UP. `a` is idle on this path so its currentTime
        // never moves — without ticks the progress line, the lyric highlight
        // and the /played beacon would all freeze while music played perfectly,
        // which is the exact shape of failure this project keeps recording.
        // 4 Hz: enough for a lyric line, cheap enough to ignore.
        ticker = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] t in
                guard let self = self, let item = self.player?.currentItem else { return }
                let d = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
                self.toPage("window.__mbTick(\(CMTimeGetSeconds(t)),\(d),"
                            + "\((self.player?.rate ?? 0) > 0))")
            }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                // The advance is the page's decision, not ours.
                self?.log("np-end"); self?.toPage("window.__mbEnded()")
            }

        p.play()
        publish()
        log("spike-started")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus" {
            DispatchQueue.main.async { [weak self] in self?.after(nil) }
            return
        }
        guard keyPath == "status", let item = object as? AVPlayerItem else { return }
        switch item.status {
        case .readyToPlay: log("spike-ready"); publish()
        case .failed:      log("spike-item-failed-\((item.error as NSError?)?.code ?? 0)")
        default:           break
        }
    }

    /// PUSH THE STATE AFTER EVERY COMMAND. The periodic observer only fires
    /// while the player is PLAYING, so a pause produced no tick and the page's
    /// idea of `playing` stayed true forever — the in-app button lagged and
    /// then stopped moving, while tapping it still worked. Position ticks are
    /// not a state channel; this is.
    ///
    /// It also covers the lock screen: a press there reaches the remote handler
    /// and never touched the page, so the in-app glyph had no way to learn
    /// about it either.
    private func after(_ tag: String?) {
        publish()
        pushState()
        if let t = tag { log(t) }
    }

    private func pushState() {
        guard let p = player, let item = p.currentItem else { return }
        let d = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
        toPage("window.__mbTick(\(CMTimeGetSeconds(p.currentTime())),\(d),\(p.rate > 0))")
    }

    /// Fetch the cover for the lock screen. Failure is SILENT by nature — a
    /// missing image just looks like a track without art — so every outcome is
    /// logged, including the one that matters: an Access redirect arrives as a
    /// perfectly valid HTTP 200 of HTML that simply is not an image.
    private func loadArt(base: String, trackId: Int) {
        let sep = base.hasSuffix("/") ? "" : "/"
        guard let url = URL(string: "\(base)\(sep)art?id=\(trackId)") else { return }
        var req = URLRequest(url: url)
        if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            guard let d = data, let img = UIImage(data: d) else {
                self.log(err == nil ? "art-not-an-image" : "art-failed"); return
            }
            self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            DispatchQueue.main.async { self.publish() }
        }.resume()
    }

    private func toPage(_ js: String) {
        guard let web = webView else { return }
        DispatchQueue.main.async { web.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func teardown() {
        if let t = ticker { player?.removeTimeObserver(t); ticker = nil }
        if observingRate { player?.removeObserver(self, forKeyPath: "timeControlStatus")
                           observingRate = false }
        if let it = observedItem { it.removeObserver(self, forKeyPath: "status")
                                   observedItem = nil }
        player?.pause()
    }

    func stop() {
        teardown(); player = nil
        unregister()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        log("spike-stopped")
    }

    // MARK: - the actual question

    private func register() {
        guard !registered else { return }
        registered = true
        let c = MPRemoteCommandCenter.shared()
        // EVERY HANDLER LOGS BEFORE IT ACTS. Whether the command ARRIVES and
        // whether playback then resumes are different questions with opposite
        // fixes, and this project has already spent four rounds guessing which.
        c.playCommand.addTarget { [weak self] _ in
            self?.log("spike-cmd-play"); self?.player?.play(); self?.after(nil); return .success }
        c.pauseCommand.addTarget { [weak self] _ in
            self?.log("spike-cmd-pause"); self?.player?.pause(); self?.after(nil); return .success }
        // A Bluetooth button is one toggle — the web side learned this the hard
        // way, and the lesson carries over unchanged.
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            self?.log("spike-cmd-toggle")
            p.rate > 0 ? p.pause() : p.play()
            self?.after(nil); return .success }
        // SKIP IS THE PAGE'S DECISION. These forward into the same entry points
        // the in-app buttons use, so shuffle, stations, recency and bans all
        // apply — Swift never works out what is next.
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.log("spike-cmd-next")
            self?.toPage("window.__mbNative && window.__mbNative.next()")
            return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.log("spike-cmd-prev")
            self?.toPage("window.__mbNative && window.__mbNative.prev()")
            return .success }
        // Dragging the lock screen scrubber. Seek natively, then report — the
        // page's position comes from ticks, so without the push its progress
        // line would snap back to where it was.
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let ev = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seek(to: CMTime(seconds: ev.positionTime, preferredTimescale: 600))
            self?.after("spike-cmd-seek")
            return .success }
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand,
         c.previousTrackCommand, c.changePlaybackPositionCommand].forEach { $0.isEnabled = true }
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand,
         c.previousTrackCommand, c.changePlaybackPositionCommand].forEach {
            $0.removeTarget(nil); $0.isEnabled = false }
    }

    /// The rate is what the lock screen reads as play-vs-pause and what makes
    /// its clock tick; publishing a position without it leaves a frozen timer,
    /// already chased once from the web side.
    private func publish() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (meta["title"] as? String) ?? "",
            MPMediaItemPropertyArtist: (meta["artist"] as? String) ?? "",
        ]
        if let album = meta["album"] as? String, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let art = artwork { info[MPMediaItemPropertyArtwork] = art }
        if let d = player?.currentItem?.duration, d.isNumeric {
            info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(d)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            CMTimeGetSeconds(player?.currentTime() ?? .zero)
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.rate ?? 0) > 0 ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
