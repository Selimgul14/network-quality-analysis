import XCTest
@testable import WiFiProbeKit

final class EndpointsTests: XCTestCase {

    private let config = ProbeConfig(
        probeID: "iphone13-selim",
        site: "phone-test",
        ingestURL: URL(string: "https://comp702-api.azurewebsites.net/ingest")!,
        ingestToken: "t",
        apiBase: URL(string: "https://comp702-api.azurewebsites.net")!,
        dashUser: "wifi",
        dashPass: "p",
        cloudBase: URL(string: "https://comp702-ref.azurewebsites.net")!,
        realWeb: URL(string: "https://www.bbc.co.uk/news")!,
        realVideo: URL(string: "https://test-videos.co.uk/clip.mp4")!,
        realDownload: URL(string: "http://ipv4.download.thinkbroadband.com/50MB.zip")!
    )

    /// M2: cloud and real only. A `local` target here would mean the app
    /// had invented a reference host that does not exist at the site.
    func testApplicationWorkloadsHaveNoLocalEndpoint() {
        for workload in [Workload.web, .video, .download] {
            let targets = Endpoints.targets(for: workload, config: config)
            XCTAssertEqual(targets.map(\.endpoint), [.cloud, .real], "\(workload)")
        }
    }

    func testCloudTargetsUseTheReferenceImagePaths() {
        let web = Endpoints.targets(for: .web, config: config)[0]
        XCTAssertEqual(web.url.absoluteString,
                       "https://comp702-ref.azurewebsites.net/page/index.html")
        let download = Endpoints.targets(for: .download, config: config)[0]
        XCTAssertEqual(download.url.absoluteString,
                       "https://comp702-ref.azurewebsites.net/files/testfile.bin")
    }

    func testRealTargetsComeFromConfig() {
        XCTAssertEqual(Endpoints.targets(for: .web, config: config)[1].url, config.realWeb)
        XCTAssertEqual(Endpoints.targets(for: .video, config: config)[1].url, config.realVideo)
        XCTAssertEqual(Endpoints.targets(for: .download, config: config)[1].url,
                       config.realDownload)
    }

    /// N3.
    func testEmailHasNoTargets() {
        XCTAssertTrue(Endpoints.targets(for: .email, config: config).isEmpty)
    }

    /// The probe labels the latency-under-load run `real` and points it at
    /// a file large enough to saturate the link.
    func testLoadLatRunsOnceAgainstReal() {
        let targets = Endpoints.targets(for: .loadlat, config: config)
        XCTAssertEqual(targets, [EndpointTarget(.real, config.realDownload)])
    }

    // MARK: baseline destination classes

    func testBaselineCoversEveryDestinationClass() {
        let targets = Endpoints.baselineTargets(config: config, gateway: "192.168.1.1")
        XCTAssertEqual(targets, [
            // The gateway falls back to TCP when it ignores echo requests,
            // which a managed campus router does.
            BaselineTarget(.local, "192.168.1.1", .icmpThenTCP),
            BaselineTarget(.cloud, "comp702-ref.azurewebsites.net", .tcp),
            BaselineTarget(.real, "1.1.1.1", .icmp),
            BaselineTarget(.real, "8.8.8.8", .icmp),
            BaselineTarget(.real, "www.google.com", .icmp),
        ])
    }

    /// If gateway discovery fails there is no local leg to probe. The run
    /// carries on: the other classes still measure.
    func testBaselineOmitsGatewayWhenUndiscovered() {
        let targets = Endpoints.baselineTargets(config: config, gateway: nil)
        XCTAssertFalse(targets.contains { $0.endpoint == .local })
        XCTAssertEqual(targets.count, 4)
    }

    // MARK: site labelling (C2)

    func testSiteLabelAlwaysCarriesThePrefix() {
        XCTAssertEqual(SiteLabel.make(from: "Halls Room"), "phone-halls-room")
        XCTAssertEqual(SiteLabel.make(from: "phone-library"), "phone-library")
    }

    func testEmptySiteLabelIsRefused() {
        XCTAssertNil(SiteLabel.make(from: ""))
        XCTAssertNil(SiteLabel.make(from: "   "))
    }
}
