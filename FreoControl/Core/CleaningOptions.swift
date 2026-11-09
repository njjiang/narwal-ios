import Foundation

/// Values recovered from the official CleanTask protobuf enums. The UI exposes
/// only the X Ultra's ordinary levels, not the newer-model SUPER/smart values.
public enum CleaningSuction: Int, CaseIterable, Identifiable, Codable, Sendable {
    case quiet = 1, normal = 2, strong = 3, max = 4
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .quiet: return "Quiet"; case .normal: return "Normal"; case .strong: return "Strong"; case .max: return "Max" }
    }
}
public enum CleaningHumidity: Int, CaseIterable, Identifiable, Codable, Sendable {
    case dry = 1, normal = 2, wet = 3
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .dry: return "Low"; case .normal: return "Normal"; case .wet: return "High" }
    }
}
public enum CleaningRoute: Int, CaseIterable, Identifiable, Codable, Sendable {
    case standard = 1, intensive = 2
    public var id: Int { rawValue }
    public var title: String { self == .standard ? "Standard" : "Intensive" }
}
public struct CleaningOptions: Equatable, Codable, Sendable {
    public var passes: Int
    public var suction: CleaningSuction
    public var humidity: CleaningHumidity
    public var route: CleaningRoute
    public static let standard = CleaningOptions()
    public init(passes: Int = 1, suction: CleaningSuction = .normal,
                humidity: CleaningHumidity = .normal, route: CleaningRoute = .standard) {
        self.passes = passes; self.suction = suction; self.humidity = humidity; self.route = route
    }
    public func validate() throws {
        // Both 1 and 2 are unconditional choices in the official cycle picker;
        // higher/smart counts have model-specific gates and remain unavailable.
        guard (1...2).contains(passes) else { throw ConnectorError.invalid("Choose one or two cleaning passes.") }
    }
    public func summary(for mode: CleaningMode) -> String {
        var parts = [mode == .vacuumThenMop ? "\(passes) vacuum + \(passes) mop" : "\(passes) \(passes == 1 ? "pass" : "passes")"]
        if mode != .mop { parts.append("\(suction.title) suction") }
        if mode != .vacuum { parts.append("\(humidity.title) moisture") }
        if route == .intensive { parts.append("Intensive route") }
        return parts.joined(separator: " · ")
    }
}

extension CleaningTaskSample {
    /// Read only what the robot actually returned. Omitted fields and unfamiliar
    /// codes remain unknown; UI picker values never stand in for observed data.
    public var reportedSettings: [String] {
        var values: [String] = []
        if let raw = parameters[1] {
            values.append([2: "Vacuum", 3: "Mop", 4: "Vacuum & mop", 5: "Vacuum, then mop"][raw] ?? "Mode \(raw)")
        }
        if let raw = parameters[2], let value = Int(exactly: raw).flatMap(CleaningSuction.init(rawValue:)) { values.append("\(value.title) suction") }
        if let raw = parameters[4], let value = Int(exactly: raw).flatMap(CleaningHumidity.init(rawValue:)) { values.append("\(value.title) moisture") }
        for (tag, name) in [(5, "vacuum"), (6, "mop"), (7, "combined")] {
            if let count = parameters[tag], count > 0 { values.append("\(count) \(name) \(count == 1 ? "pass" : "passes")") }
        }
        if let raw = parameters[8], let value = Int(exactly: raw).flatMap(CleaningRoute.init(rawValue:)) { values.append("\(value.title) route") }
        if parameters[9] == 1 { values.append("Smart mode enabled") }
        if let raw = parameters[11] {
            let label = [0: "Unspecified", 1: "Quiet", 2: "Normal", 3: "Strong", 4: "Deep"][raw]
            values.append(label.map { "\($0) sweep intensity" } ?? "Sweep intensity code \(raw)")
        }
        return values
    }
}
