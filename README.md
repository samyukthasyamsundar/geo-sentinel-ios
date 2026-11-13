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
| The Xcode project file | **Generated and validated as a well-formed file** (valid plist, all three source files referenced, local package linked, iOS 16 target, location permission string present). Never opened in Xcode. |
| The SwiftUI app in `App/` | **Written, syntax-checked and type-checked against the macOS SDK. Never compiled for iOS and never run on a phone or simulator.** |
| iOS-only calls: `requestWhenInUseAuthorization`, `.authorizedWhenInUse`, `activityType`, `pausesLocationUpdatesAutomatically` | **Checked against Apple's CoreLocation header** in the macOS SDK: they exist, are marked iOS-only (which is why they cannot compile on a Mac), and the names and types match. Still never compiled for iOS. |
| `CLLocation.sourceInformation` / `isSimulatedBySoftware` (the "iOS says this was produced by software" hint) | **Could not be checked**: it is in no header available here and was written from memory. It is isolated in one function (`producedBySoftware`); if it fails to compile, make that function `return false` and everything else works. |

The machine this was written on had no Xcode and no iOS SDK, so an iPhone build was not possible
there. **Expect to fix a small compile error or two on first build.**

## Run the logic checks (any Mac with Swift)

```sh
GEOSENTINEL_TOOLS=1 swift run KitChecks                 # 99 checks; exits non-zero if any fail
GEOSENTINEL_TOOLS=1 swift run KitDemo TestData/fake_teleport.csv
```

(The tools are hidden behind that variable so that Xcode, which resolves this package for the app,
sees the library alone.)

(`swift test` is not used because XCTest and swift-testing need a full Xcode install; `KitChecks`
is a small self-contained runner that works without one.)

## Build the app (needs Xcode 15+ and an iPhone or simulator)

The Xcode project is generated from `project.yml` and is checked in, so you do not need to click
through Xcode's project wizard.

1. Install **Xcode** from the Mac App Store (a large download, about 35 GB) and open it once so it
   finishes installing its components.
2. Open `GeoSentinel.xcodeproj`. (To regenerate it after editing `project.yml`: `brew install xcodegen`
   then `xcodegen generate`.)
3. Select the **GeoSentinel** target, then **Signing & Capabilities**, tick *Automatically manage
   signing* and pick your **Team** (a free Apple ID works; the app expires after 7 days). Change the
   bundle identifier from `com.example.GeoSentinel` to something unique, such as
   `com.yourname.GeoSentinel`.
4. Pick your iPhone (or a simulator) at the top and press **Run**. On a real phone, the first time you
   may need to trust the developer under *Settings > General > VPN & Device Management*.
5. When asked, allow location access. (The permission text is already set in the project.)

**If the build fails**, the likeliest cause is `producedBySoftware` in `LocationSource.swift`, the one
call that could not be checked against Apple's headers. Replace its body with `return false` and build
again; you lose only the extra "iOS says this was produced by software" hint.

In the **simulator**, use *Features > Location* to feed movement. iOS marks those locations as
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
| `project.yml`, `GeoSentinel.xcodeproj` | the Xcode project (generated by XcodeGen; checked as a valid file, never opened in Xcode) |

## License

MIT.
