import XCTest
@testable import FreoCore

final class SiriRoomReferenceTests: XCTestCase {
    private let device = String(repeating: "a", count: 32)
    private let otherDevice = String(repeating: "b", count: 32)

    private func room(_ id: Int, name: String = "Room", product: String = "EHf6cRNRGT", device: String? = nil, map: Int = 17, revision: UInt32? = nil) -> SiriRoomReference {
        SiriRoomReference(productKey: product, deviceID: device ?? self.device, mapID: map, roomID: id, name: name, mapRevision: revision)
    }

    func testSiriCatalogSurvivesNewInstanceAndReplacesRenamedRooms() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SiriRoomCatalog(directory: directory)
        XCTAssertEqual(try first.load(), [])
        let rooms = [room(1, name: "entryway", revision: 72), room(2, name: "Kitchen", revision: 72)]
        try first.save(rooms)
        XCTAssertEqual(try SiriRoomCatalog(directory: directory).load(), rooms)
        let renamed = [room(1, name: "Entry", revision: 73)]
        try first.save(renamed)
        XCTAssertEqual(try first.load(), renamed)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("rooms.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try first.remove()
        XCTAssertEqual(try first.load(), [])
    }

    func testLegacyCatalogRefreshUpgradesEvenWhenVisibleRoomsAreUnchanged() throws {
        struct LegacyRecord: Encodable { let version: Int; let rooms: [SiriRoomReference] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = [room(1, name: "Living Room", revision: 84)]
        let file = directory.appendingPathComponent("rooms.json")
        try JSONEncoder().encode(LegacyRecord(version: 1, rooms: current)).write(to: file)
        let catalog = SiriRoomCatalog(directory: directory)

        XCTAssertEqual(try catalog.load(), current)
        XCTAssertFalse(try catalog.isCurrent(current), "Legacy storage must not be mistaken for a current catalog")
        try catalog.save(current)
        XCTAssertTrue(try catalog.isCurrent(current))
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(record["version"] as? Int, 2)
    }

    func testRoomCatalogMigratesShortcutIDsAcrossMapRevisionByUniqueRoomName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SiriRoomCatalog(directory: directory)
        let old = [room(1, name: "Bathroom", revision: 72), room(2, name: "Kitchen", revision: 72)]
        try catalog.save(old)
        let current = [room(9, name: "Bathroom", revision: 73), room(10, name: "Kitchen", revision: 73)]
        try catalog.save(current)
        XCTAssertEqual(try catalog.resolve(identifier: old[0].id, current: current), current[0])
        XCTAssertEqual(try catalog.resolve(identifier: old[1].id, current: current), current[1])
        XCTAssertNil(try catalog.resolve(identifier: room(3, name: "Deleted", revision: 72).id, current: current))
    }

    func testSavedShortcutRoomSelectionsMigrateAsAGroupAfterMapEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SiriRoomCatalog(directory: directory)
        let old = [room(1, name: "Kitchen", revision: 72), room(2, name: "Hallway", revision: 72)]
        try catalog.save(old)
        let current = [room(8, name: "Kitchen", revision: 73), room(9, name: "Hallway", revision: 73)]
        try catalog.save(current)

