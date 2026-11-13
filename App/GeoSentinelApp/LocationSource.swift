import CoreLocation
import GeoSentinelKit

/// Feeds REAL GPS fixes from the phone into a LiveRecorder. Nothing is simulated, and nothing leaves the
/// device: there is no networking code in this app.
///
/// NOT COMPILED OR RUN by the author (no iOS SDK was available); see the README.
@MainActor
final class LocationSource: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isRecording = false
    @Published private(set) var fixCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isSimulatedBySoftware = false

    let recorder = LiveRecorder()
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        status = manager.authorizationStatus
    }

    func start() {
        lastError = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // the system shows the permission prompt
        case .authorizedWhenInUse, .authorizedAlways:
            recorder.reset(); fixCount = 0; rejectedCount = 0; isSimulatedBySoftware = false
            manager.startUpdatingLocation()
            isRecording = true
        default:
            lastError = "Location access is off. Turn it on in Settings > Privacy > Location Services."
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isRecording = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            if self.isRecording == false && (s == .authorizedWhenInUse || s == .authorizedAlways) { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for loc in locations {
                // horizontalAccuracy < 0 means "invalid"; LiveRecorder rejects those too.
                self.recorder.add(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                  accuracyM: loc.horizontalAccuracy, time: loc.timestamp)
                // iOS 15+ marks locations produced by software (developer tools, mock-location apps).
                // Reporting it is exactly this app's purpose, and it needs no workaround or evasion.
                if let src = loc.sourceInformation, src.isSimulatedBySoftware { self.isSimulatedBySoftware = true }
            }
            self.fixCount = self.recorder.fixes.count
            self.rejectedCount = self.recorder.rejected
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}
