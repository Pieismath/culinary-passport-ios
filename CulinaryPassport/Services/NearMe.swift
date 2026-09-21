import CoreLocation

/// Where the traveller is right now, asked for once and only when a feature
/// needs it (restaurants near you). Never stored, never sent anywhere.
@MainActor
final class NearMe: NSObject, CLLocationManagerDelegate {
    static let shared = NearMe()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private var last: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    /// A recent fix, or nil if location is off or it takes too long.
    func location(timeout: Duration = .seconds(8)) async -> CLLocation? {
        if let last, last.timestamp.timeIntervalSinceNow > -600 { return last }
        guard !isDenied else { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 {
                if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else {
                    manager.requestLocation()
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finish(nil)
                }
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        if let location { last = location }
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard !waiting.isEmpty else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last
        MainActor.assumeIsolated { finish(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
