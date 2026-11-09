import Foundation

/// Converts full, unrotated display-raster cell edges into map protocol points.
/// Static evidence: Narwal Android 2.10.90, processOutPointsWithMap 0x1fc412c,
/// Pair.reverseXY 0x12ccb4c, and Border.getCoordinateOffset 0x12cce50.
/// At zero rotation the app's inverse is (x + left, top - y), in grid units.
/// Its raster parser uses integer pixel centers and its room painter expands
/// their rectangles by 0.5 (0x1128514). Our display uses integer cell edges,
/// so subtract 0.5 from both display axes before that inverse transformation.
/// Neither resolution nor origin participates. Both consistent cell-count and
/// center-span extents are accepted: conversion uses left/top directly.
/// Rotated maps remain unavailable until their correspondence is verified.
public struct MapEditCoordinates: Sendable {
    private let left: Int
    private let top: Int
    private let width: Int
    private let height: Int

    public init(snapshot: MapSnapshot) throws {
        guard snapshot.floorplan.mapID == snapshot.mapID else {
            throw Self.invalid("The map coordinate frame does not match its snapshot.")
        }
        try self.init(floorplan: snapshot.floorplan, productKey: snapshot.productKey,
                      staticMapPayload: snapshot.staticMapPayload)
    }

    // Display-only archive maps need their geometry, not invented edit revisions.
    init(floorplan: Floorplan, productKey: String, staticMapPayload: Data) throws {
        guard productKey == "EHf6cRNRGT" else {
            throw Self.invalid("Room editing requires a matching Freo X Ultra map.")
        }
        let map = try Self.scan(staticMapPayload, limit: 1024 * 1024)
        guard try Self.positive(map, tag: 1) == floorplan.mapID,
              try Self.positive(map, tag: 4) == floorplan.width,
              try Self.positive(map, tag: 5) == floorplan.height else {
            throw Self.invalid("Map dimensions do not match the saved room snapshot.")
        }
        let width = floorplan.width, height = floorplan.height
        guard width > 0, height > 0, width <= 1_000_000 / height,
              floorplan.pixels.count == width * height else {
            throw Self.invalid("The room map has invalid dimensions.")
        }
        if let rotation = try Self.one(map, tag: 25) {
            guard try Self.signed(rotation) == 0 else {
                throw Self.invalid("Room editing for rotated map coordinates is not verified yet.")
            }
        }
        guard let borderField = try Self.one(map, tag: 6), borderField.wire == 2,
              let borderData = borderField.bytes else {
            throw Self.invalid("This saved map does not include its editing coordinate boundary.")
        }
        let border = try Self.scan(borderData, limit: 256)
        let bottom = try Self.defaultSigned(border, tag: 1)
        let top = try Self.defaultSigned(border, tag: 2)
        let left = try Self.defaultSigned(border, tag: 3)
        let right = try Self.defaultSigned(border, tag: 4)
        let spanX = right - left, spanY = top - bottom
        guard (spanX == width && spanY == height) ||
              (spanX == width - 1 && spanY == height - 1) else {
            throw Self.invalid("The map boundary uses an unverified coordinate convention. No room edit can be sent.")
        }
        self.left = left; self.top = top; self.width = width; self.height = height
    }

    public func point(_ point: RoomGridPoint) throws -> MapEditPoint {
        guard (0...width).contains(point.x), (0...height).contains(point.y) else {
            throw Self.invalid("The room divider falls outside the saved map.")
        }
        // These are geometric edge coordinates. Firmware split-line rounding
        // and which side receives line cells require separate verification.
        return MapEditPoint(x: Float(left + point.x) - 0.5, y: Float(top - point.y) + 0.5)
    }

    private static func invalid(_ message: String) -> ConnectorError { .invalid(message) }

    private struct Field {
        let tag: Int
        let wire: Int
        let integer: UInt64?
        let bytes: Data?
    }

    /// A narrow bounded reader avoids exposing account envelopes or map pixels.
    private static func scan(_ data: Data, limit: Int) throws -> [Field] {
        guard data.count <= limit else { throw invalid("The editing metadata is too large.") }
        let bytes = Array(data)
        var index = 0
        func integer() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw invalid("The editing metadata is truncated.") }
                let byte = bytes[index]; index += 1
                let value = UInt64(byte & 127)
                guard value <= UInt64.max >> shift else { throw invalid("The editing metadata contains an invalid number.") }
                result |= value << shift
                if byte & 128 == 0 { return result }
            }
            throw invalid("The editing metadata contains an invalid number.")
        }
        var fields: [Field] = []
        while index < bytes.count {
            guard fields.count < 512 else { throw invalid("The editing metadata has too many fields.") }
            let key = try integer()
            guard key <= UInt64(UInt32.max), key >> 3 > 0 else { throw invalid("The editing metadata has an invalid field.") }
            let tag = Int(key >> 3), wire = Int(key & 7)
            if wire == 0 {
                fields.append(Field(tag: tag, wire: wire, integer: try integer(), bytes: nil))
            } else {
                let size: Int
                switch wire {
                case 1: size = 8
                case 5: size = 4
                case 2:
                    let length = try integer()
                    guard length <= UInt64(bytes.count - index) else { throw invalid("The editing metadata is truncated.") }
                    size = Int(length)
                default: throw invalid("The editing metadata uses an unsupported field.")
                }
                guard size <= bytes.count - index else { throw invalid("The editing metadata is truncated.") }
                // Retain only the border submessage, never the raster/geometry.
                let value = tag == 6 && wire == 2 ? Data(bytes[index..<(index + size)]) : nil
                fields.append(Field(tag: tag, wire: wire, integer: nil, bytes: value))
                index += size
            }
        }
        return fields
    }

    private static func one(_ fields: [Field], tag: Int) throws -> Field? {
        let values = fields.filter { $0.tag == tag }
        guard values.count <= 1 else { throw invalid("The editing metadata has duplicate coordinate fields.") }
        return values.first
    }

    private static func positive(_ fields: [Field], tag: Int) throws -> Int {
        guard let field = try one(fields, tag: tag), field.wire == 0,
              let value = field.integer, value > 0, value <= UInt64(Int32.max) else {
            throw invalid("The editing metadata is missing its map dimensions.")
        }
        return Int(value)
    }

    private static func defaultSigned(_ fields: [Field], tag: Int) throws -> Int {
        // Official GeneratedMessage.$_getIZ at 0xe03ed0–0xe03ed8 returns 0
        // when the scalar is absent. The required border container and exact
        // dimension-span check prevent an absent boundary from being invented.
        guard let field = try one(fields, tag: tag) else { return 0 }
        return try signed(field)
    }

    private static func signed(_ field: Field) throws -> Int {
        guard field.wire == 0, let value = field.integer else { throw invalid("The map boundary has an invalid number.") }
        let signed: Int64
        if value <= UInt64(Int32.max) { signed = Int64(value) }
        else if value >= UInt64.max - UInt64(Int32.max) { signed = Int64(bitPattern: value) }
        else { throw invalid("The map boundary has an invalid signed number.") }
        // Half-cell coordinates remain exact float32 below 2^23.
        guard abs(signed) <= 8_000_000 else { throw invalid("The map boundary exceeds the supported coordinate range.") }
        return Int(signed)
    }
}
