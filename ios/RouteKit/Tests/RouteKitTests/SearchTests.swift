import XCTest
@testable import RouteKit

/// Port of `web/tests/geocode.test.ts`.
final class SearchTests: XCTestCase {
    let townFeature: [String: Any] = [
        "id": "municipality.46425",
        "text": "Chamonix-Mont-Blanc",
        "place_name": "Chamonix-Mont-Blanc, France",
        "place_type": ["municipality"],
        "properties": ["place_designation": "town"],
        "geometry": ["type": "Point", "coordinates": [6.8694, 45.9237]],
        "bbox": [6.752, 45.87, 7.052, 46.09],
    ]

    let peakFeature: [String: Any] = [
        "id": "poi.123",
        "text": "Little Bear Peak",
        "place_name": "Little Bear Peak, Alamosa, United States",
        "place_type": ["poi"],
        "properties": [
            "categories": ["peak"],
            "feature_tags": ["natural": "peak", "ele": "4280"]
        ],
        "geometry": ["type": "Point", "coordinates": [-105.497, 37.567]],
        "context": [
            ["id": "county.23768", "text": "Alamosa"],
            ["id": "region.2138", "text": "Colorado"],
            ["id": "country.213", "text": "United States"]
        ],
    ]

    let peakWithoutCounty: [String: Any] = [
        "id": "poi.123",
        "text": "Little Bear Peak",
        "place_name": "Little Bear Peak, Alamosa, United States",
        "place_type": ["poi"],
        "properties": ["categories": ["peak"], "feature_tags": ["natural": "peak", "ele": "4280"]],
        "geometry": ["type": "Point", "coordinates": [-105.497, 37.567]],
        "context": [
            ["id": "region.2138", "text": "Colorado"],
            ["id": "country.213", "text": "United States"]
        ],
    ]

    let peakWithoutElevation: [String: Any] = [
        "id": "poi.123",
        "text": "Little Bear Peak",
        "place_name": "Little Bear Peak, Alamosa, United States",
        "place_type": ["poi"],
        "properties": ["categories": ["peak"]],
        "geometry": ["type": "Point", "coordinates": [-105.497, 37.567]],
        "context": [
            ["id": "county.23768", "text": "Alamosa"],
            ["id": "region.2138", "text": "Colorado"],
            ["id": "country.213", "text": "United States"]
        ],
    ]

    let trailFeature: [String: Any] = [
        "id": "address.24163432",
        "text": "Eagle Valley Trail",
        "place_name": "Eagle Valley Trail, Eagle, Colorado 81631, United States",
        "place_type": ["address"],
        "properties": ["kind": "street"],
        "geometry": ["type": "Point", "coordinates": [-106.5471, 39.6365]],
        "bbox": [-106.8, 39.5, -106.3, 39.7],
        "context": [
            ["id": "county.144", "text": "Eagle"],
            ["id": "region.2138", "text": "Colorado"],
            ["id": "country.213", "text": "United States"]
        ],
    ]

    let trailheadFeature: [String: Any] = [
        "id": "poi.4242",
        "text": "Kilpacker Trailhead",
        "place_name": "Kilpacker Trailhead, Dolores, Colorado, United States",
        "place_type": ["poi"],
        "properties": ["categories": ["parking"], "feature_tags": ["amenity": "parking"]],
        "geometry": ["type": "Point", "coordinates": [-108.06, 37.79]],
    ]

    let backcountryRoadFeature: [String: Any] = [
        "id": "address.555",
        "text": "Lead King Basin Road",
        "place_name": "Lead King Basin Road, Gunnison, Colorado, United States",
        "place_type": ["address"],
        "properties": ["kind": "street"],
        "geometry": ["type": "Point", "coordinates": [-107.13, 39.08]],
    ]

