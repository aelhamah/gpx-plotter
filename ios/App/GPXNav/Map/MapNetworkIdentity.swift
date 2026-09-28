import Foundation
@preconcurrency import MapLibre

/// Pins the `User-Agent` that MapLibre Native sends with every tile, DEM, and
/// offline request.
///
/// ## Why this exists
///
/// The web app's MapTiler key is protected by an HTTP referrer allowlist, and a
/// native app can never satisfy one: `NSURLSession` sends neither `Origin` nor
/// `Referer`, so MapTiler answers `403 Key usage restricted`. There is no
/// app-side workaround — `Origin` is a forbidden header name in `URLSession`.
///
/// MapTiler's second protection method is an **allowed user-agent header**,
/// which is explicitly documented for "your own custom application in which you
/// can set the User-Agent HTTP header". `User-Agent` is an ordinary settable
/// header, so that works from native. This type is the app side of that.
///
/// ## Why the User-Agent carries no version
///
/// It is tempting to send `GPXNav/0.1.0 MapLibre/6.31.0 …` and allowlist a
/// prefix of it, but that only works if MapTiler matches on a *substring*. If it
/// ever matches the whole header, every version bump silently breaks the key at
/// release time — the worst possible moment to discover it.
///
/// So the `User-Agent` is exactly `allowlistToken` and nothing else, and the
/// version details move to `X-GPXNav-Version`, an ordinary custom header that
/// the allowlist never has to know about. The allowlisted value is then
/// correct today and after every future release.
enum MapNetworkIdentity {
    /// The exact, stable `User-Agent` value. This is what goes on the MapTiler key.
    static var allowlistToken: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        return "GPXNav (iOS; \(bundleID))"
    }

    /// Extra, non-allowlisted header carrying build detail for debugging.
    static var versionHeader: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build)) MapLibre/\(MapLibreVersion.current)"
    }

    /// The header value actually sent.
    static var userAgent: String { allowlistToken }

    /// Apply the identity to MapLibre's shared session.
    ///
    /// Must run before the first `MLNMapView` is created, because `NSURLSession`
    /// copies the configuration at init — which also means every tile request
    /// the map makes through the loopback cache leaves with the allowlisted
    /// user-agent, and MapTiler accepts them (§5.1).
    static func apply() {
        // The property is `null_resettable`; MapLibre documents that nil means
        // "use the default session configuration", so mirror that here.
        let configuration = MLNNetworkConfiguration.sharedManager.sessionConfiguration ?? .default
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "X-GPXNav-Version": versionHeader,
        ]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
    }
}

/// The MapLibre Native version, read from the framework so the user-agent cannot
/// drift from the binary.
enum MapLibreVersion {
    static let current: String = {
        let bundle = Bundle(for: MLNMapView.self)
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        default: return "unknown"
        }
    }()
}