        XCTAssertEqual(try catalog.resolve([old[1], old[0]], current: current), [current[1], current[0]])
        XCTAssertThrowsError(try catalog.resolve([old[0]], current: [room(10, name: "Other", revision: 74)]))
    }

    func testRoomCatalogDoesNotGuessWhenNamesBecomeAmbiguousOrMapChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SiriRoomCatalog(directory: directory)
        let old = [room(1, name: "Room", revision: 72)]
        try catalog.save(old)
        let duplicateName = [room(2, name: "Room", revision: 73), room(3, name: "Room", revision: 73)]
        try catalog.save(duplicateName)
        XCTAssertNil(try catalog.resolve(identifier: old[0].id, current: duplicateName))

        let otherMap = [room(4, name: "Room", map: 18, revision: 74)]
        try catalog.save(otherMap)
        XCTAssertNil(try catalog.resolve(identifier: old[0].id, current: otherMap))
    }
    func testSiriCatalogRejectsMixedScopeDuplicateOrInvalidRoomRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SiriRoomCatalog(directory: directory)
        for invalid in [[], [room(1), room(1)], [room(1), room(2, device: otherDevice)],
                        [room(1, name: " ")], [room(1, name: String(repeating: "x", count: 257))]] {
            XCTAssertThrowsError(try catalog.save(invalid))
        }
        try catalog.save([room(1)])
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("rooms.json"))
        XCTAssertThrowsError(try catalog.load())
    }

    func testStableIdentityScopesEveryIdentifierAndExcludesNames() throws {
        let original = room(4, name: "Kid’s room: east / play • 你好")
        let renamed = room(4, name: "Dining. Room: a|b / c")
        XCTAssertEqual(original.id, renamed.id)
        XCTAssertNotEqual(original, renamed)
        XCTAssertEqual(SiriRoomReference(id: original.id, name: renamed.name), renamed)
        XCTAssertFalse(original.id.contains("Kid"))
        XCTAssertFalse(original.id.contains("你好"))
        let references = [original, room(5), room(4, map: 18), room(4, device: otherDevice), room(4, product: "OtherProduct")]
        XCTAssertEqual(Set(references.map(\.id)).count, references.count)
        for reference in references { XCTAssertEqual(SiriRoomReference(id: reference.id, name: reference.name), reference) }
    }

    func testInvalidDirectInputsNeverCreateDelimiterCollisions() {
        let first = room(1, product: "a.b", device: "c")
        let second = room(1, product: "a", device: "b.c")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(SiriRoomReference(id: first.id, name: "First"))
        XCTAssertNil(SiriRoomReference(id: second.id, name: "Second"))
        XCTAssertThrowsError(try SiriRoomReference.validate(requested: [first], against: [first])) {
            XCTAssertEqual($0 as? SiriRoomReference.ValidationError, .invalidReference)
        }
    }

    func testIdentifierBoundsAndCanonicalParsing() throws {
        let maximum = room(Int(Int32.max), product: String(repeating: "P", count: 32), map: Int(Int32.max))
        XCTAssertEqual(SiriRoomReference(id: maximum.id, name: maximum.name), maximum)
        let invalid = [
            room(0), room(-1), room(Int(Int32.max) + 1), room(1, map: 0), room(1, map: -1), room(1, map: Int(Int32.max) + 1),
            room(1, product: ""), room(1, product: String(repeating: "P", count: 33)), room(1, product: "bad/key"),
            room(1, product: "café"), room(1, device: ""), room(1, device: String(repeating: "a", count: 31)),
            room(1, device: String(repeating: "g", count: 32)), room(1, device: String(repeating: "a", count: 31) + "\n")
        ]
        for reference in invalid {
            XCTAssertNil(SiriRoomReference(id: reference.id, name: reference.name))
            XCTAssertThrowsError(try SiriRoomReference.validate(requested: [reference], against: [room(1)]))
        }
        let reference = room(1, product: "A")
        let pieces = reference.id.split(separator: ".").map(String.init)
        var malformed = ["", reference.id + ".extra", reference.id + "\n", String(repeating: "a", count: 161)]
        for (position, value) in [(0, "other-room"), (1, "v2"), (2, "QQ="), (2, "QR"), (2, "Q!"),
                                  (3, ""), (4, "017"), (4, "+17"), (4, "2147483648"), (5, "٠١"), (5, "1 ")] {
            var changed = pieces
            changed[position] = value
            malformed.append(changed.joined(separator: "."))
        }
        for id in malformed { XCTAssertNil(SiriRoomReference(id: id, name: "Room"), "Accepted malformed reference") }
    }

    func testMatchingIgnoresCaseDiacriticsAndWhitespaceWithoutGuessingAliases() {
        let accented = room(1, name: "  Sálon\t du\n CAFÉ ")
        let similar = room(2, name: "Salon du Cafe upstairs")
        XCTAssertEqual(SiriRoomReference.matching(query: "SALON\u{00a0}DU cafe", in: [similar, accented]), [accented, similar])
        XCTAssertEqual(SiriRoomReference.matching(query: "salonducafé", in: [accented]), [accented])
        XCTAssertEqual(SiriRoomReference.matching(query: " \n\t", in: [accented]), [])
        XCTAssertEqual(SiriRoomReference.matching(query: "bedrooms", in: [room(3, name: "Bedroom")]), [])
        XCTAssertEqual(SiriRoomReference.matching(query: "lounge", in: [room(4, name: "Living room")]), [])
        let punctuation = room(5, name: "Kid’s room / Play: east")
        XCTAssertEqual(SiriRoomReference.matching(query: "kid’s ROOM / PLAY: EAST", in: [punctuation]), [punctuation])
        XCTAssertEqual(SiriRoomReference.matching(query: "kids room play east", in: [punctuation]), [])
    }

    func testMatchingRanksExactBeforePrefixBeforeSubstringAndKeepsAmbiguity() {
        let first = room(1, name: "ROOM")
        let second = room(2, name: "Room")
        let anotherRobot = room(1, name: "Room", device: otherDevice)
        let prefix = room(3, name: "Room Two")
        let substring = room(4, name: "Bedroom")
        let source = [substring, second, prefix, anotherRobot, first]
        let matched = SiriRoomReference.matching(query: "room", in: source)
        XCTAssertEqual(Set(matched.prefix(3).map(\.id)), Set([first.id, second.id, anotherRobot.id]))
        XCTAssertEqual(Array(matched.suffix(2)), [prefix, substring])
        XCTAssertEqual(matched, SiriRoomReference.matching(query: "ROOM", in: Array(source.reversed())))
        XCTAssertEqual(SiriRoomReference.matching(query: "Room", in: [room(0, name: "Room")]), [])
    }

    func testValidationPreservesSelectionOrderAndAcceptsRenamedRooms() throws {
        let current = [room(1, name: "Office"), room(2, name: "New kitchen name"), room(3, name: "Bedroom")]
        let requested = [room(2, name: "Kitchen: original name"), room(1, name: "Office")]
        XCTAssertEqual(try SiriRoomReference.validate(requested: requested, against: current), [2, 1])
        let maximum = (1...100).map { room($0) }
        XCTAssertEqual(try SiriRoomReference.validate(requested: maximum, against: maximum), Array(1...100))
    }

    func testValidationRejectsEmptyDuplicateDeletedAndOversizedSelections() {
        let current = [room(1), room(2)]
        assertValidation([], current, error: .emptySelection)
        assertValidation([room(1), room(1, name: "Renamed")], current, error: .duplicateSelection)
        assertValidation([room(3)], current, error: .staleReference)
        assertValidation((1...101).map { room($0) }, current, error: .tooManyRooms)
        assertValidation([room(1)], [], error: .invalidCurrentCatalog)
        assertValidation([room(1)], [room(1), room(1, name: "Conflicting duplicate")], error: .invalidCurrentCatalog)
        assertValidation([room(1)], [room(0)], error: .invalidCurrentCatalog)
    }

    func testValidationRejectsStaleMapCrossDeviceAndMixedCatalogs() {
        let current = [room(1), room(2)]
        for stale in [room(1, map: 16), room(1, device: otherDevice), room(1, product: "AnotherProduct")] {
            assertValidation([stale], current, error: .scopeMismatch)
            assertValidation([room(1), stale], current, error: .scopeMismatch)
            assertValidation([room(1)], current + [stale], error: .scopeMismatch)
        }
        assertValidation([room(1)], [room(1, map: 18)], error: .scopeMismatch)
    }

    func testVersionTwoIdentityIncludesCanonicalMapRevision() throws {
        let legacy = room(4, name: "Kitchen")
        XCTAssertTrue(legacy.id.hasPrefix("freo-room.v1."))
        for revision: UInt32 in [0, 1, 123456789, .max] {
            let value = room(4, name: "Kitchen", revision: revision)
            XCTAssertTrue(value.id.hasPrefix("freo-room.v2."))
            XCTAssertTrue(value.id.hasSuffix(".\(revision)"))
            XCTAssertNotEqual(legacy.id, value.id)
            XCTAssertEqual(SiriRoomReference(id: value.id, name: value.name), value)
        }
        let canonical = room(4, revision: 7).id
        for bad in ["", "07", "+7", "-1", "4294967296", "7 ", "٧"] {
            let candidate = canonical.split(separator: ".").dropLast().map(String.init).joined(separator: ".") + "." + bad
            XCTAssertNil(SiriRoomReference(id: candidate, name: "Room"))
        }
    }

    func testMapRevisionRejectsReusedRoomIDsAndLegacyShortcuts() throws {
        let old = room(4, name: "Kitchen", revision: 7)
        let reused = room(4, name: "Hallway", revision: 8)
        assertValidation([old], [reused], error: .scopeMismatch)
        assertValidation([room(4, name: "Kitchen")], [reused], error: .scopeMismatch)
        assertValidation([reused], [room(4)], error: .scopeMismatch)
        assertValidation([reused], [reused, room(5, revision: 7)], error: .scopeMismatch)
        XCTAssertEqual(try SiriRoomReference.validate(requested: [reused], against: [reused]), [4])
        // Names remain display-only within one explicitly identical revision.
        XCTAssertEqual(try SiriRoomReference.validate(requested: [old], against: [room(4, name: "Displayed name", revision: 7)]), [4])
    }

    private func assertValidation(_ requested: [SiriRoomReference], _ current: [SiriRoomReference],
                                  error: SiriRoomReference.ValidationError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SiriRoomReference.validate(requested: requested, against: current), file: file, line: line) {
            XCTAssertEqual($0 as? SiriRoomReference.ValidationError, error, file: file, line: line)
        }
    }
}
