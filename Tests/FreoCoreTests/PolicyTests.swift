import XCTest
@testable import FreoCore
final class PolicyTests: XCTestCase {
    func testOnlyCanonicalPublicIPv4() {
        for ip in ["47.251.87.117", "47.251.164.87", "47.254.42.251", "47.251.29.225"] { XCTAssertTrue(USNetworkPolicy.isPublicIPv4(ip)) }
        for ip in ["", "::1", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "100.64.0.1", "169.254.1.1", "192.0.2.2", "198.51.100.2", "203.0.113.2", "224.1.1.1", "255.255.255.255", "047.251.87.117", "47.251.87.256", "47.251.87.117."] { XCTAssertFalse(USNetworkPolicy.isPublicIPv4(ip), ip) }
    }
}
