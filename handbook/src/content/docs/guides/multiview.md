---
title: Multiview
description: Monitor and record up to four Nikon Z bodies on one phone, on iPhone, iPad and Android.
---

**Beta feature. Nikon Multiview has not been tested on camera hardware yet.**
Every camera behavior on this page is untested on Z bodies until the hardware
pass is done. Multiview is on iPhone, iPad and Android phones.

OpenZCine's Multiview is the same Multiview as OpenPocketCine's: the same
stage, toolbar, Add camera list, tiles, record lamp, settings popup, Live View
hand-off, Auto LUT and close. It differs only where a Z body cannot do what a
Pocket does; those differences are listed in
[What is different for Nikon](#what-is-different-for-nikon).

From **Your cameras**, tap the grid icon at the top-right of the camera list.
Center stage opens with space for four cameras. There is no network setup step:
the bodies are already on the network the phone is on.

## Before you start

The app cannot move a Z body onto a network. Put each body on the same network
as the phone from the camera's own menu first:

- **A router or venue Wi-Fi**: on the camera, use the network menu's connection
  to a router (Connect to computer, then the router network you saved), and
  join the phone to the same network.
- **This phone's hotspot**: turn on the phone's hotspot, then join each body to
  it from the camera's network menu. On iPhone, enable **Allow Others to Join**
  and **Maximize Compatibility**.

Pair each body with OpenZCine once from **Your cameras** first (the camera shows
its pairing code on the first connection). Multiview opens paired bodies; it does
not show a pairing code itself.

USB-C and the camera's own Wi-Fi (its access point) cannot share a network with
other bodies, so they do not join Multiview.

## Add a camera

Tap an empty tile's **Add camera**. The list shows bodies the phone sees on its
network and the router and hotspot setups saved in **Your cameras**. Listing never
connects to a camera: only the body you pick is opened, and its serial number is
checked before its picture shows. A body already in Multiview, or in use on another
phone or tablet, is not listed. Adding a camera never takes a body from another
device.

Bodies that another OpenZCine device holds are left alone: connecting to a Z body
from a second device ends the first device's session.

## Tiles, layout and tools

Layout (**Grid** or **Center stage**), **FIT/FILL**, the collapsible toolbar,
DISP and Record sit where they are in Live View, as in OpenPocketCine. Each tile
shows the camera's name, its battery, its free card space, its timecode
(**HH:MM:SS**, from the camera's live-view header) and its recording state. The
selected camera's ISO, shutter, white balance and focus mode read along the
bottom. Unknown values show a dash; nothing is guessed.

**Camera settings** opens the floating settings popup with one tab per camera:
ISO, shutter, exposure compensation, white balance, focus mode, aperture (where
the lens reports one) and frame rate, with the same drums as Live View. A change
goes to that camera only and the camera's own read-back decides what is shown.
Nikon has no mode, color or audio control in the popup.

**Auto LUT starts on for each camera.** It follows the tone the camera records
in: N-Log uses the N-Log look and Log3G10 (R3D NE) the Log3G10 look; SDR and HLG
need none. The toolbar's LUT button toggles it for all cameras and a tile's
camera options toggle it for one. The LUT affects monitoring only. Whether a
body's live-view picture carries its log curve is untested.

## Recording

The record lamp starts every camera at once, or stops them all when any camera
records. It is strict, as in OpenPocketCine: it is offered only while every
camera's recording state is current, and each camera confirms its own result;
partial failures stay visible on their tiles. A tile's camera options start or
stop that camera alone. Both follow the **Record confirmation** preference in
Settings. This is a shared command, not frame-accurate synchronized recording.

Commands go out between two live-view frames on that camera's own session.

## Live View

Double-tap a connected tile to open the normal Live View for that camera, on the
session the tile already holds (no new connection). The other cameras keep
streaming. The grid button returns to the stage, and the tile resumes on the same
session.

## Recovery

When a tile's picture stops (three missed frames), Multiview first restarts live
view on the same session, then reopens the same body at its address. Every
reopen waits at least 1.2 seconds after the last connection to that body closed,
and reopens are at least five seconds apart. Each automatic attempt counts
against the tile's small recovery budget; thirty seconds of healthy picture
restore it. When the budget is spent the tile shows **Could not restore preview.
Tap Reconnect to try again.** If another device took the body meanwhile, the tile
says which device and waits for you: Multiview never takes the camera back on its
own. If the phone leaves the network for more than 45 seconds, tiles show that
the shared network is unavailable.

All of this is untested on Z bodies.

## Close

Closing Multiview ends each camera's session. Cameras stay on their network and
keep recording; nothing is sent to them on close, and they are not moved back
anywhere. Use a tile's recording action first if you want to stop a take.

The stage's layout, selection and Fit/Fill are kept from the previous Multiview.
Cameras are not reconnected when Multiview opens again.

## What is different for Nikon

| OpenPocketCine | OpenZCine |
| --- | --- |
| The network wizard picks a router network or the phone's hotspot. | No wizard: the bodies are put on the network from their own menus. |
| Add camera lists nearby cameras over Bluetooth and moves the picked camera onto the network. | Add camera lists bodies already on the phone's network and saved router and hotspot setups; nothing is moved. |
| Discovery probes the network for the picked camera. | Nothing is probed: a camera is opened only at the address it was seen or saved at. |
| Closing returns cameras to their own Wi-Fi. | Closing returns nothing: the bodies stay on the network. |
| Settings popup includes mode, color and audio. | Mode, color and audio are not in the popup. |
| Hardware validated on Pocket 3, Pocket 4 Pro and Nano. | Untested on Z bodies. |
