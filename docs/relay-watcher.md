# Watching a shared feed

The cameras page and the first-pair help menu open **Watch a feed**. A nearby
broadcast row opens that same browse screen. Choosing a broadcast there starts
its existing relay connection; the monitor appears after the host accepts it.
A failed or locked initial join stays on the browse screen, where the operator
can enter a passcode, choose a current broadcast, refresh discovery or close.

Use regular Wi-Fi that lets both devices reach each other. The camera's access
point can advertise a feed while blocking the connection between its clients;
the existing camera-network notice still explains that refusal. A missing camera
name remains unknown rather than borrowing the device name or address.

Closing browse before joining leaves the Nikon first-pair wizard and ordinary
nearby-camera list in place. Closing an attempted relay join uses the existing
leave action. Remembered passcodes, approval identity, transport, decoding and
recovery keep their existing owners and storage namespaces.

Both native shells compose the shared camera-controls `WatcherBrowse` with a
typed host over their deployed relay facade. Network guidance is a host value.
The iOS default guidance used by the other thin apps is preserved. Android has
no watcher entry in the current Pocket or Insta shells, so those apps need no
new relay adapter.

Automated local scenarios use simulated reports and loopback hosts. Physical
watcher behavior on iOS and Android remains untested until separately qualified.
