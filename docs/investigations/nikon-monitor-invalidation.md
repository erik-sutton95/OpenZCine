# Nikon monitor observation boundaries

Camera property polling must leave the monitor unchanged when the reported facts
have not changed. A full-screen media or settings cover reduces Nikon preview
demand to covered polling; it still applies genuine camera changes so the monitor
is current when the cover closes.

`NativeAppModel` publishes `CameraDisplayState` and the property snapshot as whole
Equatable values. Observation suppresses equal assignments. Shutter lock readback
also needs a membership check: inserting or removing an existing Set membership
is an in-place mutation and can invalidate the shared surface even when the
reported lock has not changed. Pending lock writes keep their optimistic target
until camera confirmation, as before.

The shared chrome reads picture presence and source aspect as scalar facts. The
raster view continues to observe each accepted `liveFrameImage`. Replacing an
image with the same geometry does not change chrome; first picture, explicit
clear, HDMI aspect change, feed rotation and recovery remain observable. A held
recovery picture keeps its render lease and stays present until an explicit clear
or a newly accepted source retires it.

The app's live-surface regressions exercise the actual property-apply and picture
projection paths, with real-change and raster controls. Native frame-baker tests
cover held-picture repaint, source retirement and successor leases. This is an
iOS Observation correction: Android already publishes immutable property values
through StateFlow and tracks first-picture presence separately. It changes no
protocol polling, camera writes or capture policy.
