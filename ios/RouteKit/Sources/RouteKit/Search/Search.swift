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

    public init(limit: Int = 6, proximity: Coordinate? = nil) {
        self.limit = limit
        self.proximity = proximity
    }
}

public struct GeocodeResult: Equatable, Sendable {
    public var id: String
    public var name: String
    public var region: String
    public var typeLabel: String
    /// Peak summit elevation in meters, when the feature is a peak.
    public var elevation: Double?
    public var center: Coordinate
    public var bbox: [Double]?

    public init(id: String, name: String, region: String, typeLabel: String, elevation: Double?, center: Coordinate, bbox: [Double]?) {
        self.id = id
        self.name = name
        self.region = region
        self.typeLabel = typeLabel
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
        return rest.isEmpty ? placeName : rest
    }
    return placeName
}

/// Compact country label, e.g. "United States" → "USA".
private func countryLabel(_ context: [String: String]?) -> String {
    let text = context?["country"] ?? ""
    return shortCountry[text] ?? text
}

/// Administrative region from the feature's context hierarchy.
private func regionFromContext(_ context: [[String: String]]) -> String {
    let county = context.first { $0["id"]?.hasPrefix("county.") == true }?["text"]
    let region = context.first { $0["id"]?.hasPrefix("region.") == true }?["text"]
    let country = context.first { $0["id"]?.hasPrefix("country.") == true }?["text"]
    let parts = [county, region, country.map { shortCountry[$0] ?? $0 }].compactMap { $0 }
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

    let isAddress = (feature["place_type"] as? [String])?.contains("address") ?? false
    let isTrail = isAddress && name.range(of: trailNamePattern, options: nameMatchOptions) != nil
    let isSettlement = placeType.map { settlementTypes.contains($0) } ?? false

    let region = isSettlement ? regionText(name: name, placeName: placeName) : regionFromContext(
        (feature["context"] as? [[String: String]]) ?? []
    )

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

    return GeocodeResult(
        id: (feature["id"] as? String) ?? "\(lon),\(lat)",
        name: name,
        region: region,
        typeLabel: typeLabel,
        elevation: elevation,
        center: Coordinate(lat: lat, lon: lon),
        bbox: bbox
    )
}

/// Build the MapTiler geocoding URL for a query.
public func geocodeURL(query: String, options: GeocodeOptions = GeocodeOptions(), apiKey: String) -> String {
    let round5 = { (value: Double) in (value * 100000).rounded() / 100000 }
    var params = [
        "key=\(apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
        "limit=\(options.limit)",
        "types=\(geocodeTypes)"
    ]
    if let proximity = options.proximity {
        params.append("proximity=\(round5(proximity.lon)),\(round5(proximity.lat))")
    }
    let encodedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    return "https://api.maptiler.com/geocoding/\(encodedQuery).json?\(params.joined(separator: "&"))"
}

/// Geocoding client for MapTiler.
public actor GeocodingClient {
    private let httpClient: HTTPClient
    private let apiKey: String

    public init(httpClient: HTTPClient = DefaultHTTPClient(), apiKey: String) {
        self.httpClient = httpClient
        self.apiKey = apiKey
    }

    /// Forward-geocode a query; returns [] on empty input, HTTP errors, or network failure.
    public func geocode(_ query: String, options: GeocodeOptions = GeocodeOptions()) async -> [GeocodeResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let url = geocodeURL(query: trimmed, options: options, apiKey: apiKey)

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
}