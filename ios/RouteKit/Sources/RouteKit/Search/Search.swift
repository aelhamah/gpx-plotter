import Foundation

/// Place types the app surfaces in search: municipalities, towns, peaks/POIs,
/// mountain ranges, and `address`. MapTiler indexes named trails, paths, and
/// backcountry roads under `address` (kind `street`), so including it is what
/// makes trail names ("Boneyard Trail") and places like "Lead King Basin Road"
/// searchable. Named trails are relabeled "Trail" in `normalizeFeature`.
public let geocodeTypes = "municipality,place,locality,poi,major_landform,address"

public struct GeocodeOptions: Equatable, Sendable {
    public var limit: Int
    /// Current map position (lon/lat); the API biases result ranking toward it.
    public var proximity: Coordinate?

    public init(limit: Int = 10, proximity: Coordinate? = nil) {
        self.limit = limit
        self.proximity = proximity
    }
}

public struct GeocodeResult: Equatable, Sendable {
    public var id: String
    public var name: String
    public var region: String
    public var typeLabel: String
    /// MapTiler's score for how well the name matches the query, when it sent one.
    public var relevance: Double?
    /// Peak summit elevation in meters, when the feature is a peak.
    public var elevation: Double?
    public var center: Coordinate
    public var bbox: [Double]?

    public init(id: String, name: String, region: String, typeLabel: String, relevance: Double? = nil, elevation: Double?, center: Coordinate, bbox: [Double]?) {
        self.id = id
        self.name = name
        self.region = region
        self.typeLabel = typeLabel
        self.relevance = relevance
        self.elevation = elevation
        self.center = center
        self.bbox = bbox
    }
}

private let typeLabels: [String: String] = [
    "municipality": "Municipality",
    "locality": "Locality",
    "place": "Place",
    "poi": "Point of interest",
    "major_landform": "Mountain range / landform",
    "country": "Country",
    "region": "Region",
    "county": "County",
    "city": "City",
    "town": "Town",
    "village": "Village",
    "hamlet": "Hamlet",
]

private let settlementTypes: Set<String> = ["municipality", "place", "locality"]
private let shortCountry: [String: String] = ["United States": "USA", "United Kingdom": "UK"]

/// Named trails/paths are indexed as `address` features; this flags the trail-like ones.
/// Case-insensitive, matching the web version's `/trail|path|.../i`.
private let trailNamePattern = "trail|path|loop|greenway|walkway|footpath"
/// Trailheads are POIs whose name contains "trailhead".
private let trailheadNamePattern = "trailhead"

private let nameMatchOptions: String.CompareOptions = [.regularExpression, .caseInsensitive]

/// Relevance below this is a loose match, worth asking again without decoration.
public let STRONG_MATCH_RELEVANCE: Double = 0.9

/// Words that decorate a park or land designation without naming it.
private let decorativeWords: Set<String> = [
    "national", "state", "provincial", "regional", "county",
    "recreation", "conservation", "wilderness", "wildlife",
    "monument", "memorial", "historic", "historical",
    "park", "parks", "forest", "forests", "preserve", "refuge", "reserve", "reserves",
    "area", "areas",
]

/// Human-friendly badge for a feature's kind; prefer the OSM place designation when known.
public func placeTypeLabel(_ placeType: String?, _ placeDesignation: String?) -> String {
    if let placeDesignation, let label = typeLabels[placeDesignation] { return label }
    if let placeType, let label = typeLabels[placeType] { return label }
    return "Place"
}

