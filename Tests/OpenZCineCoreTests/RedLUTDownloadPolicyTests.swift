import Foundation
import Testing

@testable import OpenZCineCore

@Test func redLUTDownloadAllowedWithInternetAndNotOnCameraAP() {
    let availability = RedLUTDownloadPolicy.availability(
        hasInternetPath: true,
        isOnCameraAccessPoint: false
    )
    #expect(availability == .available)
    #expect(availability.isAvailable)
    #expect(availability.blockedReason == nil)
    #expect(
        RedLUTDownloadPolicy.canDownloadLUTs(hasInternetPath: true, isOnCameraAccessPoint: false)
    )
}

@Test func redLUTDownloadBlockedOnCameraAccessPoint() {
    let availability = RedLUTDownloadPolicy.availability(
        hasInternetPath: true,
        isOnCameraAccessPoint: true
    )
    #expect(availability == .blockedOnCameraAccessPoint)
    #expect(!availability.isAvailable)
    #expect(availability.blockedReason?.contains("camera") == true)
    #expect(
        !RedLUTDownloadPolicy.canDownloadLUTs(hasInternetPath: true, isOnCameraAccessPoint: true)
    )
}

@Test func redLUTDownloadBlockedWhenNoNetworkPath() {
    let availability = RedLUTDownloadPolicy.availability(
        hasInternetPath: false,
        isOnCameraAccessPoint: false
    )
    #expect(availability == .blockedNoInternet)
    #expect(!availability.isAvailable)
    #expect(availability.blockedReason?.isEmpty == false)
}

@Test func redLUTDownloadCameraAPReasonTakesPrecedenceOverNoInternet() {
    // On the camera AP the OS still reports a satisfied path; the AP-specific reason must win so
    // the operator sees the actionable "you're on the camera's Wi‑Fi" message.
    let availability = RedLUTDownloadPolicy.availability(
        hasInternetPath: false,
        isOnCameraAccessPoint: true
    )
    #expect(availability == .blockedOnCameraAccessPoint)
}
