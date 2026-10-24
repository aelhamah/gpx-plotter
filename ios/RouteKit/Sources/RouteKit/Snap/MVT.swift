import Foundation

/// Minimal Mapbox Vector Tile decoder.
///
/// Port of the web app's `web/src/mvt.ts`, byte-for-byte in behaviour, so the
/// snap tests on both platforms decode the same tiles the same way.
///
/// MapTiler's `outdoor` and `v3` (planet) tilesets are served as gzipped .pbf;
/// callers pass the *decompressed* bytes in here — `URLSession` decompresses
/// gzip transparently on the way in. A whole tile at snap zoom is only a few KB,
/// so decoding it per tap is cheap, and the decoded result is LRU-cached by
/// `SnapEngine` anyway.
///
/// Output geometry stays in tile pixel space (integer offsets against the
/// layer's `extent`, y-down, origin at the tile's top-left); convert to
/// lat/lon with `MVT.tilePointToCoordinate`.
public enum MVT {
    public enum Value: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)

        /// The value as the snap filters want it: a string, or nil.
        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        /// The value as a finite number, or nil.
        public var numberValue: Double? {
            if case .number(let n) = self, n.isFinite { return n }
            return nil
        }
    }

    /// One vertex in tile pixel space. A struct rather than a tuple because
    /// Swift cannot synthesize `Equatable` for a type whose stored properties
    /// are tuples, and the decode tests compare geometry part-for-part.
    public struct Pixel: Equatable, Hashable, Sendable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public struct Feature: Equatable, Sendable {
        public var id: UInt64?
        /// 1 = Point, 2 = LineString, 3 = Polygon (vector-tile spec).
        public var type: Int
        public var props: [String: Value]
        /// Geometry as one or more parts; each part is a list of tile pixels.
        public var parts: [[Pixel]]

        public init(id: UInt64? = nil, type: Int, props: [String: Value] = [:], parts: [[Pixel]] = []) {
            self.id = id
            self.type = type
            self.props = props
            self.parts = parts
        }
    }

    public struct Layer: Equatable, Sendable {
        public var name: String
        public var extent: Int
        public var features: [Feature]

        public init(name: String, extent: Int, features: [Feature]) {
            self.name = name
            self.extent = extent
            self.features = features
        }
    }

    static let defaultExtent = 4096

    // MARK: - Byte reader

    /// A bounds-checked cursor over protobuf wire bytes.
    ///
    /// The web decoder grew its own `Reader` class for the same reason: the MVT
    /// wire format is varints and length-delimited fields all the way down, and
    /// a full protobuf runtime would be a dependency for ~150 lines of reading.
    struct Reader {
        let bytes: [UInt8]
        var pos = 0

        init(_ data: Data) {
            self.bytes = [UInt8](data)
        }

        init(_ slice: ArraySlice<UInt8>) {
            self.bytes = Array(slice)
        }

        var done: Bool { pos >= bytes.count }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard pos < bytes.count else { throw MVTError.truncated }
                let byte = bytes[pos]
                pos += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                if shift > 63 { throw MVTError.varintTooLong }
            }
            return result
        }

        mutating func readVarintAsInt() throws -> Int {
            let value = try readVarint()
            guard value <= UInt64(Int.max) else { throw MVTError.varintTooLong }
            return Int(value)
        }

        mutating func readBytes() throws -> ArraySlice<UInt8> {
            let length = try readVarintAsInt()
            guard length >= 0, pos + length <= bytes.count else { throw MVTError.truncated }
            let slice = bytes[pos..<(pos + length)]
            pos += length
            return slice
        }

        mutating func readString() throws -> String {
            String(decoding: try readBytes(), as: UTF8.self)
        }

        mutating func readFixed32() throws -> UInt32 {
            guard pos + 4 <= bytes.count else { throw MVTError.truncated }
            var value: UInt32 = 0
            for i in 0..<4 {
                value |= UInt32(bytes[pos + i]) << (8 * i)
            }
            pos += 4
            return value
        }

        mutating func readFloat32() throws -> Float {
            Float(bitPattern: try readFixed32())
        }

        mutating func skipFixed64() throws {
            guard pos + 8 <= bytes.count else { throw MVTError.truncated }
            pos += 8
        }
    }

    public enum MVTError: Error, Equatable {
        case truncated
        case varintTooLong
        case unsupportedWireType(UInt64)
    }

    struct TaggedField {
        var field: Int
        var wireType: Int
    }

    static func tagField(_ reader: inout Reader) throws -> TaggedField {
        let tag = try reader.readVarint()
        return TaggedField(field: Int(tag >> 3), wireType: Int(tag & 0x7))
    }

    static func skipField(_ reader: inout Reader, wireType: Int) throws {
        switch wireType {
        case 0: _ = try reader.readVarint()
        case 1: try reader.skipFixed64()
        case 2: _ = try reader.readBytes()
        case 5: _ = try reader.readFixed32()
        default: throw MVTError.unsupportedWireType(UInt64(wireType))
        }
    }

    /// Zig-zag decode (MVT geometry deltas and sint values are zig-zagged).
    static func zigzag(_ value: UInt64) -> Int {
        // The shift-based formulation, portable to 64-bit Int:
        // (v >>> 1) ^ -(v & 1) — arithmetic on the bit pattern.
        let shifted = Int(bitPattern: UInt(value) >> 1)
        return Int(value & 1) == 1 ? ~shifted : shifted
    }

    // MARK: - Value / geometry / layer decoding

    static func decodeValue(_ data: ArraySlice<UInt8>) throws -> Value {
        var reader = Reader(data)
        // `true` is the web decoder's default for a value with no recognisable
        // field; kept so an odd Value message still yields *something*.
        var value = Value.bool(true)
        while !reader.done {
            let tag = try tagField(&reader)
            if tag.wireType == 0 {
                let raw = try reader.readVarint()
                switch tag.field {
                case 4: value = .number(Double(raw)) // int_value
                case 5: value = .number(Double(raw)) // uint_value
                case 6: value = .number(Double(zigzag(raw))) // sint_value
                case 7: value = .bool(raw != 0) // bool_value
                default: break
                }
            } else if tag.wireType == 2 {
                value = .string(try reader.readString())
            } else if tag.wireType == 5 {
                value = .number(Double(try reader.readFloat32()))
            } else {
                try skipField(&reader, wireType: tag.wireType)
            }
        }
        return value
    }

    static func decodeGeometry(_ data: ArraySlice<UInt8>, extent: Int) throws -> [[Pixel]] {
        var reader = Reader(data)
        var parts: [[Pixel]] = []
        /// Index of the part being appended to, or nil outside one. An index
        /// rather than a copied array: in the web decoder `part` aliases the
        /// array already pushed into `parts`, and Swift arrays copy on write.
        var partIndex: Int?
        var cursorX = 0
        var cursorY = 0
        while !reader.done {
            let command = try reader.readVarint()
            let id = Int(command & 0x7)
            let count = Int(command >> 3)
            if id == 1 || id == 2 {
                for _ in 0..<count {
                    cursorX = max(0, min(extent - 1, cursorX + zigzag(try reader.readVarint())))
                    cursorY = max(0, min(extent - 1, cursorY + zigzag(try reader.readVarint())))
                    if id == 1 {
                        parts.append([Pixel(x: cursorX, y: cursorY)])
                        partIndex = parts.count - 1
                    } else {
                        if partIndex == nil {
                            parts.append([])
                            partIndex = parts.count - 1
                        }
                        parts[partIndex!].append(Pixel(x: cursorX, y: cursorY))
                    }
                }
            } else if id == 7 {
                // ClosePath: implicit ring close; the cursor resets to the
                // part's start and the current part ends.
                cursorX = 0
                cursorY = 0
                partIndex = nil
            } else {
                return parts
            }
        }
        return parts
    }

    static func decodeLayer(_ data: ArraySlice<UInt8>) throws -> Layer {
        var reader = Reader(data)
        var name = ""
        var extent = defaultExtent
        var keys: [String] = []
        var values: [Value] = []
        var rawFeatures: [ArraySlice<UInt8>] = []

        while !reader.done {
            let tag = try tagField(&reader)
            switch tag.field {
            case 1: name = try reader.readString()
            case 2: rawFeatures.append(try reader.readBytes())
            case 3: keys.append(try reader.readString())
            case 4: values.append(try decodeValue(try reader.readBytes()))
            case 5:
                extent = try reader.readVarintAsInt()
            default:
                try skipField(&reader, wireType: tag.wireType)
            }
        }

        // Features may appear before keys/values on the wire, so resolve their
        // tags only once the dictionaries are complete.
        var features: [Feature] = []
        for featureBytes in rawFeatures {
            var featureReader = Reader(featureBytes)
            var feature = Feature(type: 0)
            while !featureReader.done {
                let tag = try tagField(&featureReader)
                switch tag.field {
                case 1: feature.id = try featureReader.readVarint()
                case 2:
                    let tagReader = Reader(try featureReader.readBytes())
                    var tags = tagReader
                    while !tags.done {
                        let keyIndex = try tags.readVarintAsInt()
                        let valueIndex = try tags.readVarintAsInt()
                        guard keyIndex >= 0, keyIndex < keys.count,
                              valueIndex >= 0, valueIndex < values.count else { continue }
                        feature.props[keys[keyIndex]] = values[valueIndex]
                    }
                case 3: feature.type = try featureReader.readVarintAsInt()
                case 4: feature.parts = try decodeGeometry(try featureReader.readBytes(), extent: extent)
                default:
                    try skipField(&featureReader, wireType: tag.wireType)
                }
            }
            features.append(feature)
        }
        return Layer(name: name, extent: extent, features: features)
    }

    /// Decode decompressed vector-tile bytes into its named layers.
    public static func decodeTile(_ data: Data) throws -> [Layer] {
        var reader = Reader(data)
        var layers: [Layer] = []
        while !reader.done {
            let tag = try tagField(&reader)
            if tag.field == 3 && tag.wireType == 2 {
                layers.append(try decodeLayer(try reader.readBytes()))
            } else {
                try skipField(&reader, wireType: tag.wireType)
            }
        }
        return layers
    }

    /// Find the first layer with the given name, or nil.
    public static func layer(named name: String, in layers: [Layer]) -> Layer? {
        layers.first { $0.name == name }
    }

    /// Convert a tile-pixel coordinate to lat/lon. `extent` is the layer extent;
    /// (px, py) are y-down pixel offsets within the (z, x, y) tile.
    public static func tilePointToCoordinate(
        z: Int,
        x: Int,
        y: Int,
        extent: Int,
        px: Double,
        py: Double
    ) -> Coordinate {
        let n = Double.pi - (2 * Double.pi * (Double(y) + py / Double(extent))) / pow(2, Double(z))
        return Coordinate(
            lat: atan(sinh(n)) * (180 / Double.pi),
            lon: (Double(x) + px / Double(extent)) / pow(2, Double(z)) * 360 - 180
        )
    }
}
