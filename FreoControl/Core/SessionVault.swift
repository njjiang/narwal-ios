import Foundation
import Security

/// The opt-in flag contains no credentials. Clearing it first prevents a
/// temporarily undeletable Keychain item from restoring a disconnected session.
protocol SessionVault: Sendable {
    func isEnabled() -> Bool
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

final class KeychainSessionVault: SessionVault, @unchecked Sendable {
    struct Operations {
        var copy: ([String: Any]) -> (OSStatus, Data?)
        var update: ([String: Any], [String: Any]) -> OSStatus
        var add: ([String: Any]) -> OSStatus
        var delete: ([String: Any]) -> OSStatus
        static let system = Operations(copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
           add: { SecItemAdd($0 as CFDictionary, nil) },
           delete: { SecItemDelete($0 as CFDictionary) })
    }
    private let defaults: UserDefaults
    private let operations: Operations
    private let preference = "FreoControl.rememberUSSession.v1"
    init(defaults: UserDefaults = .standard, operations: Operations = .system) {
        self.defaults = defaults; self.operations = operations
    }
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.freo.personal.control.us-session.v1",
         kSecAttrAccount as String: "narwal-us",
         kSecAttrSynchronizable as String: false]
    }
    func isEnabled() -> Bool { defaults.bool(forKey: preference) }
    func load() throws -> Data? {
        guard isEnabled() else { return nil }
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(query)
        if status == errSecItemNotFound {
            defaults.set(false, forKey: preference); return nil
        }
        guard status == errSecSuccess, let data else {
            throw ConnectorError.invalid("The saved sign-in is unavailable. Unlock this device, then retry saved sign-in.")
        }
        return data
    }
    func save(_ data: Data) throws {
        guard data.count <= 65536 else { throw ConnectorError.invalid("The saved sign-in exceeds its storage limit.") }
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        var status = operations.update(Self.query, values)
        if status == errSecItemNotFound {
            status = operations.add(Self.query.merging(values) { _, new in new })
        }
        guard status == errSecSuccess else {
            throw ConnectorError.invalid("This sign-in could not be saved securely. Unlock this device and try again.")
        }
        defaults.set(true, forKey: preference)
    }
    func remove() throws {
        defaults.set(false, forKey: preference)
        let status = operations.delete(Self.query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectorError.invalid("Saved sign-in is disabled, but its Keychain item could not be removed. Unlock this device, then tap Remove saved sign-in.")
        }
    }
}

protocol SessionNetworkPolicy: Sendable {
    func expiration() async -> Date
    func destination(_ kind: NarwalServiceKind) async throws -> VerifiedDestination
    func recheck() async throws -> Date
}
extension USNetworkPolicy: SessionNetworkPolicy {}

typealias SessionHTTPClient = @Sendable (VerifiedDestination, String, String, [String: String], Data?,
    @escaping @Sendable () async throws -> Void) async throws -> Data

/// Typed HTTP failures let authentication rejection differ from server outages.
struct AccountHTTPError: LocalizedError, Sendable {
    let status: Int
    var errorDescription: String? { "Narwal returned HTTP \(status). Redirects are not followed." }
    var rejectsAuthentication: Bool { status == 401 || status == 403 }
}

/// Narwal sometimes rejects a valid request with an application-level reason
/// in its JSON envelope (for example, a source-network restriction). Keep only
/// a short human-readable message; never surface or log the raw response.
enum AccountFailureDetails {
    static func message(in root: [String: Any], fallback: String) -> String {
        let candidates = [root["message"], root["msg"], root["errorMessage"], root["error_msg"]]
        for candidate in candidates {
            guard let raw = candidate as? String else { continue }
            let value = raw.unicodeScalars.map { scalar -> String in
                CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 180,
                  !value.contains("@"),
                  !["token", "password", "authorization"].contains(where: { value.localizedCaseInsensitiveContains($0) }) else { continue }
            return "Narwal says: \(value)"
        }
        if let raw = root["code"] as? NSNumber,
           CFGetTypeID(raw) != CFBooleanGetTypeID(),
           raw.stringValue.count <= 12, raw.doubleValue != 0 {
            return "Narwal rejected the request (code \(raw.stringValue)). \(fallback)"
        }
        return fallback
    }
}

enum SessionRestoreFailure: LocalizedError {
    case expired, invalidIdentity
    var errorDescription: String? {
        switch self {
        case .expired: return "Your saved Narwal session expired. Sign in again."
        case .invalidIdentity: return "The saved Narwal account identity could not be verified. Sign in again."
        }
    }
}

struct SessionStorageFailure: LocalizedError {
    var errorDescription: String? {
        "You are signed in, but this sign-in could not be saved securely. Unlock this iPhone and sign in again to save it."
    }
}
