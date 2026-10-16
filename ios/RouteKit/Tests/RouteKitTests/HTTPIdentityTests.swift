import XCTest
@testable import RouteKit

/// The gap this covers: MapTiler keys are recommended here to be restricted to an
/// allowed `User-Agent`, because a native app can never satisfy a referrer
/// allowlist. Tiles, the DEM tileset and offline prefetch all go through MapLibre
/// and were already sending it. Geocoding and these DEM samples did not, so a
/// correctly-restricted key loaded the map and refused everything else.
final class HTTPIdentityTests: XCTestCase {

    func testTheAllowlistedAgentIsSent() {
        XCTAssertEqual(
            HTTPHeaders.forIdentifyingAs(userAgent: "GPXNav (iOS; com.example.GPXNav)"),
            ["User-Agent": "GPXNav (iOS; com.example.GPXNav)"]
        )
    }

    /// No identity means "leave the session's own default alone", not "send an
    /// empty one" -- an empty header is a different string to match against, and
    /// would fail an allowlist just as surely as no header at all.
    func testNoAgentMeansNoHeaders() {
        XCTAssertTrue(HTTPHeaders.forIdentifyingAs(userAgent: nil).isEmpty)
        XCTAssertTrue(HTTPHeaders.forIdentifyingAs(userAgent: "").isEmpty)
    }

    /// The value has to survive being handed around untouched: MapTiler matches
    /// the whole header when the allowlist is a plain string, so a stray space or
    /// a version suffix appended here breaks the key at release time rather than
    /// at build time.
    func testTheValueIsSentExactlyAsGiven() {
        let token = "GPXNav (iOS; com.example.GPXNav)"
        let headers = HTTPHeaders.forIdentifyingAs(userAgent: token)
        XCTAssertEqual(headers["User-Agent"], token)
        XCTAssertEqual(headers.count, 1)
    }

    /// Belt and braces around the client itself: building the session must not
    /// throw, whichever branch it takes, and a string that is not a usable URL
    /// must surface as a `URLError`.
    ///
    /// Deliberately not pinning *which* `URLError`. `"not a url"` has no scheme,
    /// which `URL(string:)` accepts as a relative reference, so it reaches
    /// `URLSession` and comes back `unsupportedURL`; a string it does reject
    /// would be `badURL` instead. Both are correct answers to the same question
    /// and the split is an implementation detail of `URL` parsing.
    func testTheClientSurfacesAURLErrorForAnUnusableURL() async {
        let client = DefaultHTTPClient(userAgent: "GPXNav (iOS; com.example.GPXNav)")
        do {
            _ = try await client.data(from: "not a url")
            XCTFail("expected a URLError")
        } catch is URLError {
            // Which code, depends on how far the string got.
        } catch {
            XCTFail("expected URLError, got \(error)")
        }
    }
}