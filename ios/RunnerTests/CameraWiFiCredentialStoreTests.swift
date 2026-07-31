import XCTest

@testable import Runner

/// A keychain backing that lives and dies with the test process.
///
/// The real keychain is deliberately absent here: these tests pin the store's account-key scheme
/// and lookup order, and running them against securityd made them flake — parallel simulator
/// clones can lose keychain access for whole windows, failing every test in this class at once
/// regardless of which keys they used.
private final class InMemoryKeychain: CameraWiFiKeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private func key(_ service: String, _ account: String) -> String {
        service + "\u{1}" + account
    }

    func read(service: String, account: String) -> Data? {
        lock.withLock { items[key(service, account)] }
    }

    func write(service: String, account: String, data: Data) {
        lock.withLock { items[key(service, account)] = data }
    }

    func delete(service: String, account: String) {
        lock.withLock { _ = items.removeValue(forKey: key(service, account)) }
    }
}

final class CameraWiFiCredentialStoreTests: XCTestCase {
    private let testSSID = "NIKON_ZR_TEST_\(UUID().uuidString)"
    private let testPrefix = "NIKON_ZR_TEST_PREFIX_\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        CameraWiFiCredentialStore.setBacking(InMemoryKeychain())
    }

    override func tearDown() {
        CameraWiFiCredentialStore.setBacking(SecItemKeychainBacking())
        super.tearDown()
    }

    func testSaveAndLoadPasswordForSSID() {
        CameraWiFiCredentialStore.savePassword("camera-pass", forSSID: testSSID)
        XCTAssertEqual(CameraWiFiCredentialStore.password(forSSID: testSSID), "camera-pass")
    }

    func testSaveAndLoadPasswordForPrefix() {
        CameraWiFiCredentialStore.savePassword("prefix-pass", forPrefix: testPrefix)
        XCTAssertEqual(CameraWiFiCredentialStore.password(forPrefix: testPrefix), "prefix-pass")
    }

    func testPasswordLookupPrefersSSIDBeforePrefix() {
        CameraWiFiCredentialStore.savePassword("ssid-pass", forSSID: testSSID)
        CameraWiFiCredentialStore.savePassword("prefix-pass", forPrefix: testPrefix)
        XCTAssertEqual(
            CameraWiFiCredentialStore.password(forSSID: testSSID, prefix: testPrefix),
            "ssid-pass"
        )
    }

    func testPasswordLookupFallsBackToPrefix() {
        CameraWiFiCredentialStore.savePassword("prefix-pass", forPrefix: testPrefix)
        XCTAssertEqual(
            CameraWiFiCredentialStore.password(forSSID: nil, prefix: testPrefix),
            "prefix-pass"
        )
    }

    func testOverwritePasswordForSSID() {
        CameraWiFiCredentialStore.savePassword("first-pass", forSSID: testSSID)
        CameraWiFiCredentialStore.savePassword("second-pass", forSSID: testSSID)
        XCTAssertEqual(CameraWiFiCredentialStore.password(forSSID: testSSID), "second-pass")
    }

    /// The prefix marker is what keeps a prefix entry from colliding with an SSID that happens to
    /// share its text. An SSID lookup must never resolve a prefix entry, or vice versa.
    func testPrefixAndSSIDEntriesNeverCollide() {
        CameraWiFiCredentialStore.savePassword("as-prefix", forPrefix: testSSID)
        XCTAssertNil(CameraWiFiCredentialStore.password(forSSID: testSSID))
        XCTAssertEqual(CameraWiFiCredentialStore.password(forPrefix: testSSID), "as-prefix")
    }
}