    func testGeocodeURL() {
        let url = geocodeURL(query: "Mount Rainier", apiKey: "test-key")
        XCTAssertTrue(url.hasPrefix("https://api.maptiler.com/geocoding/Mount%20Rainier.json"))
        XCTAssertTrue(url.contains("types=\(geocodeTypes)"))
        XCTAssertTrue(url.contains("address"))
        XCTAssertTrue(url.contains("limit=6"))
        XCTAssertFalse(url.contains("proximity="))
    }

    func testGeocodeURLWithProximity() {
        let url = geocodeURL(query: "Mount Rainier", options: GeocodeOptions(proximity: Coordinate(lat: 46.8523, lon: -121.7576)), apiKey: "test-key")
        XCTAssertTrue(url.contains("proximity=-121.7576,46.8523"))
    }

    func testPlaceTypeLabel() {
        XCTAssertEqual(placeTypeLabel("place", "village"), "Village")
        XCTAssertEqual(placeTypeLabel("place", "town"), "Town")
        XCTAssertEqual(placeTypeLabel("municipality", nil), "Municipality")
        XCTAssertEqual(placeTypeLabel("poi", nil), "Point of interest")
        XCTAssertEqual(placeTypeLabel("major_landform", nil), "Mountain range / landform")
        XCTAssertEqual(placeTypeLabel(nil, nil), "Place")
        XCTAssertEqual(placeTypeLabel("unknown_kind", nil), "Place")
    }

    func testNormalizeFeatureTown() {
        let result = normalizeFeature(townFeature)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, "municipality.46425")
        XCTAssertEqual(result?.name, "Chamonix-Mont-Blanc")
        XCTAssertEqual(result?.region, "France")
        XCTAssertEqual(result?.typeLabel, "Town")
        XCTAssertEqual(result?.center, Coordinate(lat: 45.9237, lon: 6.8694))
        XCTAssertEqual(result?.bbox, [6.752, 45.87, 7.052, 46.09])
    }

    func testNormalizeFeaturePeak() {
        let result = normalizeFeature(peakFeature)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.region, "Alamosa, Colorado, USA")
        XCTAssertEqual(result?.typeLabel, "Peak")
        XCTAssertEqual(result?.elevation, 4280)
        XCTAssertNil(result?.bbox)
    }

    func testNormalizeFeaturePeakWithoutCounty() {
        let result = normalizeFeature(peakWithoutCounty)
        XCTAssertEqual(result?.region, "Colorado, USA")
    }

    func testNormalizeFeaturePeakWithoutElevation() {
        let result = normalizeFeature(peakWithoutElevation)
        XCTAssertNil(result?.elevation)
    }

    func testNormalizeFeatureTrail() {
        let result = normalizeFeature(trailFeature)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.typeLabel, "Trail")
        XCTAssertEqual(result?.name, "Eagle Valley Trail")
        XCTAssertEqual(result?.region, "Eagle, Colorado, USA")
        XCTAssertEqual(result?.bbox, [-106.8, 39.5, -106.3, 39.7])
    }

    func testNormalizeFeatureTrailhead() {
        let result = normalizeFeature(trailheadFeature)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.typeLabel, "Trailhead")
        XCTAssertEqual(result?.name, "Kilpacker Trailhead")
    }

    func testNormalizeFeatureBackcountryRoad() {
        let result = normalizeFeature(backcountryRoadFeature)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.typeLabel, "Street")
        XCTAssertEqual(result?.name, "Lead King Basin Road")
    }

    func testNormalizeFeatureSkipsNonPoint() {
        let feature: [String: Any] = ["geometry": ["type": "LineString", "coordinates": []]]
        XCTAssertNil(normalizeFeature(feature))
    }

    func testNormalizeFeatureSkipsInvalidCoordinates() {
        XCTAssertNil(normalizeFeature(["geometry": ["type": "Point", "coordinates": []]]))
        XCTAssertNil(normalizeFeature(["geometry": ["type": "Point", "coordinates": ["x", 1]]]))
    }
}