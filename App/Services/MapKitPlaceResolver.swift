import CoreLocation
import Foundation
import MapKit
import SyncCore

/// Spaces out requests so the geocoder isn't called more than once per `interval`.
actor RequestThrottle {
    private let interval: TimeInterval
    private var nextSlot: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Returns once the caller may send its request. Callers are released in order.
    func wait() async {
        let now = Date()
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

/// Looks up a place name for a coordinate with MapKit's reverse geocoder.
///
/// Names look like "Paris, France". Results are cached by the sync engine, not here.
struct MapKitPlaceResolver: PlaceResolver {
    private let throttle: RequestThrottle
    private let logger: FileLogger

    init(minimumInterval: TimeInterval = 1.5, logger: FileLogger = .shared) {
        self.throttle = RequestThrottle(interval: minimumInterval)
        self.logger = logger
    }

    func placeName(for coordinate: Coordinate) async -> String? {
        await throttle.wait()
        guard !Task.isCancelled else { return nil }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }

        do {
            let items = try await request.mapItems
            let representations = items.first?.addressRepresentations
            return Self.format(city: representations?.cityName, country: representations?.regionName)
        } catch {
            // The coordinate stays out of the log (D18); the error code is enough.
            let nsError = error as NSError
            logger.warning("Place lookup failed: \(nsError.domain) \(nsError.code)", category: "place")
            return nil
        }
    }

    /// "City, Country", or just the country when there's no city; `nil` when both are empty.
    static func format(city: String?, country: String?) -> String? {
        let city = clean(city)
        let country = clean(country)
        switch (city, country) {
        case let (city?, country?): return "\(city), \(country)"
        case let (city?, nil): return city
        case let (nil, country?): return country
        case (nil, nil): return nil
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
