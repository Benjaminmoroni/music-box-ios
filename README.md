# Music Box — iOS shell

A ~140-line native wrapper around an existing web app. It exists for **one
reason**: to declare `UIBackgroundModes: audio` and set `AVAudioSession` to
`.playback`, so audio keeps playing when the phone locks.

A PWA cannot do either. There is no manifest field, meta tag or JavaScript API
for it — the iOS audio session is released a few seconds after the page is
backgrounded and will not come back without a foreground gesture. That was
measured four separate ways (freezing `playbackRate`, a real `pause()`+`play()`,
muting, and re-asserting `play()` on resume) before concluding the web could not
do it.

**Everything else lives in the web app.** This shell has no features, no offline
logic, no player. If you are looking for how something works, it is not here.

## Layout

    project.yml       XcodeGen spec — the .xcodeproj is GENERATED, never committed
    Sources/          two files: audio session setup, and a WKWebView
    Resources/        Info.plist (the entitlement + config) and a launch screen
    .github/          builds an unsigned .ipa on a hosted macOS runner

## Configuration

The site URL is **not in this repo** — it is a placeholder in `Info.plist` and
CI substitutes it from the `MB_APP_URL` secret. If it is missing, the app says
so on screen instead of showing a blank webview.

`MBAllowedHostSuffixes` lists hosts the webview may navigate to besides the app's
own. It contains `cloudflareaccess.com` because login **redirects off our origin
and back**; a wrapper that only allows its own host dead-ends first-launch login
and looks broken. Anything else opens in Safari.

## Build

Pushing to `main` builds `MusicBox-unsigned.ipa` as a workflow artifact. It is
**unsigned on purpose**: AltStore signs it with a free Apple ID on the way onto
the device, and AltServer re-signs before the 7-day certificate lapses. No
$99/yr developer account and no Mac are required — the runner is a hosted macOS
VM that exists for the length of the build.

To build locally you need a Mac with Xcode:

    brew install xcodegen && xcodegen generate && open MusicBox.xcodeproj

## Status

**Untested.** Written on Linux, never compiled — there is no Mac here and CI has
not run. Expect the first build to need fixing. In particular the audio-session
claim above is the *standard* approach for web-wrapped audio apps, not something
verified on a device yet.
