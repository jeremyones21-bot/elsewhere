# Elsewhere

Sets a USB-connected iPhone's location from a Mac. A GhostMe-style tool built on the same mechanism Xcode uses: Developer Mode plus the `LocationSimulation` instruments service.

```
./build.sh            # builds, signs, installs to /Applications
NO_INSTALL=1 ./build.sh
```

Needs Go (`brew install go`) and the Xcode command-line tools.

## How it fits together

- `helper/`: `elsewhere-helper`, a Go program built on [go-ios](https://github.com/danielpaulus/go-ios) (MIT). It runs the iOS 17+ CoreDevice tunnel **in userspace (no sudo)**, triggers Trust pairing, reveals the Developer Mode toggle, downloads and mounts the personalised developer disk image (cached in `~/Library/Application Support/Elsewhere/images`), and sets/resets the location. It talks newline-delimited JSON over stdin/stdout.
- `Sources/`: the SwiftUI app. MapKit handles the map, address search (`MKLocalSearchCompleter`) and routes (`MKDirections`), so no API keys are needed. Bookmarks and history are in `library.json` in the same support folder.

## Gotchas

- **iOS clears the simulated location when the LocationSimulation channel closes.** The go-ios CLI `setlocation` blocks until Ctrl-C for this reason. The helper keeps one channel open per phone. Spawning a process per update would make routes flicker back to the real location.
- Quitting the app closes the helper's stdin, and the helper stops the simulation (giving up after 2s). **Keep After Unplugging** (Location menu or action bar) walks through the Developer Mode trick: once the helper sees Developer Mode off, it detaches the location channel without stopping or closing it, so unplugging and quitting can't undo the location. It holds until the phone restarts. The app can't read the phone's location back, so the steps are confirmed from Developer Mode state and USB presence.
- MapKit has no cycling directions on macOS, so Cycle uses walking paths at 5 m/s. Speeds: walk 1.4 m/s, drive 13 m/s, with one update per second.
- The tunnel-info port is 28150, so a separate `ios tunnel start` agent on 28100 can run alongside.

## Tested

Tested on an iPhone running iOS 27.0 (2026-10-15): about 2s from launch to ready, 0.1s per Change Location, and 15/15 route updates at 1 Hz succeeded. The first location channel over a fresh tunnel once took about 10s, so the helper opens it during setup.
