import XCTest

@testable import Runner

final class CameraWiFiCredentialStoreTests: XCTestCase {
    private let testSSID = "NIKON_ZR_TEST_\(UUID().uuidString)"
    private let testPrefix = "NIKON_ZR_TEST_PREFIX_\(UUID().uuidString)"

    override func tearDown() {
        CameraWiFiCredentialStore.deletePassword(forSSID: testSSID)
        CameraWiFiCredentialStore.deletePassword(forPrefix: testPrefix)
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
}
