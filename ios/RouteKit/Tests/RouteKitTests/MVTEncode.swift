import Foundation
@testable import RouteKit

/// Minimal Mapbox Vector Tile *encoder* solely for tests/fixtures, so the
/// decoder in `MVT.swift` is validated against real protobuf bytes — the same
/// role `web/tests/helpers/mvtEncode.ts` plays on the web. Geometry is written
/// in tile-pixel space (extent units) with zig-zag delta commands.
enum MVTEncode {
    struct FixtureFeature {
        var type: Int
        var props: [String: MVT.Value]
        var parts: [[MVT.Pixel]]
        /// Append a ClosePath command after each part with 3+ points.
        var close = false

        init(type: Int, props: [String: MVT.Value] = [:], parts: [[MVT.Pixel]], close: Bool = false) {
            self.type = type
            self.props = props
            self.parts = parts
            self.close = close
        }
    }

    struct FixtureLayer {
        var name: String
        var extent: Int?
        var features: [FixtureFeature]
    }

    static func varint(_ value: Int) -> [UInt8] {
        precondition(value >= 0, "Negative varints unsupported in test encoder")
        var bytes: [UInt8] = []
        var v = UInt64(value)
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
        return bytes
    }

    static func zigzag(_ value: Int) -> Int {
        (value << 1) ^ (value >> 63)
    }

    static func tag(_ field: Int, wireType: Int) -> [UInt8] {
        varint((field << 3) | wireType)
    }

    static func lenBytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, wireType: 2) + varint(payload.count) + payload
    }

    static func stringBytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func valueBytes(_ value: MVT.Value) -> [UInt8] {
        var inner: [UInt8] = []
        switch value {
        case .string(let text):
            inner += lenBytes(1, stringBytes(text))
        case .bool(let flag):
            inner += tag(7, wireType: 0) + varint(flag ? 1 : 0)
        case .number(let n):
            if n >= 0, n == n.rounded(), n < Double(Int.max) {
                inner += tag(5, wireType: 0) + varint(Int(n))
            } else {
                inner += tag(4, wireType: 0) + varint(Int(n))
            }
        }
        return lenBytes(4, inner)
    }

    static func geometryBytes(_ parts: [[MVT.Pixel]], close: Bool = false) -> [UInt8] {
        var packed: [UInt8] = []
        var cursorX = 0
        var cursorY = 0
        for part in parts {
            guard let first = part.first else { continue }
            packed += varint((1 << 3) | 1) // MoveTo, one point
            packed += varint(zigzag(first.x - cursorX)) + varint(zigzag(first.y - cursorY))
            cursorX = first.x
            cursorY = first.y
            if part.count >= 2 {
                packed += varint(((part.count - 1) << 3) | 2) // LineTo
            }
            for pixel in part.dropFirst() {
                packed += varint(zigzag(pixel.x - cursorX)) + varint(zigzag(pixel.y - cursorY))
                cursorX = pixel.x
                cursorY = pixel.y
            }
            if close && part.count >= 3 {
                packed += varint((1 << 3) | 7) // ClosePath
                cursorX = 0
                cursorY = 0
            }
        }
        return varint((4 << 3) | 2) + varint(packed.count) + packed
    }

    static func encodeLayer(_ layer: FixtureLayer) -> [UInt8] {
        var keys: [String] = []
        var values: [MVT.Value] = []
        var valueIndexes: [String: Int] = [:]
        var keyIndexes: [String: Int] = [:]

        for feature in layer.features {
            for key in feature.props.keys where keyIndexes[key] == nil {
                keyIndexes[key] = keys.count
                keys.append(key)
            }
        }

        var features: [UInt8] = []
        for feature in layer.features {
            var inner: [UInt8] = []
            inner += tag(3, wireType: 0) + varint(feature.type)
            var tagPairs: [UInt8] = []
            for (key, raw) in feature.props {
                let ki = keyIndexes[key]!
                let rawKey = String(describing: raw)
                let vi: Int
                if let existing = valueIndexes[rawKey] {
                    vi = existing
                } else {
                    vi = values.count
                    values.append(raw)
                    valueIndexes[rawKey] = vi
                }
                tagPairs += varint(ki) + varint(vi)
            }
            if !tagPairs.isEmpty { inner += lenBytes(2, tagPairs) }
            inner += geometryBytes(feature.parts, close: feature.close)
            features += lenBytes(2, inner)
        }

        var layerBytes: [UInt8] = []
        layerBytes += lenBytes(1, stringBytes(layer.name))
        // Emit features before keys/values, matching MapTiler's real tiles, so
        // the decoder must resolve tags in a second pass.
        layerBytes += features
        layerBytes += tag(5, wireType: 0) + varint(layer.extent ?? 4096)
        for key in keys { layerBytes += lenBytes(3, stringBytes(key)) }
        for value in values { layerBytes += valueBytes(value) }

        return lenBytes(3, layerBytes)
    }

    static func encodeTile(_ layers: [FixtureLayer]) -> Data {
        var tile: [UInt8] = []
        for layer in layers { tile += encodeLayer(layer) }
        return Data(tile)
    }

    /// Inverse of `MVT.tilePointToCoordinate`: lng/lat → tile-pixel offsets.
    static func lngLatToTilePx(
        lng: Double,
        lat: Double,
        z: Int,
        x: Int,
        y: Int,
        extent: Int
    ) -> (px: Double, py: Double) {
        let world = pow(2, Double(z))
        let fx = ((lng + 180) / 360) * world
        let sinLat = sin(lat * .pi / 180)
        let fy = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * world
        return (px: (fx - Double(x)) * Double(extent), py: (fy - Double(y)) * Double(extent))
    }

    /// The integer tile a lng/lat falls in — `SnapTiles.fractionalTile`'s floor.
    static func tileCoordsFor(lng: Double, lat: Double, z: Int) -> (x: Int, y: Int) {
        let fractional = SnapTiles.fractionalTile(lng: lng, lat: lat, zoom: z)
        return (x: fractional.x, y: fractional.y)
    }
}
