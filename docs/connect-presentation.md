# Connection presentation ownership

A connection attempt owned by OpenCine's cameras model keeps its shared card or pair-page
progress through reading settings and waiting for the first picture. OpenZCine does not replace
that progress with an additional preparing page.

First-pair instructions, camera approval, network joining and transport discovery remain in the
Nikon host. An app-owned connection, including an established session without a first picture,
renders the shared pair-page presentation directly. This retains status, failures and an explicit
way back without starting the pair screen's active-discovery lifecycle around that session.
Android already hosts its wizard and connection progress in the shared pair page; it has no
separate preparing page to retire.

## Adding a setup

Both shells provide typed options to OpenCine's shared chooser. The host decides which USB,
camera-access-point, infrastructure, hotspot and supported capture-device paths are available.
Reachability labels, camera-AP exclusions, network-name permission, Wi-Fi credential scanning and
secure storage remain host responsibilities. The iOS host defers AP and capture presentations until the chooser
dismisses; selecting a camera setup still provisions or watches its actual route. Saved IDs, serialized routes and credential namespaces are unchanged.

## Taking over a held camera

Direct first-pair decisions and integration prompts use one shared consent owner and presenter.
A saved setup that reports held-elsewhere admission returns to the integration's same explicit
prompt before a confirmed retry. The host still checks the real transport/session admission.
The confirmed retry runs once; another failure ends the attempt instead of asking again.

Cancel sends no connection request. Repeated, superseded or retired responses cannot admit a
connection. Direct requests retain their selected setup and validate its existence and native
connection generation before calling the funnel. Shared attempts validate their own lifetime.
Retiring the presentation sends no capture, recording or disconnect command.
