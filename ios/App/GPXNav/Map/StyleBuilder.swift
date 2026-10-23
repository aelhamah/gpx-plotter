import Foundation
import RouteKit

/// Fetches MapTiler's hosted style, resolves its basemap sources, and rewrites
/// it for what MapLibre Native cannot do on its own.
///
/// Three rewrites, all forced by Native's missing APIs:
///
/// - **3D terrain.** The web app calls `map.setTerrain({ source, exaggeration })`,
///   a MapLibre GL **JS** API. Native's ObjC headers expose no terrain setter,
///   so `"terrain": { … }` has to be in the style JSON before the map loads it.
/// - **Cached tiles.** MapTiler's sources are all TileJSON `url`s, which
///   MapLibre resolves for a live map but which leave us no seam to intercept a
///   tile. They are resolved here and repointed at the loopback cache, so every
///   basemap request passes through disk. That is what makes an offline map
///   possible at all — see `TileCache`.
/// - **Cached elevation.** The DEM source is repointed at the loopback for the
///   same reason: hillshade and 3D terrain read it straight from MapTiler
///   otherwise, and neither survives being offline.
///
/// The basemap is still MapTiler's own; only these things are changed.
actor StyleBuilder {
    /// Terrain exaggeration, matching the web app's `setTerrain` call.
    static let terrainExaggeration = 1.15

    private let session: URLSession
    private let config: MapTilerConfig?
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<(Data, ResolvedSources, Double?), Error>] = [:]
    /// Source id → MapTiler's own tile URL template, from that source's
    /// TileJSON. The loopback server substitutes coordinates into it on a miss.
    private var upstreamTemplates: [String: String] = [:]
    private var sources: [String: BasemapSource] = [:]
    /// Style builds started but not yet merged, by style key.
    ///
    /// See `upstreamTemplate(forSource:)` for what this is for: tiles that
    /// arrive while one of these is in flight wait for it rather than being
    /// answered 404, which MapLibre treats as final.
    private var building: [String: (style: MapStyle, terrain: Bool)] = [:]
    /// Basemap style → the highest zoom it was found to serve tiles for.
    ///
    /// See `maxZoom(for:)` for what this is for and why it is not the smallest
    /// source's ceiling.
    private var zoomCeilings: [String: Double] = [:]

    init(config: MapTilerConfig?) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        // The style is fetched by us rather than by MapLibre, so it needs the
        // allowlisted user-agent set explicitly instead of coming from
        // MLNNetworkConfiguration.
        configuration.httpAdditionalHeaders = [
            "User-Agent": MapNetworkIdentity.userAgent,
            "X-GPXNav-Version": MapNetworkIdentity.versionHeader,
        ]
        // Belt and braces under BoundedFetch: the idle timeout CFNetwork applies
        // has been observed not to fire on a stalled HTTP/3 attempt, so the
        // deadline is enforced by cancellation there rather than relied upon
        // here, and waiting for a path that never appears would otherwise be
        // allowed to wait for the resource timeout.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// The style JSON to hand MapLibre, or nil when there is no MapTiler key.
    func style(for style: MapStyle, terrain: Bool) async -> Data? {
        guard let config else { return nil }
        let key = "\(style.rawValue)-\(terrain)"
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return try? await existing.value.0 }
        print("StyleBuilder: building \(key)")
        building[key] = (style, terrain)
        defer { building.removeValue(forKey: key) }

        let task = Task<(Data, ResolvedSources, Double?), Error> { [config, session] in
            print("StyleBuilder: task started \(key)")
            let raw = try await Self.fetchStyle(for: style, config: config, session: session)
            print("StyleBuilder: \(key) style json parsed (\(raw.count) keys)")
            let resolved = try await Self.resolveTileSources(in: raw, session: session)
            print("StyleBuilder: \(key) resolve done \(resolved.sources.keys.sorted())")
            // Read off the resolved style, which is still a dictionary here.
            // `patching` serialises it, and a JSON round trip to get one number
            // back would be a strange price for asking MapLibre to stay inside
            // its tiles.
            let ceiling = Self.styleZoomCeiling(resolved.style)
            print("StyleBuilder: \(key) ceiling \(ceiling.map(String.init(describing:)) ?? "nil")")
            let patched = try Self.patching(
                resolved.style,
                terrain: terrain,
                formats: resolved.sources.mapValues(\.format)
            )
            // Merge into the actor's state *before* returning rather than in the
            // creator below, so the moment this task completes every awaiter of
            // it — the creator here, and any tile request that joined through
            // `inFlight` — sees the templates. Merging only after the creator's
            // continuation is scheduled made that ordering load-bearing: a
            // joiner that resumed first looped back through `style()` for a
            // template that did not exist yet, returned synchronously from the
            // completed task, and spun on the actor so hard (99% CPU) that the
            // creator's continuation never got to run to merge it — a livelock
            // that left the style build unfinished for the whole session.
            self.upstreamTemplates.merge(resolved.sources.mapValues(\.upstreamTemplate)) { _, new in new }
            self.sources.merge(resolved.sources) { _, new in new }
            // The DEM source is ours, not the style's, so its upstream is known
            // here rather than from a TileJSON fetch. Both the loopback's
            // `/tiles/terrain/…` route and the slope generator read through it.
            self.upstreamTemplates[AppConfig.demSource] = config.terrainTileURL
            self.sources[AppConfig.demSource] = BasemapSource(
                name: AppConfig.demSource,
                format: .webp,
                upstreamTemplate: config.terrainTileURL
            )
            self.cache[key] = patched
            if let ceiling {
                // A ceiling is a floor of correctness, so a later variant that
                // resolved fewer of the style's sources must not lower it.
                // `outdoor` and `outdoor-with-terrain` resolve the same sources and
                // so report the same figure; taking the max rather than the latest
                // means a partial rebuild cannot quietly clamp the camera.
                self.zoomCeilings[style.rawValue] = self.zoomCeilings[style.rawValue].map {
                    max($0, ceiling)
                } ?? ceiling
            }
            print("StyleBuilder: \(key) merged sources \(resolved.sources.keys.sorted())")
            return (patched, resolved.sources, ceiling)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            print("StyleBuilder: \(key) awaiting build")
            let (patched, _, _) = try await task.value
            return patched
        } catch {
            print("StyleBuilder failed for \(key): \(error)")
            return nil
        }
    }

    /// The highest zoom the basemap for `style` is known to serve tiles for, or
    /// nil before it has been built.
    ///
    /// ## Why the camera needs to know
    ///
    /// MapTiler's `outdoor-v2` tops out at z14. Past it the renderer gets *empty*
    /// tiles, not overzoomed ones, so a camera that zooms to z16 frames nothing at
    /// all: a flat grey canvas in light mode, near-black in dark, with the route
    /// polyline floating on it because that is an overlay we draw ourselves. The
    /// web app has always capped its fit on `FIT_MAX_ZOOM`; the iOS fit did not,
    /// and a city-block route — the easy case — fits to z16 or z17, so the commonest
    /// thing the app can be asked to show was the one thing it could not.
    ///
    /// ## Why the highest source, not the lowest
    ///
    /// Because a source is overzoomed past *its own* ceiling and keeps drawing,
    /// while a style goes blank only once every source has stopped. The two
    /// basemaps are the case in point: `satellite-v4` pairs a deep imagery raster
    /// with a labels vector that stops at 14 like everything else MapTiler
    /// publishes, and it renders perfectly well past that — only the labels
    /// exhaust. Taking the minimum would clamp satellite to 14 as well and throw
    /// away the very zoom the imagery was there for.
    func maxZoom(for style: MapStyle) -> Double? {
        zoomCeilings[style.rawValue]
    }

    /// The highest `maxzoom` declared by a style's basemap sources, or nil when
    /// none declares one.
    ///
    /// Read off the patched style rather than the TileJSON responses so sources
    /// MapTiler inlined are counted too. `raster-dem` is skipped: it is elevation
    /// rather than imagery, it stops at z14 for its own reasons, and it is ours —
    /// letting it cap the camera would cap the camera at the elevation model's
    /// depth even on a basemap that draws past it.
    private static func styleZoomCeiling(_ patched: [String: Any]) -> Double? {
        guard let sources = patched["sources"] as? [String: Any] else { return nil }
        var ceilings: [Double] = []
        for raw in sources.values {
            guard let source = raw as? [String: Any],
                  let type = source["type"] as? String,
                  type == "vector" || type == "raster",
                  let number = source["maxzoom"] as? NSNumber
            else { continue }
            ceilings.append(number.doubleValue)
        }
        return ceilings.max()
    }

    /// MapTiler's tile URL template for a basemap source, waiting out any
    /// style build in flight before declaring the source unknown.
    ///
    /// The wait is the difference between a map and a blank one. MapLibre asks
    /// for tiles the moment it has a style — and that style can come straight
    /// out of its own resource cache while this process is still building the
    /// same style from the revalidation request that cache triggered. The tile
    /// then arrives here before `upstreamTemplates` has been merged, and a 404
    /// is final: MapLibre does not re-ask, so the source stays unfetched for
    /// the whole session. Waiting turns that race into an ordering; only a
    /// build that has genuinely come up empty answers 404.
    func upstreamTemplate(forSource source: String) async -> String? {
        if let template = upstreamTemplates[source] { return template }
        while let pending = building.values.first {
            _ = await style(for: pending.style, terrain: pending.terrain)
            if let template = upstreamTemplates[source] { return template }
            if building.isEmpty { break }
            // `style()` can return synchronously — the build it joined has
            // already completed and it simply has no template to give (a failed
            // build clears `building` only in the creator's defer, which cannot
            // run while this loop keeps the actor). Yield so that continuation
            // gets its turn; without it the loop spins in place at full CPU and
            // the creator never runs.
            await Task.yield()
        }
        return upstreamTemplates[source]
    }

    /// Every tile set the loaded style needs, so the corridor download covers
    /// what the map actually asks for.
    ///
    /// Read from the style rather than hardcoded, because the two basemaps
    /// differ: `outdoor-v2` has three vector sources, `satellite-v4` swaps one
    /// for a raster, and the elevation source is the same in both.
    func basemapSources() -> [BasemapSource] {
        sources.values.sorted { $0.name < $1.name }
    }

    // MARK: - Fetching

    private static func styleURLString(for style: MapStyle, config: MapTilerConfig) -> String {
        switch style {
        case .outdoor: config.mapStyleURL
        case .satellite: config.satelliteStyleURL
        }
    }

    private static func fetchStyle(
        for style: MapStyle,
        config: MapTilerConfig,
        session: URLSession
    ) async throws -> [String: Any] {
        guard let url = URL(string: styleURLString(for: style, config: config)) else {
            throw URLError(.badURL)
        }
        let data = try await fetch(url: url, session: session)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    /// Resolve every TileJSON-backed source into an inline `tiles` array, and
    /// return the upstream template and format for each.
    ///
    /// Both vector and raster sources go through here: the satellite basemap is
    /// a raster tileset, and an offline map that cached the labels but not the
    /// imagery under them would be a map of nowhere. The zoom range comes from
    /// the TileJSON and is kept; only the URL is repointed. A source that fails
    /// to resolve is left as MapTiler sent it, so one bad TileJSON cannot take
    /// the whole style down.
    private static func resolveTileSources(
        in style: [String: Any],
        session: URLSession
    ) async throws -> (style: [String: Any], sources: ResolvedSources) {
        var resolved = style
        guard var rawSources = resolved["sources"] as? [String: Any] else {
            return (resolved, [:])
        }
        var found: ResolvedSources = [:]

        for (id, raw) in rawSources {
            guard var source = raw as? [String: Any],
                  let type = source["type"] as? String,
                  type == "vector" || type == "raster",
                  let tileJSONURL = source["url"] as? String,
                  let url = URL(string: tileJSONURL)
            else { continue }

            guard let data = try? await fetch(url: url, session: session),
                  let tileJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let templates = tileJSON["tiles"] as? [String], let first = templates.first
            else {
                print("StyleBuilder: TileJSON failed for '\(id)' (\(tileJSONURL))")
                continue
            }

            source["tiles"] = [first]
            if let minzoom = tileJSON["minzoom"] { source["minzoom"] = minzoom }
            if let maxzoom = tileJSON["maxzoom"] { source["maxzoom"] = maxzoom }
            if let bounds = tileJSON["bounds"] { source["bounds"] = bounds }
            source.removeValue(forKey: "url")
            rawSources[id] = source
            found[id] = BasemapSource(
                name: id,
                format: TileFormat(rawValue: (tileJSON["format"] as? String) ?? "")
                    ?? (type == "vector" ? .pbf : .png),
                upstreamTemplate: first
            )
        }

        resolved["sources"] = rawSources
        return (resolved, found)
    }

    private static func fetch(url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(MapNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(MapNetworkIdentity.versionHeader, forHTTPHeaderField: "X-GPXNav-Version")
        let (data, response) = try await BoundedFetch.data(request, session: session)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Patching

    /// Point the tile sources at the loopback cache, and add the DEM source plus
    /// the terrain block.
    ///
    /// `formats` comes from the TileJSON resolution rather than being guessed
    /// here, because the extension is part of the loopback path: a raster
    /// source served as `.pbf` is a tile MapLibre cannot decode.
    static func patching(
        _ style: [String: Any],
        terrain: Bool,
        formats: [String: TileFormat]
    ) throws -> Data {
        var patched = style
        var sources = patched["sources"] as? [String: Any] ?? [:]

        for (id, raw) in sources {
            guard var source = raw as? [String: Any],
                  let type = source["type"] as? String,
                  type == "vector" || type == "raster"
            else { continue }
            let format = formats[id] ?? (type == "vector" ? .pbf : .png)
            source["tiles"] = [AppConfig.cachedTileURLTemplate(forSource: id, format: format)]
            source.removeValue(forKey: "url")
            sources[id] = source
        }

        // Named `terrain` to match the web app's source id, so the relief layer
        // and the terrain block refer to the same thing, and read through the
        // loopback so elevation is on disk like everything else. Inline tiles
        // rather than a TileJSON url, for the same reason the basemap sources
        // are resolved.
        sources[AppConfig.demSource] = [
            "type": "raster-dem",
            "tiles": [AppConfig.demTileURLTemplate],
            "tileSize": 512,
            "maxzoom": MapLayers.demMaxZoom,
            "encoding": "mapbox",
        ]
        patched["sources"] = sources

        if terrain {
            patched["terrain"] = [
                "source": AppConfig.demSource,
                "exaggeration": terrainExaggeration,
            ]
        } else {
            patched.removeValue(forKey: "terrain")
        }

        return try JSONSerialization.data(withJSONObject: patched)
    }
}

/// One tile set a loaded style depends on.
struct BasemapSource: Hashable, Sendable {
    /// The style's source id, which is also the loopback path segment and the
    /// prefix of its cache file.
    let name: String
    let format: TileFormat
    /// MapTiler's own `{z}/{x}/{y}` template for this tileset.
    let upstreamTemplate: String

    /// Elevation rather than map imagery. It is a different kind of tile — the
    /// loopback serves it as the `raster-dem` source, the hillshade layer reads
    /// it, and the slope generator decodes it — and it stops at z14, so a
    /// corridor download asks for it over a narrower range than the basemap.
    var isElevation: Bool { name == AppConfig.demSource }
}

/// Source id → the tile set it needs, as resolved from the style's TileJSON.
typealias ResolvedSources = [String: BasemapSource]

/// A data fetch that cannot hang, used by everything the app asks the network
/// for itself — the style build and the loopback's upstream tile fetches.
///
/// ## Why a deadline of its own
///
/// The tile proxy sits behind Cloudflare, which answers `Alt-Svc: h3=":443"`,
/// so after the first response in a session URLSession attempts the rest over
/// HTTP/3. On a network where UDP is dropped rather than refused, that attempt
/// neither completes nor fails: the request it is standing in for has been
/// observed sitting past every configured timeout, which leaves the style build
/// — and behind it every tile the map will ever draw — waiting on a connection
/// that will never come. CFNetwork's own fallback to TCP cannot be relied on to
/// arrive, so the attempt is cancelled outright and retried; a retry after a
/// cancelled attempt goes back over TCP, and any other transient failure gets
/// the same second chance instead of wedging the launch.
///
/// The deadline is enforced by racing the request against a sleep and
/// cancelling the loser, because cancelling `session.data(for:)` is the one
/// operation that reliably tears down a stalled attempt.
enum BoundedFetch {
    /// Seconds one attempt may take before it is cancelled and retried.
    static let attemptTimeout: Double = 10
    /// Attempts before the fetch gives up and rethrows the last failure.
    static let maxAttempts = 3

    /// `request`'s bytes, or the last error after `maxAttempts` tries.
    ///
    /// No status-code check here: an HTTP response is an answer, not a stall,
    /// and each caller decides for itself what a non-2xx means.
    static func data(
        _ request: URLRequest,
        session: URLSession,
        attempts: Int = maxAttempts
    ) async throws -> (Data, URLResponse) {
        let url = request.url
        let target = (url?.host ?? "?") + (url?.path ?? "")
        var lastError: Error = URLError(.unknown)
        for attempt in 1...attempts {
            let started = Date()
            do {
                let (data, response) = try await withTimeout(attemptTimeout) {
                    try await session.data(for: request)
                }
                let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                if let http = response as? HTTPURLResponse {
                    // Every failure is worth a line. Successes are only worth
                    // one for the style and TileJSON builds — the handful of
                    // requests the launch waits on — or when slow: a tile
                    // cache miss is common enough that logging each one would
                    // bury everything else.
                    let isStyleBuild = url?.path.hasSuffix("style.json") == true || url?.path.hasSuffix("tiles.json") == true
                    if isStyleBuild || Date().timeIntervalSince(started) >= 0.5 {
                        print("BoundedFetch: GET \(target) -> \(http.statusCode), \(data.count)B in \(seconds)s")
                    }
                }
                return (data, response)
            } catch {
                lastError = error
                let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                print("BoundedFetch: GET \(target) attempt \(attempt)/\(attempts) failed after \(seconds)s: \(error)")
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64((0.5 * Double(attempt)) * 1_000_000_000))
                }
            }
        }
        throw lastError
    }

    /// Run `work`, but not for longer than `seconds`.
    ///
    /// Exiting the group cancels whichever side lost, and cancelling the
    /// request side is what actually stops a stalled connection attempt.
    private static func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }
    }
}
