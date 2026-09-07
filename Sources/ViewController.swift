import UIKit
import WebKit

/// A WKWebView pointing at the music-box PWA. It deliberately does almost
/// nothing: the web app is the app, and every feature lives there.
final class ViewController: UIViewController, WKNavigationDelegate {

  private var webView: WKWebView!

  /// Read from Info.plist so the real hostname is never committed — this repo
  /// is public. CI substitutes MBAppURL from a secret at build time.
  private var appURL: URL? {
    guard let s = Bundle.main.object(forInfoDictionaryKey: "MBAppURL") as? String,
          let u = URL(string: s), u.host != nil, u.host != "example.invalid"
    else { return nil }
    return u
  }

  private var allowedSuffixes: [String] {
    (Bundle.main.object(forInfoDictionaryKey: "MBAllowedHostSuffixes") as? [String]) ?? []
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1)

    let cfg = WKWebViewConfiguration()
    // The app plays audio without a tap for every track after the first, and
    // the player is inline rather than fullscreen.
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    // A PERSISTENT store, explicitly. This holds the Cloudflare Access cookie,
    // the service worker and the offline downloads. Ephemeral would mean
    // logging in on every launch and re-downloading everything.
    cfg.websiteDataStore = .default()

    webView = WKWebView(frame: view.bounds, configuration: cfg)
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    // Let the page paint under the status bar the way the PWA does.
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    view.addSubview(webView)

    guard let url = appURL else {
      // Fail LOUDLY and in words. A blank webview is the least debuggable
      // failure there is, and a missing build secret is the likeliest cause.
      showFatal("MBAppURL is not set.\n\nThis build was produced without the "
                + "MB_APP_URL secret, so it has no site to load.")
      return
    }
    webView.load(URLRequest(url: url))
  }

  /// CLOUDFLARE ACCESS REDIRECTS OFF OUR ORIGIN AND BACK.
  ///
  /// One-time-PIN login is served from *.cloudflareaccess.com. The common
  /// wrapper default — "only allow my own host" — would dead-end first-launch
  /// login and read as a broken app rather than a policy choice. Anything else
  /// (a link in lyrics, say) opens in Safari rather than inside the shell.
  func webView(_ webView: WKWebView,
               decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, let host = url.host else {
      decisionHandler(.allow); return
    }
    let ownHost = appURL?.host ?? ""
    let permitted = host == ownHost
      || allowedSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    if permitted {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      UIApplication.shared.open(url)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    showFatal("Couldn't load.\n\n\(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView,
               didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    showFatal("Couldn't reach the server.\n\n\(error.localizedDescription)")
  }

  private func showFatal(_ message: String) {
    let label = UILabel(frame: view.bounds.insetBy(dx: 24, dy: 24))
    label.numberOfLines = 0
    label.textAlignment = .center
    label.textColor = .white
    label.font = .systemFont(ofSize: 15)
    label.text = message
    label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(label)
  }
}
