import Foundation

public enum ElevationLookupError: Error {
    case requestFailed(Error)
    case noUsableValue
}

/// Ground-elevation lookup, keyed by lat/lon — see docs/SPEC.md §7: Timeline's own phone-GPS
/// altitude is untrusted, so altitude always comes from here instead. Points inside the US go to
/// USGS EPQS (1 m grid); everywhere else, and any US point EPQS fails on, goes to Open-Meteo
/// (Copernicus 90 m grid, worldwide). EPQS answers HTTP 200 with "Call failed" outside the US, after
/// taking as long as a real lookup, which is why it is not simply tried first everywhere.
public struct ElevationLookupService {
    private static let usgsURL = URL(string: "https://epqs.nationalmap.gov/v1/json")!
    private static let openMeteoURL = URL(string: "https://api.open-meteo.com/v1/elevation")!
    /// Both services normally answer in about a second; EPQS has been seen taking 30s, which held up
    /// every set in a batch AI run.
    private static let timeoutSeconds: TimeInterval = 8
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookupElevation(latitude: Double, longitude: Double) async throws -> Double {
        if Self.isInUSGSCoverage(latitude: latitude, longitude: longitude),
            let meters = try? await lookupUSGS(latitude: latitude, longitude: longitude)
        {
            return meters
        }
        return try await lookupOpenMeteo(latitude: latitude, longitude: longitude)
    }

    /// Rough boxes for the US states and territories EPQS covers: the lower 48, Alaska, Hawaii and
    /// Puerto Rico with the Virgin Islands. They spill over into Canada and Mexico, which is fine:
    /// a failed EPQS lookup there falls through to Open-Meteo.
    static func isInUSGSCoverage(latitude: Double, longitude: Double) -> Bool {
        let boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = [
            (24.4, 49.4, -125.0, -66.9),
            (51.0, 71.5, -180.0, -129.0),
            (18.9, 22.3, -160.3, -154.8),
            (17.6, 18.6, -67.3, -64.5),
        ]
        return boxes.contains {
            (($0.minLat)...($0.maxLat)).contains(latitude) && (($0.minLon)...($0.maxLon)).contains(longitude)
        }
    }

    private func lookupUSGS(latitude: Double, longitude: Double) async throws -> Double {
        var components = URLComponents(url: Self.usgsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "x", value: String(format: "%.7f", longitude)),
            URLQueryItem(name: "y", value: String(format: "%.7f", latitude)),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "wkid", value: "4326"),
            URLQueryItem(name: "includeDate", value: "false"),
        ]
        guard let value = Self.extractValue(from: try await fetchJSON(components.url!)) else {
            throw ElevationLookupError.noUsableValue
        }
        return value
    }

    private func lookupOpenMeteo(latitude: Double, longitude: Double) async throws -> Double {
        var components = URLComponents(url: Self.openMeteoURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.7f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.7f", longitude)),
        ]
        guard let value = Self.extractOpenMeteoValue(from: try await fetchJSON(components.url!)) else {
            throw ElevationLookupError.noUsableValue
        }
        return value
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeoutSeconds
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw ElevationLookupError.requestFailed(error)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElevationLookupError.noUsableValue
        }
        return payload
    }

    /// Open-Meteo answers `{"elevation":[129.0]}`: one value per requested point.
    static func extractOpenMeteoValue(from payload: [String: Any]) -> Double? {
        (payload["elevation"] as? [Any])?.first.flatMap(toDouble)
    }

    /// Handles the handful of known EPQS response shapes the reference app defends against.
    public static func extractValue(from payload: [String: Any]) -> Double? {
        if let direct = toDouble(payload["value"]) {
            return direct
        }
        if let nested = payload["USGS_Elevation_Point_Query_Service"] as? [String: Any],
            let elevationQuery = nested["Elevation_Query"] as? [String: Any],
            let elevation = toDouble(elevationQuery["Elevation"])
        {
            return elevation
        }
        if let elevation = toDouble(payload["elevation"]) {
            return elevation
        }
        return nil
    }

    private static func toDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}
