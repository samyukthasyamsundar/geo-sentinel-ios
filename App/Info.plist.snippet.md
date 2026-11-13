# Settings the Xcode project needs (not generated here)

When you create the Xcode project (see the README), add this to the target's Info (or Info.plist):

    NSLocationWhenInUseUsageDescription =
        "GeoSentinel reads your phone's GPS to check whether the recorded location looks genuine. Nothing leaves your phone."

Without it iOS will refuse to show the location permission prompt and the app will record nothing.