/// Short disambiguation text (context after the matched name).
private func regionText(name: String, placeName: String) -> String {
    if !name.isEmpty && placeName.hasPrefix(name) {
        let rest = String(placeName.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        let source = rest.isEmpty ? placeName : rest
        return source.replacingOccurrences(of: "^Columbia(,|$)", with: "District of Columbia$1", options: .regularExpression)
    }
    return placeName.replacingOccurrences(of: "^Columbia(,|$)", with: "District of Columbia$1", options: .regularExpression)
}

/// Compact country label, e.g. "United States" → "USA".
private func countryLabel(_ context: [String: String]?) -> String {
    let text = context?["text"] ?? context?["country"] ?? ""
    return shortCountry[text] ?? text
}

/// Administrative region from the feature's context hierarchy.
private func regionFromContext(_ context: [[String: String]]) -> String {
    let county = context.first { $0["id"]?.hasPrefix("county.") == true }?["text"]
    let regionContext = context.first { $0["id"]?.hasPrefix("region.") == true }
    let countryContext = context.first { $0["id"]?.hasPrefix("country.") == true }
    let region: String?
    if regionContext?["text"] == "Columbia",
       countryContext?["text"] == "United States" {
        region = "District of Columbia"
    } else {
        region = regionContext?["text"]
    }
    let country = countryContext
    let parts = [county, region, country.map { shortCountry[$0["text"] ?? ""] ?? ($0["text"] ?? "") }].compactMap { $0 }
    return parts.joined(separator: ", ")
}

/// Map a raw MapTiler geocoding feature to our normalized result; nil when unusable.
public func normalizeFeature(_ feature: [String: Any]) -> GeocodeResult? {
    guard let geometry = feature["geometry"] as? [String: Any],
          geometry["type"] as? String == "Point",
          let coordinates = geometry["coordinates"] as? [Double],
          coordinates.count >= 2,
          let lon = coordinates[0] as Double?,
          let lat = coordinates[1] as Double?,
          lon.isFinite, lat.isFinite
    else { return nil }

    let placeName = (feature["place_formatted"] as? String) ?? (feature["place_name"] as? String) ?? ""
    let name = (feature["text"] as? String) ?? placeName
    let placeType = (feature["place_type"] as? [String])?.first

    let properties = feature["properties"] as? [String: Any]
    let placeDesignation = properties?["place_designation"] as? String
    let categories = properties?["categories"] as? [String] ?? []
    let featureTags = properties?["feature_tags"] as? [String: String] ?? [:]
    let context = (feature["context"] as? [[String: String]]) ?? []

    let isAddress = (feature["place_type"] as? [String])?.contains("address") ?? false
    let isTrail = isAddress && name.range(of: trailNamePattern, options: nameMatchOptions) != nil
    let isSettlement = placeType.map { settlementTypes.contains($0) } ?? false

    let region = isSettlement ? regionText(name: name, placeName: placeName) : regionFromContext(context)

    let natural = featureTags["natural"]
    let isPeak = natural == "peak" || categories.contains("peak")
    let isTrailhead = !isPeak && placeType == "poi" && name.range(of: trailheadNamePattern, options: nameMatchOptions) != nil

    let typeLabel: String
    if isPeak {
        typeLabel = "Peak"
    } else if isTrailhead {
        typeLabel = "Trailhead"
    } else if isTrail {
        typeLabel = "Trail"
    } else if isAddress {
        typeLabel = "Street"
    } else {
        typeLabel = placeTypeLabel(placeType, placeDesignation)
    }

    let elevation: Double?
    if isPeak, let eleStr = featureTags["ele"], let ele = Double(eleStr), ele > 0 {
        elevation = ele
    } else {
        elevation = nil
    }

    let bbox: [Double]?
    if let bboxArray = feature["bbox"] as? [Double], bboxArray.count >= 4 {
        bbox = Array(bboxArray.prefix(4))
    } else {
        bbox = nil
    }

    let relevance: Double?
    if let raw = feature["relevance"] as? Double, raw.isFinite {
        relevance = raw
    } else {
        relevance = nil
    }

    return GeocodeResult(
        id: (feature["id"] as? String) ?? "\(lon),\(lat)",
        name: name,
        region: region,
        typeLabel: typeLabel,
        relevance: relevance,
        elevation: elevation,
        center: Coordinate(lat: lat, lon: lon),
        bbox: bbox
    )
}

public func relaxedQuery(_ query: String) -> String? {
    let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        .map(String.init)
    guard let index = words.firstIndex(where: { decorativeWords.contains($0.lowercased()) }) else {
        return nil
    }
    let relaxed = (words[words.startIndex..<index] + words[index.advanced(by: 1)...]).map { $0 }
    let asksSomething = relaxed.contains { !decorativeWords.contains($0.lowercased()) }
    return asksSomething ? relaxed.joined(separator: " ") : nil
}

private func topRelevance(_ results: [GeocodeResult]) -> Double {
    max(0, results.compactMap(\.relevance).max() ?? 0)
}

public func rankSearchResults(_ results: [GeocodeResult], center: Coordinate?) -> [GeocodeResult] {
    let distances: [Int: Double]? = center.map { center in
        var map: [Int: Double] = [:]
        for (index, result) in results.enumerated() {
            map[index] = Haversine.meters(from: center, to: result.center)
        }
        return map
    }

    let ranked: [GeocodeResult]
    if let distances {
        ranked = results.enumerated().sorted { left, right in
            let leftRelevance = results[left.offset].relevance ?? -Double.infinity
            let rightRelevance = results[right.offset].relevance ?? -Double.infinity
            if leftRelevance != rightRelevance {
                return leftRelevance > rightRelevance
            }
            return (distances[left.offset] ?? Double.infinity) < (distances[right.offset] ?? Double.infinity)
        }.map { results[$0.offset] }
    } else {
        ranked = results
    }

    var seen = Set<String>()
    var output: [GeocodeResult] = []
    for result in ranked {
        let key = "\(result.name)\u{0}\(result.typeLabel)"
        if seen.contains(key) { continue }
        seen.insert(key)
        output.append(result)
    }
    return output
}

/// Build the MapTiler geocoding URL for a query.
///
/// Goes to the tile proxy, which holds the key — see `MapTilerConfig`.
public func geocodeURL(query: String, options: GeocodeOptions = GeocodeOptions(), baseURL: String) -> String {
    let round5 = { (value: Double) in (value * 100000).rounded() / 100000 }
    var params = [
        "limit=\(options.limit)",
        "types=\(geocodeTypes)",
        "autocomplete=false"
    ]
    if let proximity = options.proximity {
        params.append("proximity=\(round5(proximity.lon)),\(round5(proximity.lat))")
    }
    let encodedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    return "\(baseURL)/geocoding/\(encodedQuery).json?\(params.joined(separator: "&"))"
}

/// Geocoding client for MapTiler.
public actor GeocodingClient {
    private let httpClient: HTTPClient
    private let baseURL: String

    public init(httpClient: HTTPClient = DefaultHTTPClient(), baseURL: String) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    /// Forward-geocode a query; returns [] on empty input, HTTP errors, or network failure.
    public func geocode(_ query: String, options: GeocodeOptions = GeocodeOptions()) async -> [GeocodeResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let url = geocodeURL(query: trimmed, options: options, baseURL: baseURL)

        do {
            let (data, response) = try await httpClient.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let features = (json?["features"] as? [[String: Any]]) ?? []
            return features.compactMap { normalizeFeature($0) }
        } catch {
            return []
        }
    }

    /// Forward-geocode with decorative-word fallback, matching the web app.
    public func geocodeWithFallback(_ query: String, options: GeocodeOptions = GeocodeOptions()) async -> [GeocodeResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        var asked = trimmed
        var best = await geocode(asked, options: options)
        var bestScore = topRelevance(best)

        for _ in 0..<2 where bestScore < STRONG_MATCH_RELEVANCE {
            guard let relaxed = relaxedQuery(asked), relaxed != asked else { break }
            asked = relaxed
            let retry = await geocode(relaxed, options: options)
            let retryScore = topRelevance(retry)
            if retryScore > bestScore {
                best = retry
                bestScore = retryScore
            }
        }

        return best
    }
}
