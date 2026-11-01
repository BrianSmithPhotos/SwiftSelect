import Foundation

public enum ReverseGeocodeError: Error {
    case requestFailed(Error)
    case noLocationFound
}

/// City/county/state derived from one reverse-geocode lookup. `keywordTokens` is what gets merged
/// into the keyword edit buffer; `contextText` is the compact form passed to the AI prompt as
/// location context (docs/SPEC.md §6/§7) — mirrors the reference app's `ReverseGeocodeResult`.
public struct ReverseGeocodeResult: Equatable {
    public var city: String
    public var county: String
    public var state: String
    /// Nominatim's `ISO3166-2-lvl4` field (e.g. `"US-CA"`) — happens to be exactly eBird's
    /// subnational1 region-code format, so `EBirdSpeciesListService` reuses it directly rather than
    /// deriving a country/state code some other way. `nil` when Nominatim doesn't report an
    /// admin-level-4 boundary for the coordinate (some countries use a different admin level).
    public var stateRegionCode: String? = nil
    /// The named spot inside the town or village (hamlet, district, suburb): "Byland Abbey" inside
    /// Wass, "Pimlico" inside the City of Westminster. The level that actually tells the AI where a
    /// photo was taken; city and county alone read "North Yorkshire" for a whole abbey series.
    public var place: String = ""

    public var keywordTokens: [String] {
        [place == city ? "" : place, city, county, state]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var contextText: String {
        var parts: [String] = []
        if !place.isEmpty, place != city { parts.append("place=\(place)") }
        if !city.isEmpty { parts.append("city=\(city)") }
        if !county.isEmpty { parts.append("county=\(county)") }
        if !state.isEmpty { parts.append("state=\(state)") }
        return parts.joined(separator: "; ")
    }
}

/// Reverse-geocodes a GPS fix into city/county/state via OpenStreetMap's Nominatim, so a location
/// can both become keywords and give the AI suggestion prompt scene context (docs/SPEC.md §6/§7,
/// e.g. helping identify a plausible local bird/plant species). Mirrors the reference app's
/// `ReverseGeocodeService`.
public struct ReverseGeocodeService {
    private static let baseURL = URL(string: "https://nominatim.openstreetmap.org/reverse")!
    /// Nominatim's usage policy requires a descriptive `User-Agent` identifying the application.
    private static let userAgent = "SwiftSelect/0.1 (local desktop photo workflow)"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookupLocation(latitude: Double, longitude: Double) async throws -> ReverseGeocodeResult {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.7f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.7f", longitude)),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            // 14 reaches hamlets and districts. 10 stops at the county for a rural point, and 18
            // names the nearest building (a pub, a rail depot), which would mislead the AI.
            URLQueryItem(name: "zoom", value: "14"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 8

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw ReverseGeocodeError.requestFailed(error)
        }

        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let address = payload["address"] as? [String: Any]
        else { throw ReverseGeocodeError.noLocationFound }

        let city = Self.firstNonEmpty(
            address, keys: ["city", "town", "village", "municipality"])
        let place = Self.firstNonEmpty(
            address, keys: ["hamlet", "suburb", "neighbourhood", "quarter", "locality"])
        let county = Self.firstNonEmpty(address, keys: ["county", "state_district"])
        let state = Self.firstNonEmpty(address, keys: ["state", "region"])
        guard !place.isEmpty || !city.isEmpty || !county.isEmpty || !state.isEmpty else {
            throw ReverseGeocodeError.noLocationFound
        }
        let stateRegionCode = address["ISO3166-2-lvl4"] as? String
        return ReverseGeocodeResult(
            city: city, county: county, state: state, stateRegionCode: stateRegionCode, place: place)
    }

    private static func firstNonEmpty(_ address: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = address[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }
}
