import OpenCineCameraVocabulary

// The Nikon PTP wire, property, profile, discovery and session code lives in the OpenCineNikon
// product of the OpenCine package (sibling ../OpenCine, pinned in opencine-pins.txt). Re-exported so the iOS app,
// the Watch app and the Android JNI facade keep importing OpenZCineCore only.
@_exported import OpenCineNikon

// Session recovery (the shared episode, its states and operator copy) is the camera
// vocabulary's, shared by every camera; scoped re-exports keep the same single import without the
// vocabulary's other names, some of which (`LUTSelection`) OpenZCine defines itself.
@_exported import enum OpenCineCameraVocabulary.SessionDropSuspect
@_exported import enum OpenCineCameraVocabulary.SessionRecoveryCopy
@_exported import class OpenCineCameraVocabulary.SessionRecoveryEpisode
@_exported import enum OpenCineCameraVocabulary.SessionRecoveryState
@_exported import enum OpenCineCameraVocabulary.SessionRecoveryTrigger

// The live monitor's FPS chip words come from the vocabulary's shared `MonitorLinkMeter` (A5-17),
// which reads the vocabulary's connection phase. It is exported under its own name: Nikon's
// `CameraConnectionPhase` (the connection sheet) keeps the plain one.
public typealias LinkConnectionPhase = OpenCineCameraVocabulary.CameraConnectionPhase
