# GeoSentinel for iPhone

An iPhone app that records your phone's **real GPS** (with your permission) and checks it for signs
of being faked: impossible speed, teleports, impossible acceleration, and machine-regular movement.
It also reports when iOS itself says a location was produced by software rather than the GPS chip.

It is the mobile counterpart of [geo-sentinel](https://github.com/samyukthasyamsundar/geo-sentinel),
a Go command-line tool, and the detection logic is ported to Swift and checked against it.

- **Real data only.** Nothing is simulated or generated.
- **Everything stays on the phone.** The app contains no networking code, no account, no upload.
- **It detects; it never fakes.** It does not change, send or spoof any location.

## What is verified and what is not

This matters, so it is stated up front.

| Part | Status |
|------|--------|
| `GeoSentinelKit` (all detection logic, CSV parser, live recorder) | **Built and tested.** 99 checks pass on macOS with Swift 6.3 and only the command-line tools. |
| Same verdicts as the Go tool | **Verified** on 13 files: the six example traces plus single glitches, a two-fix excursion, a 130-fix zig-zag and repeated outliers. |
| The SwiftUI app in `App/` | **Written, syntax-checked and type-checked against the macOS SDK. Never compiled for iOS and never run on a phone or simulator.** |
| iOS-only calls: `requestWhenInUseAuthorization`, `.authorizedWhenInUse`, `activityType`, `pausesLocationUpdatesAutomatically`, `sourceInformation.isSimulatedBySoftware` | **Unchecked.** They do not exist in the macOS SDK, so they were written from documentation. These are the first places to look if the first build fails. |

The machine this was written on had no Xcode and no iOS SDK, so an iPhone build was not possible
there. **Expect to fix a small compile error or two on first build.**

## Run the logic checks (any Mac with Swift)

```sh
swift run KitChecks                 # 99 checks; exits non-zero if any fail
swift run KitDemo TestData/fake_teleport.csv
```

(`swift test` is not used because XCTest and swift-testing need a full Xcode install; `KitChecks`
is a small self-contained runner that works without one.)

## Build the app (needs Xcode 15+ and an iPhone or simulator)

1. Install **Xcode** from the Mac App Store and open it once.
2. **File > New > Project > iOS > App**, name it `GeoSentinel`, interface **SwiftUI**.
3. Delete the generated `ContentView.swift` and `...App.swift`, and drag in the three files from
   `App/GeoSentinelApp/`.
4. **File > Add Package Dependencies > Add Local...** and choose this folder. Add the
   `GeoSentinelKit` library to the app target.
5. In the target's **Info** tab add the key `Privacy - Location When In Use Usage Description` with a
   sentence such as the one in `App/Info.plist.snippet.md`. Without it iOS shows no permission prompt
   and the app records nothing.
6. Choose your phone (or a simulator) and run. On a real phone, set a development team under
   **Signing & Capabilities**. A free Apple ID works but the app expires after 7 days.

In the **simulator**, use *Features > Location* to feed movement, and iOS will mark those locations as
simulated, which the app reports. That is the app working, not a bug.

## What it cannot do

- **It cannot catch a careful fake.** If someone replays realistic-looking movement somewhere else,
  the trace contains nothing impossible. Catching that needs evidence from outside the trace.
- **Sudden speed changes inside the reported GPS error are not flagged.** This is deliberate, to avoid
  false accusations, and it means some real anomalies are missed.
- It judges only the trace recorded on this phone. It cannot check anyone else's location.
- Thresholds suit people, bikes and cars. A flight will be called faked.
- It needs a minute or two of movement to say anything.
- The thresholds were chosen against a simulator I wrote, not real recorded traces.

## Layout

| Path | What |
|------|------|
| `Sources/GeoSentinelKit` | the detection logic (no iOS dependency) |
| `Sources/KitChecks` | the test runner |
| `Sources/KitDemo` | prints a verdict for a CSV file |
| `TestData` | the example traces, shared with the Go tool |
| `App/GeoSentinelApp` | the SwiftUI app (untested on iOS) |

## License

MIT.
