# GeoSentinel

Two apps that check GPS data for signs of being **faked**, built on one shared Swift detector:

- **GeoSentinel for Mac**: drop a GPS file (`.csv` or `.gpx`) on it and see a verdict, the reasons, and the
  track on a map with the suspicious positions marked. **Downloadable** (see below).
- **GeoSentinel for iPhone**: records your phone's real GPS and checks it. Source only; **not yet built
  or run on a phone** (see the status table further down).

## GeoSentinel for Mac

**Download:** the latest `GeoSentinel-<version>-macOS.zip` from the
[Releases page](https://github.com/samyukthasyamsundar/geo-sentinel-ios/releases). It is one universal
app for Apple Silicon and Intel Macs, macOS 13 or later. Check the download against the `.sha256` file
shown on the release.

**macOS will warn you the first time, and that is expected.** The app is signed ad-hoc and is **not
notarised**, because notarising needs a paid Apple Developer account. Gatekeeper reports it as rejected.
To open it: unzip, then **right-click `GeoSentinel.app`, choose Open, and confirm**. (On newer macOS you may
instead need *System Settings > Privacy & Security > Open Anyway*.) Only do this for a copy you downloaded
from this repository, and compare its SHA-256 first. If you would rather not run an unsigned binary, build it
yourself:

```sh
cd MacApp && Packaging/build_app.sh 1.1.0      # needs the Swift toolchain; writes MacApp/dist/
```

**Use it:** drag a file onto the window (or *Open file...*), and pick the travel mode that matches the trip
(on foot, car, train, aircraft). The mode matters: an aircraft trace analysed with the car limit will look
faked. Your file is read on this Mac and never uploaded; the app has no networking code.

**What you see:** a verdict card (with the reasons), trip stats (duration, positions, distance, top speed,
average), and the path on a plain lat/lon grid coloured by speed (darker is faster). Press play to replay
the trip: the marker only moves along positions that are in the file. Distance and speed are shown **only
when they can be trusted**: when the file's GPS error is larger than the movement (a slow walk, say), the
app says it cannot measure them, draws a plain path, and shows no speed colours rather than inventing
figures. Impossible jumps are left out of the stats and drawn as dashed lines.

**What has and has not been checked:**

| Part | Status |
|------|--------|
| The detector, both parsers, the map geometry, the file loader | **Tested**: 120 + 132 checks pass; each parser defence and the map edge cases (date line, poles, one point, whole-world traces) were broken on purpose to confirm a test fails |
| Every screen (welcome, result, errors) | **Rendered to images and inspected**, which found and fixed real bugs (a map running to the pole, data jammed against the map edge, a legend describing a hidden shape, eight identical findings flooding the list) |
| The packaged app | **Builds, is code-signed (ad-hoc), contains both architectures, and launches and stays running** on an Apple Silicon Mac |
| Drag-and-drop, the file picker, the travel-mode menu, clicking a finding | **Not exercised by anyone.** They compile and are wired up, but nobody has clicked them, because the checks here draw views to images and cannot drive a real window |
| The Intel half of the universal binary | **Built, never run** (the test machine is Apple Silicon) |

A clean verdict cannot rule out a careful fake: replaying realistic-looking movement somewhere else leaves
nothing impossible in the data.

## GeoSentinel for iPhone

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
