import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class ElevationLookupServiceTests: XCTestCase {
    override func tearDown() {
        ElevationMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeService() -> ElevationLookupService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevationMockURLProtocol.self]
        return ElevationLookupService(session: URLSession(configuration: configuration))
    }

    private func respond(_ request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, body.data(using: .utf8)!)
    }

    // MARK: - Routing

    func testPointOutsideTheUSGoesStraightToOpenMeteo() async throws {
        var hosts: [String] = []
        ElevationMockURLProtocol.requestHandler = { [self] request in
            hosts.append(request.url!.host!)
            return respond(request, #"{"elevation":[129.0]}"#)
        }

        let meters = try await makeService().lookupElevation(latitude: 48.8867, longitude: 2.3431)

        XCTAssertEqual(meters, 129.0)
        XCTAssertEqual(hosts, ["api.open-meteo.com"])
    }

    func testPointInsideTheUSUsesUSGS() async throws {
        var hosts: [String] = []
        ElevationMockURLProtocol.requestHandler = { [self] request in
            hosts.append(request.url!.host!)
            return respond(request, #"{"value":"71.782798767"}"#)
        }

        let meters = try await makeService().lookupElevation(latitude: 45.5, longitude: -122.6)

        XCTAssertEqual(meters, 71.782798767)
        XCTAssertEqual(hosts, ["epqs.nationalmap.gov"])
    }

    /// EPQS's real answer for a point it has no data for: HTTP 200, with the error in `value`.
    func testUSGSFailureFallsBackToOpenMeteo() async throws {
        var hosts: [String] = []
        ElevationMockURLProtocol.requestHandler = { [self] request in
            hosts.append(request.url!.host!)
            if request.url!.host == "epqs.nationalmap.gov" {
                return respond(request, #"{"value":"Call failed.  [Failed cloud operation]"}"#)
            }
            return respond(request, #"{"elevation":[640.0]}"#)
        }

        let meters = try await makeService().lookupElevation(latitude: 49.2, longitude: -123.1)

        XCTAssertEqual(meters, 640.0)
        XCTAssertEqual(hosts, ["epqs.nationalmap.gov", "api.open-meteo.com"])
    }

    func testRequestsUseAShortTimeout() async throws {
        var timeout: TimeInterval?
        ElevationMockURLProtocol.requestHandler = { [self] request in
            timeout = request.timeoutInterval
            return respond(request, #"{"elevation":[14.0]}"#)
        }

        _ = try await makeService().lookupElevation(latitude: 36.8, longitude: 10.18)

        XCTAssertEqual(timeout, 8)
    }

    func testOpenMeteoFailureThrows() async {
        ElevationMockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }

        do {
            _ = try await makeService().lookupElevation(latitude: 36.8, longitude: 10.18)
            XCTFail("Expected requestFailed")
        } catch let error as ElevationLookupError {
            guard case .requestFailed = error else { return XCTFail("Expected .requestFailed, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCoverageBoxesIncludeUSStatesAndExcludeEurope() {
        XCTAssertTrue(ElevationLookupService.isInUSGSCoverage(latitude: 45.5, longitude: -122.6))
        XCTAssertTrue(ElevationLookupService.isInUSGSCoverage(latitude: 61.2, longitude: -149.9))
        XCTAssertTrue(ElevationLookupService.isInUSGSCoverage(latitude: 21.3, longitude: -157.8))
        XCTAssertFalse(ElevationLookupService.isInUSGSCoverage(latitude: 48.8867, longitude: 2.3431))
        XCTAssertFalse(ElevationLookupService.isInUSGSCoverage(latitude: 54.2, longitude: -1.16))
    }

    func testExtractsOpenMeteoArrayValue() {
        XCTAssertEqual(ElevationLookupService.extractOpenMeteoValue(from: ["elevation": [129.0]]), 129.0)
        XCTAssertNil(ElevationLookupService.extractOpenMeteoValue(from: ["elevation": [Double]()]))
    }

    // MARK: - USGS response shapes

    // Fixtures shaped like the reference app's known USGS EPQS response variants
    // (elevation_lookup_service.py's `_extract_value`).

    func testExtractsDirectValueField() {
        let payload: [String: Any] = ["value": "123.45"]

        XCTAssertEqual(ElevationLookupService.extractValue(from: payload), 123.45)
    }

    func testExtractsNestedUSGSElevationQueryField() {
        let payload: [String: Any] = [
            "USGS_Elevation_Point_Query_Service": [
                "Elevation_Query": [
                    "Elevation": 456.7
                ]
            ]
        ]

        XCTAssertEqual(ElevationLookupService.extractValue(from: payload), 456.7)
    }

    func testExtractsFlatElevationField() {
        let payload: [String: Any] = ["elevation": 78.9]

        XCTAssertEqual(ElevationLookupService.extractValue(from: payload), 78.9)
    }

    func testReturnsNilForUnrecognizedShape() {
        let payload: [String: Any] = ["somethingElse": 1]

        XCTAssertNil(ElevationLookupService.extractValue(from: payload))
    }
}

private final class ElevationMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
