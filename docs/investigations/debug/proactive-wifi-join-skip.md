---
status: awaiting_human_verify
trigger: "fresh build post-7d244aa, camera AP up (NIKON_ZR_* visible), phone on home WiFi, app does NOT prompt to connect/join when opened"
created: 2026-07-02T12:00:00Z
updated: 2026-07-02T14:30:00Z
---

## Current Focus

hypothesis: CONFIRMED — subnet false positive on 192.168.1.x home WiFi + swallowed errors
next_action: Human verify on device with home WiFi + camera AP visible

## Resolution

root_cause: isOnCameraAccessPoint matched 192.168.1.0/24 subnet on home WiFi (false positive), causing proactiveJoinTarget to return nil; join failures dismissed without UI in release
fix: SSID-based detection via NEHotspotNetwork; persistent join banner; immediate first attempt; os_log + inline error display
verification: just native-check passed; commit 271892a pushed
files_changed: [Sources/OpenZCineCore/CameraWiFiSSID.swift, ios/Runner/NativeAppRoot.swift, ios/Runner/LinkExperience.swift, ios/Runner/StartupDesign.swift, ios/Runner/WiFiJoinCoordinator.swift, ios/Runner/NativeCameraDiscovery.swift, ios/Runner/AccessorySetupWiFiCoordinator.swift, Tests/OpenZCineCoreTests/CameraWiFiSSIDTests.swift]
