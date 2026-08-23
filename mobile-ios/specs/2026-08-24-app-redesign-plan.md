# App Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the WiFi link measurable on any network whose router answers anything, and turn the app from a debugging readout into a three-tab product that keeps its results.

**Architecture:** All logic stays in the `WiFiProbeKit` SwiftPM package so it builds and tests from the command line with no simulator; the app target is SwiftUI only. The WiFi-link measurement becomes a three-rung ladder (ICMP echo, TTL-limited time exceeded, TCP on-link). Finished runs persist to disk as JSON through an actor, and per-site aggregation over those runs feeds the Trends tab.

**Tech Stack:** Swift 6.2 toolchain, swift-tools-version 5.9, iOS 17 / macOS 14 deployment targets, SwiftUI, Observation, Swift Charts, XCTest. No third-party packages.

**Spec:** `src/mobile-ios/specs/2026-08-24-app-redesign-design.md`

## Global Constraints

- No third-party dependencies (REQUIREMENTS.md N10). Swift Charts is a system framework and is permitted.
- Nothing outside `src/mobile-ios/` may be modified, except `CLAUDE.md` and `dissertation/plan.md`, which are already authorised (CONSTRAINTS.md C1).
- Phone records keep the forced `phone-` site prefix; the app refuses to run unlabelled (C2).
- The ingest token and dashboard password never enter a committed file (C5).
- `contracts/measurement.schema.json` is authoritative and read-only (C8). Metric values may be numbers or strings; new metric keys are allowed, new top-level keys are not.
- Working directory for every command below: `src/mobile-ios/WiFiProbeKit` unless a path says otherwise.
- Test command: `swift test`. Full suite must stay green; it is 89 tests (2 skipped) at the start of this plan.
- Prose rules for all comments and user-facing copy: no em dashes, no emoji, and avoid the words "genuinely", "honestly", "straightforward".

---

### Task 1: ICMP replies are parsed at the right offset

The bug that made the WiFi link unmeasurable. A `SOCK_DGRAM` ICMP socket on Darwin delivers the IP header, so byte 0 is `0x45`, never the ICMP type. Every reply was rejected and every host read as 100% loss.

**Files:**
- Create: `Tests/WiFiProbeKitTests/Fixtures/icmp-echo-reply.bin`
- Modify: `Sources/WiFiProbeKit/Net/ICMPPinger.swift`
- Test: `Tests/WiFiProbeKitTests/ICMPTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ICMPPinger.ParsedICMP` (a struct with `let type: UInt8` and `let sequence: UInt16`, `Equatable`), and `static func parseReply(_ buffer: [UInt8], count: Int) -> ParsedICMP?`. Task 2 extends this function.

- [ ] **Step 1: Create the fixture from a real captured reply**

This is a real 84-byte echo reply captured from the halls gateway (10.93.0.1) on 24 August 2026: 20 bytes of IPv4 header, then ICMP type 0, identifier 0, sequence 4242 (`0x1092`), then a 56-byte payload.

```bash
printf '450040003c280000400126f10a5d00010a5d02d60000177a0000109208090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f' \
  | xxd -r -p > Tests/WiFiProbeKitTests/Fixtures/icmp-echo-reply.bin
test $(wc -c < Tests/WiFiProbeKitTests/Fixtures/icmp-echo-reply.bin) -eq 84 && echo OK
```

Expected: `OK`

- [ ] **Step 2: Write the failing tests**

Append to `Tests/WiFiProbeKitTests/ICMPTests.swift`:

```swift
// MARK: reply parsing

/// The bug this fixture exists for: on Darwin a SOCK_DGRAM ICMP socket
/// hands back the IP header as well, so the ICMP type is not at byte 0.
/// Reading it there yields 0x45, the version and IHL nibble, and every
/// reply is discarded as "not an echo reply".
func testParsesEchoReplyPastTheIPHeader() throws {
    let data = try fixture("icmp-echo-reply.bin")
    let parsed = try XCTUnwrap(ICMPPinger.parseReply([UInt8](data), count: data.count))
    XCTAssertEqual(parsed.type, 0)
    XCTAssertEqual(parsed.sequence, 4242)
}

/// The IHL is read rather than assumed, so a header carrying options is
/// still parsed correctly. Built by widening the fixture's header to 24
/// bytes and inserting four bytes of IP option padding.
func testHonoursAnIPHeaderWithOptions() throws {
    var bytes = [UInt8](try fixture("icmp-echo-reply.bin"))
    bytes[0] = 0x46                                  // IHL 6, so 24 bytes
    bytes.insert(contentsOf: [0x01, 0x01, 0x01, 0x00], at: 20)
    let parsed = try XCTUnwrap(ICMPPinger.parseReply(bytes, count: bytes.count))
    XCTAssertEqual(parsed.type, 0)
    XCTAssertEqual(parsed.sequence, 4242)
}

func testRejectsATruncatedDatagram() {
    let bytes = [UInt8](repeating: 0x45, count: 12)
    XCTAssertNil(ICMPPinger.parseReply(bytes, count: bytes.count))
}

func testRejectsANonEchoReply() throws {
    var bytes = [UInt8](try fixture("icmp-echo-reply.bin"))
    bytes[20] = 3                                    // destination unreachable
    XCTAssertNil(ICMPPinger.parseReply(bytes, count: bytes.count))
}
```

If `ICMPTests.swift` has no `fixture` helper, add this to the same file:

```swift
private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                              withExtension: nil))
    return try Data(contentsOf: url)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ICMPTests`
Expected: FAIL, "type 'ICMPPinger' has no member 'parseReply'"

- [ ] **Step 4: Implement the parser**

In `Sources/WiFiProbeKit/Net/ICMPPinger.swift`, add inside `public enum ICMPPinger`, next to `echoPacket`:

```swift
    /// One parsed reply: the ICMP type, and the sequence number that
    /// identifies which of our packets it answers.
    public struct ParsedICMP: Equatable, Sendable {
        public let type: UInt8
        public let sequence: UInt16
    }

    /// Parse one datagram received on a `SOCK_DGRAM` ICMP socket.
    ///
    /// Darwin includes the IPv4 header in what it hands back, unlike
    /// Linux, so the ICMP header starts at the IHL rather than at byte 0.
    /// The IHL is read rather than assumed to be 20, because a header
    /// carrying options is longer and a fixed offset would then land in
    /// the middle of the ICMP header.
    ///
    /// Replies are matched on sequence, not identifier: the kernel owns
    /// the identifier field on a datagram socket.
    public static func parseReply(_ buffer: [UInt8], count: Int) -> ParsedICMP? {
        guard count >= 20, buffer.count >= count else { return nil }
        guard buffer[0] >> 4 == 4 else { return nil }
        let ipHeader = Int(buffer[0] & 0x0F) * 4
        guard ipHeader >= 20, count >= ipHeader + 8 else { return nil }

        let type = buffer[ipHeader]
        guard type == echoReply else { return nil }
        let sequence = UInt16(buffer[ipHeader + 6]) << 8 | UInt16(buffer[ipHeader + 7])
        return ParsedICMP(type: type, sequence: sequence)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ICMPTests`
Expected: PASS

- [ ] **Step 6: Use the parser in the receive loop**

In `pingSync`, replace the body of `collect(until:)`:

```swift
        func collect(until deadline: TimeInterval) {
            var buffer = [UInt8](repeating: 0, count: 1024)
            while Date().timeIntervalSince1970 < deadline {
                let received = recv(handle, &buffer, buffer.count, 0)
                guard received > 0,
                      let parsed = parseReply(buffer, count: received),
                      let start = sentAt.removeValue(forKey: parsed.sequence) else { continue }
                rtts.append((Date().timeIntervalSince1970 - start) * 1000)
            }
        }
```

Then delete the now-wrong sentence from the type's doc comment, the one reading "the received buffer starts at the ICMP header with no IP header to skip", and replace it with:

```swift
/// the kernel rewrites the identifier field, so replies are matched on
/// sequence number, and the received buffer carries the IPv4 header ahead
/// of the ICMP one, so `parseReply` skips it by reading the IHL.
```

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS. Tests that previously skipped with "gateway does not answer ICMP here" or "ICMP echo appears to be filtered" should now run, because they skip on exactly the symptom this bug produced. Note in the commit message how many previously-skipped tests now execute.

- [ ] **Step 8: Commit**

```bash
git add Sources/WiFiProbeKit/Net/ICMPPinger.swift \
        Tests/WiFiProbeKitTests/ICMPTests.swift \
        Tests/WiFiProbeKitTests/Fixtures/icmp-echo-reply.bin
git commit -m "Mobile: parse ICMP replies past the IP header

A SOCK_DGRAM ICMP socket on Darwin delivers the IPv4 header as well,
so the type was read as 0x45 and every reply discarded. The WiFi link
therefore read as 100% loss on every network, which was blamed on the
campus router. It answers echo in 3.2 ms."
```

---

### Task 2: TTL-limited probing and time-exceeded replies

The second rung. A router that drops packets addressed to itself must still return ICMP time exceeded when a TTL expires, which is how `mtr` gets hop 1 on the Pi.

**Files:**
- Create: `Tests/WiFiProbeKitTests/Fixtures/icmp-time-exceeded.bin`
- Modify: `Sources/WiFiProbeKit/Net/ICMPPinger.swift`
- Test: `Tests/WiFiProbeKitTests/ICMPTests.swift`

**Interfaces:**
- Consumes: `ICMPPinger.parseReply(_:count:)` and `ParsedICMP` from Task 1.
- Produces: `ICMPPinger.firstHop(via:count:interval:) async throws -> PingStats.Summary`, and an extended `parseReply` that also returns type 11 replies with the sequence recovered from the quoted original datagram.

- [ ] **Step 1: Create the fixture**

A real 112-byte time-exceeded reply from 10.93.0.1, captured on 24 August 2026 by sending an echo to 1.1.1.1 with `IP_TTL = 1`. Layout: 20 bytes IPv4 header, 8 bytes ICMP error header, then the quoted original datagram (20 bytes IPv4 plus the first 8 bytes of our echo, whose sequence is 4243, `0x1093`).

```bash
printf '45c05c003c290000400126140a5d00010a5d02d60b00f4ff0000000045005400e57c00000101c4f80a5d02d60101010108000f790000109308090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f' \
  | xxd -r -p > Tests/WiFiProbeKitTests/Fixtures/icmp-time-exceeded.bin
test $(wc -c < Tests/WiFiProbeKitTests/Fixtures/icmp-time-exceeded.bin) -eq 112 && echo OK
```

Expected: `OK`

- [ ] **Step 2: Write the failing tests**

Append to `Tests/WiFiProbeKitTests/ICMPTests.swift`:

```swift
/// A router that will not answer a ping addressed to itself still has to
/// report an expired TTL. The sequence is recovered from the copy of our
/// own packet quoted inside the error, which is what ties the reply to
/// the request it answers.
func testParsesTimeExceededAndRecoversTheQuotedSequence() throws {
    let data = try fixture("icmp-time-exceeded.bin")
    let parsed = try XCTUnwrap(ICMPPinger.parseReply([UInt8](data), count: data.count))
    XCTAssertEqual(parsed.type, 11)
    XCTAssertEqual(parsed.sequence, 4243)
}

/// A time-exceeded quoting somebody else's traffic is not ours to count.
func testIgnoresTimeExceededQuotingANonEchoDatagram() throws {
    var bytes = [UInt8](try fixture("icmp-time-exceeded.bin"))
    bytes[48] = 17                                   // quoted protocol is not an echo
    XCTAssertNil(ICMPPinger.parseReply(bytes, count: bytes.count))
}

func testRejectsTimeExceededTruncatedBeforeTheQuotedHeader() throws {
    let bytes = [UInt8](try fixture("icmp-time-exceeded.bin"))
    XCTAssertNil(ICMPPinger.parseReply(bytes, count: 40))
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ICMPTests`
Expected: FAIL, `XCTUnwrap` finds nil because `parseReply` returns nil for type 11.

- [ ] **Step 4: Extend the parser**

In `ICMPPinger`, add the constant beside `echoReply`:

```swift
    private static let timeExceeded: UInt8 = 11
```

Replace the tail of `parseReply` (everything from `let type = buffer[ipHeader]`) with:

```swift
        let type = buffer[ipHeader]
        switch type {
        case echoReply:
            let sequence = UInt16(buffer[ipHeader + 6]) << 8 | UInt16(buffer[ipHeader + 7])
            return ParsedICMP(type: type, sequence: sequence)

        case timeExceeded:
            // The error body is 8 bytes, then a copy of the datagram that
            // expired: its own IPv4 header, then the first 8 bytes of our
            // echo. The sequence lives in that copy.
            let quoted = ipHeader + 8
            guard count >= quoted + 20, buffer[quoted] >> 4 == 4 else { return nil }
            let quotedHeader = Int(buffer[quoted] & 0x0F) * 4
            let inner = quoted + quotedHeader
            guard quotedHeader >= 20, count >= inner + 8,
                  buffer[inner] == echoRequest else { return nil }
            let sequence = UInt16(buffer[inner + 6]) << 8 | UInt16(buffer[inner + 7])
            return ParsedICMP(type: type, sequence: sequence)

        default:
            return nil
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ICMPTests`
Expected: PASS

- [ ] **Step 6: Add TTL support to the sender**

Change the two signatures in `ICMPPinger` to carry a TTL, defaulting to the kernel's own:

```swift
    public static func ping(host: String,
                            count: Int = 10,
                            interval: TimeInterval = 0.2,
                            graceSeconds: TimeInterval = 2.0,
                            ttl: Int32? = nil) async throws -> PingStats.Summary {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try pingSync(
                        host: host, count: count, interval: interval,
                        grace: graceSeconds, ttl: ttl))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func pingSync(host: String, count: Int, interval: TimeInterval,
                         grace: TimeInterval, ttl: Int32? = nil) throws -> PingStats.Summary {
```

Immediately after the `SO_RCVTIMEO` `setsockopt` call in `pingSync`, add:

```swift
        // Rung 2 of the gateway ladder: an echo sent with TTL 1 expires at
        // the first router, which is obliged to answer with time exceeded
        // even when it ignores pings addressed to itself.
        if var hops = ttl {
            setsockopt(handle, IPPROTO_IP, IP_TTL, &hops,
                       socklen_t(MemoryLayout<Int32>.size))
        }
```

- [ ] **Step 7: Add the first-hop entry point**

Add to `ICMPPinger`:

```swift
    /// Time the first router by expiring a TTL at it, rather than by
    /// asking it to answer for itself.
    ///
    /// The destination is somewhere beyond the router and is never
    /// reached; only the router's error reply is timed. `mtr` measures
    /// hop 1 the same way on the Pi, so both probes end up measuring the
    /// WiFi link by one method.
    public static func firstHop(via host: String = "1.1.1.1",
                                count: Int = 10,
                                interval: TimeInterval = 0.2) async throws -> PingStats.Summary {
        try await ping(host: host, count: count, interval: interval, ttl: 1)
    }
```

- [ ] **Step 8: Run the whole suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/WiFiProbeKit/Net/ICMPPinger.swift \
        Tests/WiFiProbeKitTests/ICMPTests.swift \
        Tests/WiFiProbeKitTests/Fixtures/icmp-time-exceeded.bin
git commit -m "Mobile: time the first hop with an expiring TTL

Accepts ICMP time exceeded and recovers the sequence from the quoted
original datagram, so a router that ignores pings addressed to itself
can still be timed. Same method mtr uses for hop 1 on the Pi."
```

---

### Task 3: The three-rung gateway ladder

**Files:**
- Modify: `Sources/WiFiProbeKit/Net/GatewayProbe.swift`
- Modify: `Sources/WiFiProbeKit/Net/RouteTable.swift` (add `GatewayCache.flush()`)
- Modify: `Sources/WiFiProbeKit/Workloads/BaselineWorkload.swift`
- Modify: `Sources/WiFiProbeKit/RunCoordinator.swift`
- Test: `Tests/WiFiProbeKitTests/GatewayProbeTests.swift`

**Interfaces:**
- Consumes: `ICMPPinger.ping(host:count:interval:graceSeconds:ttl:)` and `ICMPPinger.firstHop(via:count:interval:)` from Task 2.
- Produces:
  - `GatewayProbe.Method` gains case `firstHopTTL`; existing cases `icmp`, `tcp`, `none` are unchanged.
  - `GatewayProbe.Attempt` struct: `let method: Method`, `let answered: Bool`, `let detail: String`.
  - `GatewayProbe.Result` gains `let attempts: [Attempt]`.
  - `GatewayProbe.Probes` struct of four closures with a `.live` default, so the ladder is testable with no network.
  - `GatewayProbe.measure(host:count:interval:probes:) async -> Result`.
  - `GatewayCache.flush()`.
  - `BaselineWorkload.runGateway(host:count:interval:) async -> (metrics: [String: MetricValue], result: GatewayProbe.Result)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/WiFiProbeKitTests/GatewayProbeTests.swift`:

```swift
// MARK: the ladder, with no network

private extension GatewayProbe.Probes {
    /// Every rung silent unless a test replaces one.
    static func silent() -> GatewayProbe.Probes {
        GatewayProbe.Probes(
            echo: { _, count, _ in PingStats.summarise(rtts: [], sent: count) },
            firstHopTTL: { _, count, _ in PingStats.summarise(rtts: [], sent: count) },
            tcpPort: { _ in nil },
            tcp: { _, _, count, _ in PingStats.summarise(rtts: [], sent: count) })
    }
}

func testEchoWinsWhenTheRouterAnswersIt() async {
    var probes = GatewayProbe.Probes.silent()
    probes.echo = { _, count, _ in PingStats.summarise(rtts: [3.2, 3.4, 3.1], sent: count) }
    let result = await GatewayProbe.measure(host: "10.0.0.1", count: 3,
                                            interval: 0, probes: probes)
    XCTAssertEqual(result.method, .icmp)
    XCTAssertEqual(result.attempts.count, 1, "later rungs must not run once one answers")
}

func testFallsThroughToTTLWhenEchoIsIgnored() async {
    var probes = GatewayProbe.Probes.silent()
    probes.firstHopTTL = { _, count, _ in PingStats.summarise(rtts: [4.0, 4.2], sent: count) }
    let result = await GatewayProbe.measure(host: "10.0.0.1", count: 2,
                                            interval: 0, probes: probes)
    XCTAssertEqual(result.method, .firstHopTTL)
    XCTAssertEqual(result.attempts.map(\.method), [.icmp, .firstHopTTL])
}

func testFallsThroughToTCPWhenNeitherICMPRungAnswers() async {
    var probes = GatewayProbe.Probes.silent()
    probes.tcpPort = { _ in 80 }
    probes.tcp = { _, _, count, _ in PingStats.summarise(rtts: [6.1], sent: count) }
    let result = await GatewayProbe.measure(host: "10.0.0.1", count: 1,
                                            interval: 0, probes: probes)
    XCTAssertEqual(result.method, .tcp)
    XCTAssertEqual(result.port, 80)
    XCTAssertEqual(result.attempts.map(\.method), [.icmp, .firstHopTTL, .tcp])
}

/// Total silence has to stay distinguishable from a measurement, and the
/// app has to be able to say what it tried rather than offer the user a
/// choice of two explanations.
func testTotalSilenceRecordsEveryRungItTried() async {
    let result = await GatewayProbe.measure(host: "10.0.0.1", count: 4,
                                            interval: 0, probes: .silent())
    XCTAssertEqual(result.method, GatewayProbe.Method.none)
    XCTAssertEqual(result.summary.lossPct, 100)
    XCTAssertEqual(result.attempts.count, 3)
    XCTAssertTrue(result.attempts.allSatisfy { !$0.answered })
}

/// A rung that throws is a rung that did not answer, not a crash.
func testAThrowingRungIsTreatedAsSilence() async {
    struct Boom: Error {}
    var probes = GatewayProbe.Probes.silent()
    probes.echo = { _, _, _ in throw Boom() }
    probes.firstHopTTL = { _, count, _ in PingStats.summarise(rtts: [5.0], sent: count) }
    let result = await GatewayProbe.measure(host: "10.0.0.1", count: 1,
                                            interval: 0, probes: probes)
    XCTAssertEqual(result.method, .firstHopTTL)
    XCTAssertFalse(result.attempts[0].answered)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter GatewayProbeTests`
Expected: FAIL, "type 'GatewayProbe' has no member 'Probes'"

- [ ] **Step 3: Rewrite GatewayProbe**

Replace the whole of `Sources/WiFiProbeKit/Net/GatewayProbe.swift`:

```swift
import Foundation

/// Measures the WiFi link by whatever means the router will answer to.
///
/// The first hop is the one destination the phone cannot choose, so it
/// has to work with whatever that router permits. Three rungs are tried
/// in order and the first that answers wins:
///
/// 1. **ICMP echo.** The normal case.
/// 2. **An expiring TTL.** A router that drops packets addressed to
///    itself must still report an expired TTL, and the source of that
///    error is the router. This is how `mtr` measures hop 1 on the Pi.
/// 3. **TCP connect or refusal.** An RST is generated by the host's own
///    stack, so the time to receive one is a round trip even when no port
///    is open. The router does not have to offer a service, only to say
///    no.
///
/// Every rung tried is recorded, answered or not, so the app can report
/// what it did rather than offering the user a choice of explanations.
///
/// A note on history: this ladder was built after the app reported "your
/// router did not answer" on every network, which was attributed to
/// campus client isolation. The real cause was a parsing bug in
/// `ICMPPinger`, and rung 1 works. The other two rungs are kept because
/// routers that answer nothing do exist, and because rung 2 is the method
/// the Pi already uses.
public enum GatewayProbe {

    /// Ports worth asking. Most gateways answer something on at least one,
    /// whether with a handshake or a refusal.
    public static let candidatePorts: [UInt16] = [80, 443, 53, 8080]

    public enum Method: String, Sendable, Equatable {
        case icmp         // the router answered echo requests
        case firstHopTTL  // it ignored echo but reported an expired TTL
        case tcp          // it answered TCP, possibly with a refusal
        case none         // it answered nothing at all
    }

    /// One rung, and what came of it.
    public struct Attempt: Sendable, Equatable {
        public let method: Method
        public let answered: Bool
        public let detail: String
    }

    public struct Result: Sendable, Equatable {
        public let summary: PingStats.Summary
        public let method: Method
        public let port: UInt16?
        public let attempts: [Attempt]
    }

    /// The four network operations the ladder needs, injectable so the
    /// order of the rungs can be tested without a router.
    public struct Probes: Sendable {
        public var echo: @Sendable (String, Int, TimeInterval) async throws -> PingStats.Summary
        public var firstHopTTL: @Sendable (String, Int, TimeInterval) async throws -> PingStats.Summary
        public var tcpPort: @Sendable (String) async -> UInt16?
        public var tcp: @Sendable (String, UInt16, Int, TimeInterval) async -> PingStats.Summary

        public init(
            echo: @escaping @Sendable (String, Int, TimeInterval) async throws -> PingStats.Summary,
            firstHopTTL: @escaping @Sendable (String, Int, TimeInterval) async throws -> PingStats.Summary,
            tcpPort: @escaping @Sendable (String) async -> UInt16?,
            tcp: @escaping @Sendable (String, UInt16, Int, TimeInterval) async -> PingStats.Summary
        ) {
            self.echo = echo
            self.firstHopTTL = firstHopTTL
            self.tcpPort = tcpPort
            self.tcp = tcp
        }

        public static let live = Probes(
            echo: { host, count, interval in
                try await ICMPPinger.ping(host: host, count: count, interval: interval)
            },
            firstHopTTL: { _, count, interval in
                try await ICMPPinger.firstHop(count: count, interval: interval)
            },
            tcpPort: { host in await respondingPort(host: host) },
            tcp: { host, port, count, interval in
                await tcpPing(host: host, port: port, count: count, interval: interval)
            })
    }

    public static func measure(host: String,
                               count: Int = 10,
                               interval: TimeInterval = 0.2,
                               probes: Probes = .live) async -> Result {
        var attempts: [Attempt] = []

        // Rung 1 and rung 2 are both ICMP and share their shape.
        for (method, probe) in [(Method.icmp, probes.echo),
                                (Method.firstHopTTL, probes.firstHopTTL)] {
            do {
                let summary = try await probe(host, count, interval)
                if summary.lossPct < 100 {
                    attempts.append(Attempt(method: method, answered: true,
                                            detail: "\(summary.rttMs) ms"))
                    return Result(summary: summary, method: method, port: nil,
                                  attempts: attempts)
                }
                attempts.append(Attempt(method: method, answered: false,
                                        detail: "no reply"))
            } catch {
                attempts.append(Attempt(method: method, answered: false,
                                        detail: String(describing: error)))
            }
        }

        // Rung 3.
        guard let port = await probes.tcpPort(host) else {
            attempts.append(Attempt(method: .tcp, answered: false,
                                    detail: "no candidate port answered"))
            return Result(summary: PingStats.summarise(rtts: [], sent: count),
                          method: .none, port: nil, attempts: attempts)
        }
        let summary = await probes.tcp(host, port, count, interval)
        let answered = summary.lossPct < 100
        attempts.append(Attempt(method: .tcp, answered: answered,
                                detail: answered ? "port \(port), \(summary.rttMs) ms"
                                                 : "port \(port) stopped answering"))
        return Result(summary: summary, method: answered ? .tcp : .none,
                      port: port, attempts: attempts)
    }

    /// Repeated TCP round trips to a port already known to answer.
    static func tcpPing(host: String, port: UInt16, count: Int,
                        interval: TimeInterval) async -> PingStats.Summary {
        let trustRefusals = LocalSubnet.isOnLink(host)
        var rtts: [Double] = []
        for index in 0..<count {
            switch await TCPProbe.probe(host: host, port: port) {
            case .connected(let rtt): rtts.append(rtt)
            case .refused(let rtt) where trustRefusals: rtts.append(rtt)
            case .refused, .unreachable: break
            }
            if index < count - 1, interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        return PingStats.summarise(rtts: rtts, sent: count)
    }

    /// The first candidate port that produces any answer, open or shut.
    ///
    /// A refusal counts only from an on-link address. The local stack
    /// refuses connections to unroutable addresses in a few milliseconds
    /// without sending anything, and that must never be mistaken for a
    /// router replying. See `LocalSubnet`.
    static func respondingPort(host: String,
                               ports: [UInt16] = candidatePorts,
                               onLink: ((String) -> Bool) = LocalSubnet.isOnLink)
        async -> UInt16? {
        let trustRefusals = onLink(host)
        for port in ports {
            switch await TCPProbe.probe(host: host, port: port, timeout: 1) {
            case .connected: return port
            case .refused where trustRefusals: return port
            case .refused, .unreachable: continue
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter GatewayProbeTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for the cache flush**

Append to `Tests/WiFiProbeKitTests/RouteTableTests.swift`:

```swift
/// A five-minute cache on a value that changes the moment the phone joins
/// a different network is a bug waiting for a demo, so every run starts
/// by discarding it.
func testFlushDiscardsTheCachedGateway() async throws {
    let cache = GatewayCache()
    _ = try? cache.address()
    await cache.flush()
    let flushed = await cache.isEmpty
    XCTAssertTrue(flushed)
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --filter RouteTableTests`
Expected: FAIL, "value of type 'GatewayCache' has no member 'flush'"

- [ ] **Step 7: Add flush**

In `Sources/WiFiProbeKit/Net/RouteTable.swift`, inside `public actor GatewayCache`, add:

```swift
    /// Discard the cached address. Called at the start of every run,
    /// because the phone may have joined a different network since the
    /// last one.
    public func flush() { cached = nil }

    /// For tests.
    public var isEmpty: Bool { cached == nil }
```

Also change `public actor GatewayCache` to expose a public initialiser if it does not already have one:

```swift
    public init() {}
```

- [ ] **Step 8: Run to verify it passes**

Run: `swift test --filter RouteTableTests`
Expected: PASS

- [ ] **Step 9: Report the method out of the baseline pass**

In `Sources/WiFiProbeKit/Workloads/BaselineWorkload.swift`, add alongside `run`:

```swift
    /// The gateway leg, which needs to report which rung of the ladder
    /// answered as well as the numbers. `run` returns metrics only, and
    /// the method matters to the screen.
    public static func runGateway(host: String,
                                  count: Int = 10,
                                  interval: TimeInterval = 0.2)
        async -> (metrics: [String: MetricValue], result: GatewayProbe.Result) {
        let dns = IPv4Address.resolutionMs(host)
        let result = await GatewayProbe.measure(host: host, count: count, interval: interval)

        var metrics: [String: MetricValue] = ["dns_ms": .number(dns)]
        switch result.method {
        case .tcp: metrics["tcp_mode"] = .number(1)
        // Marks the RTT as a first-hop TTL measurement rather than a ping
        // of the router itself, so the two are not silently mixed.
        case .firstHopTTL: metrics["ttl_mode"] = .number(1)
        case .icmp, .none: break
        }
        metrics["rtt_ms"] = .number(result.summary.rttMs)
        metrics["jitter_ms"] = .number(result.summary.jitterMs)
        metrics["loss_pct"] = .number(result.summary.lossPct)
        return (metrics, result)
    }
```

- [ ] **Step 10: Use it from the coordinator**

In `Sources/WiFiProbeKit/RunCoordinator.swift`:

Add to `RunOutcome`, after `wifiLinkMethod`:

```swift
    /// Every rung of the ladder that was tried, in order, so the screen
    /// can show what happened instead of guessing between two causes.
    public let wifiLinkAttempts: [GatewayProbe.Attempt]
```

In `run(site:progress:)`, add beside the other gateway locals:

```swift
        var gatewayAttempts: [GatewayProbe.Attempt] = []
```

Replace the branch inside the task group that reads

```swift
                    if case .number(let loss)? = metrics["loss_pct"] {
                        if target.endpoint == .local {
```

so that the gateway target is dispatched through `runGateway`. The simplest change that keeps the parallel group intact is to run the gateway separately, before the group. Replace the block that begins `let gateway = await gatewayLookup()` with:

```swift
        await GatewayCache.shared.flush()
        let gateway = await gatewayLookup()

        // The gateway leg runs on its own because it needs the ladder's
        // verdict as well as its numbers, and because it feeds the path
        // record below.
        var gatewayRTT: Double?
        var gatewayMethod: GatewayProbe.Method = .none
        var gatewayAttempts: [GatewayProbe.Attempt] = []
        var gatewaySilent = false
        var offSiteReachable = false

        if let gateway {
            var step = RunStep(workload: .baseline, endpoint: .local, target: gateway)
            step.state = .running
            progress(step)
            let (metrics, result) = await BaselineWorkload.runGateway(
                host: gateway, count: config.pingCount, interval: config.pingInterval)
            gatewayMethod = result.method
            gatewayAttempts = result.attempts
            if result.summary.lossPct >= 100 {
                gatewaySilent = true
            } else {
                gatewayRTT = result.summary.rttMs
            }
            await emit(step, metrics, nil)
        }

        let baselineTargets = Endpoints.baselineTargets(config: config, gateway: nil)
```

Then inside the task group's success branch, delete the `if target.endpoint == .local { ... } else` wrapper and keep only:

```swift
                case .success(let metrics):
                    if case .number(let loss)? = metrics["loss_pct"], loss < 100 {
                        offSiteReachable = true
                    }
                    await emit(step, metrics, nil)
                case .failure(let error):
                    await emit(step, nil, error)
```

Finally add `wifiLinkAttempts: gatewayAttempts,` to the `RunOutcome` constructed at the end.

- [ ] **Step 11: Update the coordinator tests for the new shape**

In `Tests/WiFiProbeKitTests/RunCoordinatorTests.swift`, the baseline target list no longer includes the gateway (it is run separately). Update `testBaselineCoversEveryDestinationClass` so its expectation is the off-site classes only, and add:

```swift
/// The gateway is measured once, and the path record reuses that number
/// rather than pinging the router a second time.
func testGatewayIsMeasuredOnceAndReusedByThePathRecord() async throws {
    // Reuses this file's existing pattern for driving a run with injected
    // runners, so no network is touched. `records` is whatever the file's
    // other tests already read the posted JSON objects out of.
    let gatewayBaselines = records.filter {
        $0["workload"] as? String == "baseline" && $0["endpoint"] as? String == "local"
    }
    XCTAssertEqual(gatewayBaselines.count, 1)
}
```

Copy the arrange half of the nearest existing test in that file verbatim (the one that builds a `RunCoordinator` with stub `runner` and `baselineRunner` closures and awaits `run(site:progress:)`), then apply the assertion above. Do not invent a new helper.

Note that after Task 3 the gateway is no longer produced by `baselineRunner`, so a stub `gatewayLookup` returning a host now drives a real `BaselineWorkload.runGateway` call. Pass `gatewayLookup: { nil }` in every existing test that does not care about the gateway, so no test reaches the network.

- [ ] **Step 12: Correct the false record in the comments**

The header comment on `GatewayProbe.swift` is replaced in Step 3 above; confirm no other file still claims the campus router ignores ICMP:

```bash
grep -rn "ignores ICMP\|client isolation\|ICMP is filtered" ../ --include=*.swift --include=*.md
```

Correct any hit to say that the cause was the reply parser, citing this plan's Task 1. `CONSTRAINTS.md`, `README.md` and `NEXT.md` are the likely places.

- [ ] **Step 13: Run the whole suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 14: Commit**

```bash
git add -A Sources Tests ..
git commit -m "Mobile: three-rung ladder for the WiFi link

Echo, then an expiring TTL, then TCP, stopping at the first that
answers, with every rung recorded so the app can say what it tried.
Flushes the gateway cache at the start of each run, since the phone
may have changed network since the last one."
```

---

### Task 4: Runs persist to disk

**Files:**
- Create: `Sources/WiFiProbeKit/Store/StoredRun.swift`
- Create: `Sources/WiFiProbeKit/Store/RunStore.swift`
- Test: `Tests/WiFiProbeKitTests/RunStoreTests.swift`

**Interfaces:**
- Consumes: `RunOutcome` and `RunStep` from `RunCoordinator`, `Verdict` from `SummaryClient`, `GatewayProbe.Method` and `GatewayProbe.Attempt` from Task 3.
- Produces:
  - `StoredRun`, `Codable` and `Sendable`, with `let id: String` (the run id), `let site: String`, `let startedAt: Date`, `let finishedAt: Date`, `let recordCount: Int`, `let failedCount: Int`, `let gateway: String?`, `let wifiLinkMethod: String`, `let wifiLinkAttempts: [StoredRun.Attempt]`, `let steps: [StoredRun.Step]`, `let verdict: StoredRun.VerdictSnapshot?`.
  - `StoredRun.Step`: `let workload: String`, `let endpoint: String`, `let target: String`, `let ok: Bool`, `let error: String?`.
  - `StoredRun.Attempt`: `let method: String`, `let answered: Bool`, `let detail: String`.
  - `StoredRun.VerdictSnapshot`: `let score: Double?`, `let quality: Double?`, `let availabilityPct: Double?`, `let label: String?`, `let headline: String?`, `let segments: [String: String]`, `let wifiLinkRTTms: Double?`.
  - `actor RunStore` with `init(directory: URL)`, `static func defaultDirectory() throws -> URL`, `func save(_ run: StoredRun) throws`, `func all() -> [StoredRun]`, `func runs(site: String) -> [StoredRun]`, `func sites() -> [String]`, `func delete(id: String) throws`, `func deleteAll() throws`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/WiFiProbeKitTests/RunStoreTests.swift`:

```swift
import XCTest
@testable import WiFiProbeKit

final class RunStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runstore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(id: String, site: String, at: Date,
                     score: Double? = 91) -> StoredRun {
        StoredRun(
            id: id, site: site, startedAt: at, finishedAt: at.addingTimeInterval(60),
            recordCount: 11, failedCount: 0, gateway: "10.0.0.1",
            wifiLinkMethod: "icmp",
            wifiLinkAttempts: [StoredRun.Attempt(method: "icmp", answered: true,
                                                 detail: "3.2 ms")],
            steps: [StoredRun.Step(workload: "web", endpoint: "real",
                                   target: "https://bbc.co.uk", ok: true, error: nil)],
            verdict: StoredRun.VerdictSnapshot(
                score: score, quality: score, availabilityPct: 100, label: "excellent",
                headline: "Your WiFi is doing fine",
                segments: ["wifi_link": "ok"], wifiLinkRTTms: 3.2))
    }

    func testSavesAndReadsBackARun() async throws {
        let store = RunStore(directory: directory)
        try await store.save(run(id: "a", site: "phone-home", at: Date()))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.verdict?.score, 91)
        XCTAssertEqual(all.first?.steps.first?.workload, "web")
    }

    /// Newest first, because that is the order History shows.
    func testOrdersNewestFirst() async throws {
        let store = RunStore(directory: directory)
        let now = Date()
        try await store.save(run(id: "old", site: "phone-home",
                                 at: now.addingTimeInterval(-3600)))
        try await store.save(run(id: "new", site: "phone-home", at: now))
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), ["new", "old"])
    }

    func testFiltersBySiteAndListsSites() async throws {
        let store = RunStore(directory: directory)
        let now = Date()
        try await store.save(run(id: "a", site: "phone-home", at: now))
        try await store.save(run(id: "b", site: "phone-library",
                                 at: now.addingTimeInterval(-10)))
        let home = await store.runs(site: "phone-home")
        XCTAssertEqual(home.map(\.id), ["a"])
        let sites = await store.sites()
        XCTAssertEqual(Set(sites), ["phone-home", "phone-library"])
    }

    /// A run written by an older build, or half-written when the app was
    /// killed, must not take the whole history down with it.
    func testSkipsAnUnreadableRunFile() async throws {
        let store = RunStore(directory: directory)
        try await store.save(run(id: "good", site: "phone-home", at: Date()))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), ["good"])
    }

    func testDeletesOneRunAndThenAll() async throws {
        let store = RunStore(directory: directory)
        try await store.save(run(id: "a", site: "phone-home", at: Date()))
        try await store.save(run(id: "b", site: "phone-home", at: Date()))
        try await store.delete(id: "a")
        var all = await store.all()
        XCTAssertEqual(all.map(\.id), ["b"])
        try await store.deleteAll()
        all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    /// Runs survive the process, which is the whole point.
    func testASecondStoreOverTheSameDirectorySeesTheRuns() async throws {
        try await RunStore(directory: directory)
            .save(run(id: "a", site: "phone-home", at: Date()))
        let reopened = await RunStore(directory: directory).all()
        XCTAssertEqual(reopened.map(\.id), ["a"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RunStoreTests`
Expected: FAIL, "cannot find 'StoredRun' in scope"

- [ ] **Step 3: Implement StoredRun**

Create `Sources/WiFiProbeKit/Store/StoredRun.swift`:

```swift
import Foundation

/// One finished run, as it was displayed, kept on the device.
///
/// The verdict is a snapshot rather than something refetched later. A run
/// reopened in December has to show what it showed in August, and `?at=`
/// on the backend is not a substitute: the local record is the point.
///
/// Everything is a plain `String` rather than the kit's enums so that a
/// build which adds a workload can still read runs written by an older
/// one. A history that cannot be decoded is worse than a history with an
/// unfamiliar label in it.
public struct StoredRun: Codable, Sendable, Identifiable, Equatable {

    public struct Step: Codable, Sendable, Equatable {
        public let workload: String
        public let endpoint: String
        public let target: String
        public let ok: Bool
        public let error: String?

        public init(workload: String, endpoint: String, target: String,
                    ok: Bool, error: String?) {
            self.workload = workload
            self.endpoint = endpoint
            self.target = target
            self.ok = ok
            self.error = error
        }
    }

    public struct Attempt: Codable, Sendable, Equatable {
        public let method: String
        public let answered: Bool
        public let detail: String

        public init(method: String, answered: Bool, detail: String) {
            self.method = method
            self.answered = answered
            self.detail = detail
        }
    }

    public struct VerdictSnapshot: Codable, Sendable, Equatable {
        public let score: Double?
        public let quality: Double?
        public let availabilityPct: Double?
        public let label: String?
        public let headline: String?
        public let segments: [String: String]
        public let wifiLinkRTTms: Double?

        public init(score: Double?, quality: Double?, availabilityPct: Double?,
                    label: String?, headline: String?, segments: [String: String],
                    wifiLinkRTTms: Double?) {
            self.score = score
            self.quality = quality
            self.availabilityPct = availabilityPct
            self.label = label
            self.headline = headline
            self.segments = segments
            self.wifiLinkRTTms = wifiLinkRTTms
        }
    }

    public let id: String
    public let site: String
    public let startedAt: Date
    public let finishedAt: Date
    public let recordCount: Int
    public let failedCount: Int
    public let gateway: String?
    public let wifiLinkMethod: String
    public let wifiLinkAttempts: [Attempt]
    public let steps: [Step]
    public let verdict: VerdictSnapshot?

    public init(id: String, site: String, startedAt: Date, finishedAt: Date,
                recordCount: Int, failedCount: Int, gateway: String?,
                wifiLinkMethod: String, wifiLinkAttempts: [Attempt],
                steps: [Step], verdict: VerdictSnapshot?) {
        self.id = id
        self.site = site
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.recordCount = recordCount
        self.failedCount = failedCount
        self.gateway = gateway
        self.wifiLinkMethod = wifiLinkMethod
        self.wifiLinkAttempts = wifiLinkAttempts
        self.steps = steps
        self.verdict = verdict
    }

    /// The site label without the `phone-` prefix, which is the name the
    /// fixed probe would use for the same network. Trends uses it to look
    /// for a Pi at the same site.
    public var fixedProbeSite: String {
        site.hasPrefix(SiteLabel.prefix)
            ? String(site.dropFirst(SiteLabel.prefix.count)) : site
    }
}
```

- [ ] **Step 4: Implement RunStore**

Create `Sources/WiFiProbeKit/Store/RunStore.swift`:

```swift
import Foundation

/// Finished runs on disk, one JSON file each.
///
/// One file per run rather than one file holding all of them: a run is
/// written once and never edited, a partial write can only damage the run
/// being written, and a file that will not decode is skipped rather than
/// taking the history with it. A few hundred small records do not need
/// SQLite, and a plain file store is testable against a temporary
/// directory with no simulator.
public actor RunStore {

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Application Support, which is backed up and not purged under disk
    /// pressure the way Caches is.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("runs", isDirectory: true)
    }

    public func save(_ run: StoredRun) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(run.id).json")
        try encoder.encode(run).write(to: url, options: .atomic)
    }

    /// Newest first, which is the order History shows and the order the
    /// charts want.
    public func all() -> [StoredRun] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StoredRun.self, from: data)
            }
            .sorted { $0.finishedAt > $1.finishedAt }
    }

    public func runs(site: String) -> [StoredRun] {
        all().filter { $0.site == site }
    }

    /// Sites in order of most recent use, so a picker offers the network
    /// you are most likely on.
    public func sites() -> [String] {
        var seen: [String] = []
        for run in all() where !seen.contains(run.site) { seen.append(run.site) }
        return seen
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).json"))
    }

    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter RunStoreTests`
Expected: PASS

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test`
Expected: PASS

```bash
git add Sources/WiFiProbeKit/Store Tests/WiFiProbeKitTests/RunStoreTests.swift
git commit -m "Mobile: keep finished runs on the device

One JSON file per run in Application Support, read through an actor.
The verdict is snapshotted as displayed rather than refetched, so a
run reopened later shows what it showed at the time."
```

---

### Task 5: Queued uploads survive the app being killed

Stretch item MS1, arriving because the disk store now exists. It is what makes the interruption test a test of durability rather than of in-memory state.

**Files:**
- Modify: `Sources/WiFiProbeKit/PendingStore.swift`
- Test: `Tests/WiFiProbeKitTests/UploadTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PendingStore.init(directory: URL?)`, defaulting to `nil` for the in-memory behaviour the existing tests use. Existing methods `add`, `take`, `acknowledge`, `reject`, `pendingCount`, `rejectedCount` keep their signatures.

- [ ] **Step 1: Write the failing test**

Append to `Tests/WiFiProbeKitTests/UploadTests.swift`:

```swift
/// The upload fails precisely when the network is worst, which is when
/// the measurement matters most. If the app is killed while the queue is
/// full, the queue has to still be there afterwards.
func testQueuedRecordsSurviveANewStoreOverTheSameDirectory() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pending-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = PendingStore(directory: directory)
    await first.add(sampleRecord())
    await first.add(sampleRecord())
    var count = await first.pendingCount
    XCTAssertEqual(count, 2)

    let reopened = PendingStore(directory: directory)
    count = await reopened.pendingCount
    XCTAssertEqual(count, 2, "the queue did not survive")

    let entries = await reopened.take()
    await reopened.acknowledge(entries[0].id)
    let afterAck = PendingStore(directory: directory)
    count = await afterAck.pendingCount
    XCTAssertEqual(count, 1, "an acknowledged record came back")
}

/// Order is preserved across a restart, so a partial upload still leaves
/// a contiguous prefix delivered.
func testQueueOrderSurvivesARestart() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pending-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = PendingStore(directory: directory)
    for _ in 0..<3 { await first.add(sampleRecord()) }
    let before = await first.take().map(\.id)
    let after = await PendingStore(directory: directory).take().map(\.id)
    XCTAssertEqual(before, after)
}
```

If `UploadTests.swift` has no `sampleRecord()` helper, add this one:

```swift
private func sampleRecord() -> Record {
    Record(probeID: "iphone-test", site: "phone-home",
           runID: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
           workload: .baseline, endpoint: .real, target: "1.1.1.1",
           ok: true, error: nil,
           metrics: ["rtt_ms": .number(13.9), "loss_pct": .number(0)],
           netHash: nil)
}
```

If `Record.init` takes a different argument list, match the one the file's existing tests already use rather than changing `Record`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter UploadTests`
Expected: FAIL, "argument 'directory' must precede..." or "extra argument 'directory' in call"

- [ ] **Step 3: Make the store persistent**

Replace `Sources/WiFiProbeKit/PendingStore.swift`:

```swift
import Foundation

/// Records produced but not yet accepted by the backend (M9).
///
/// The upload fails precisely when the network is worst, which is when
/// the measurement matters most, so nothing is discarded on a failed
/// send. Given a directory the queue is mirrored to disk and survives the
/// app being killed mid-run, which is MS1. Given nil it stays in memory,
/// which is what the unit tests want.
public actor PendingStore {
    public struct Entry: Sendable, Codable {
        public let id: UUID
        public let record: Record
    }

    private var entries: [Entry] = []
    /// Records the backend refused outright. A rejection is an app bug
    /// rather than a network condition, so they are kept apart and
    /// surfaced instead of being retried forever.
    private(set) var rejected: [Entry] = []

    private let directory: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            entries = Self.load(from: directory.appendingPathComponent("queue.json"),
                                decoder: decoder)
            rejected = Self.load(from: directory.appendingPathComponent("rejected.json"),
                                 decoder: decoder)
        }
    }

    public func add(_ record: Record) {
        entries.append(Entry(id: UUID(), record: record))
        persist()
    }

    /// Oldest first: order is preserved so a partial upload leaves a
    /// contiguous prefix delivered.
    public func take() -> [Entry] { entries }

    public func acknowledge(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    public func reject(_ id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            rejected.append(entries.remove(at: index))
            persist()
        }
    }

    public var pendingCount: Int { entries.count }
    public var rejectedCount: Int { rejected.count }

    // MARK: disk

    private func persist() {
        guard let directory else { return }
        write(entries, to: directory.appendingPathComponent("queue.json"))
        write(rejected, to: directory.appendingPathComponent("rejected.json"))
    }

    private func write(_ list: [Entry], to url: URL) {
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A queue file that will not decode is dropped rather than crashing
    /// the app on launch. Losing an unsent record is bad; refusing to
    /// start is worse.
    private static func load(from url: URL, decoder: JSONDecoder) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder.decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// Where the app keeps its queue, beside the runs.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("pending", isDirectory: true)
    }
}
```

- [ ] **Step 4: Make Record decodable**

`Record` currently has a custom `encode(to:)` and no `Decodable` conformance, but `Entry` now needs both. In `Sources/WiFiProbeKit/Contract/Record.swift`, change the declaration to `public struct Record: Codable, Sendable, Equatable` and, if the synthesised decoder cannot be produced because of the custom `CodingKeys` or `MetricValue`, add `Decodable` to `MetricValue` as well:

```swift
extension MetricValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) { self = .number(number); return }
        self = .string(try container.decode(String.self))
    }
}
```

Run `swift build` after this step; if the compiler asks for an explicit `init(from:)` on `Record`, write one that mirrors the existing `CodingKeys` exactly, decoding `context` and `raw_ref` as optional.

- [ ] **Step 5: Run to verify the tests pass**

Run: `swift test --filter UploadTests`
Expected: PASS

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test`
Expected: PASS

```bash
git add Sources/WiFiProbeKit/PendingStore.swift \
        Sources/WiFiProbeKit/Contract/Record.swift \
        Tests/WiFiProbeKitTests/UploadTests.swift
git commit -m "Mobile: the upload queue survives a restart

Mirrors the queue to disk when given a directory. Records queued
while the network was gone are still there after the app is killed,
which is what makes the interruption test a test of durability."
```

---

### Task 6: Per-site aggregation for Trends

**Files:**
- Create: `Sources/WiFiProbeKit/Trends.swift`
- Test: `Tests/WiFiProbeKitTests/TrendsTests.swift`

**Interfaces:**
- Consumes: `StoredRun` from Task 4.
- Produces:
  - `Trends.SiteSummary`: `let site: String`, `let runCount: Int`, `let medianScore: Double?`, `let medianDownloadMbps: Double?`, `let medianWiFiLinkMs: Double?`, `let firstRun: Date`, `let lastRun: Date`, `let worstSegment: String?`.
  - `static func rank(_ runs: [StoredRun]) -> [SiteSummary]`, best median score first.
  - `static func median(_ values: [Double]) -> Double?`.
  - `static func series(_ runs: [StoredRun], metric: Trends.Metric) -> [(date: Date, value: Double)]`.
  - `enum Trends.Metric: String, CaseIterable { case score, download, latency }` with `var title: String` and `var unit: String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/WiFiProbeKitTests/TrendsTests.swift`:

```swift
import XCTest
@testable import WiFiProbeKit

final class TrendsTests: XCTestCase {

    private func run(site: String, at: Date, score: Double?,
                     segments: [String: String] = [:],
                     download: Double? = nil,
                     wifiLink: Double? = nil) -> StoredRun {
        var steps: [StoredRun.Step] = []
        if download != nil {
            steps.append(StoredRun.Step(workload: "download", endpoint: "real",
                                        target: "t", ok: true, error: nil))
        }
        return StoredRun(
            id: UUID().uuidString, site: site, startedAt: at,
            finishedAt: at.addingTimeInterval(60), recordCount: 10, failedCount: 0,
            gateway: "10.0.0.1", wifiLinkMethod: "icmp", wifiLinkAttempts: [],
            steps: steps,
            verdict: StoredRun.VerdictSnapshot(
                score: score, quality: score, availabilityPct: 100, label: nil,
                headline: nil, segments: segments, wifiLinkRTTms: wifiLink),
            downloadMbps: download)
    }

    func testMedianOfAnEvenCountAveragesTheMiddleTwo() {
        XCTAssertEqual(Trends.median([1, 2, 3, 4]), 2.5)
    }

    func testMedianOfAnEmptyListIsNil() {
        XCTAssertNil(Trends.median([]))
    }

    /// Medians rather than means, for the reason the backend uses them:
    /// one failed run should not swing a summary.
    func testOneBadRunDoesNotSinkASite() {
        let now = Date()
        let runs = (0..<4).map { run(site: "phone-home", at: now.addingTimeInterval(Double($0)),
                                     score: 90) }
            + [run(site: "phone-home", at: now, score: 2)]
        let ranked = Trends.rank(runs)
        XCTAssertEqual(ranked.first?.medianScore, 90)
    }

    func testRanksBestFirstAndCountsRuns() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 59),
                    run(site: "phone-library", at: now, score: 88),
                    run(site: "phone-library", at: now.addingTimeInterval(-60), score: 88)]
        let ranked = Trends.rank(runs)
        XCTAssertEqual(ranked.map(\.site), ["phone-library", "phone-home"])
        XCTAssertEqual(ranked.first?.runCount, 2)
    }

    /// A site with no scored run at all still appears, last, because
    /// "tested and never got a verdict" is information.
    func testSitesWithoutAScoreSortLast() {
        let now = Date()
        let ranked = Trends.rank([run(site: "phone-a", at: now, score: nil),
                                  run(site: "phone-b", at: now, score: 40)])
        XCTAssertEqual(ranked.map(\.site), ["phone-b", "phone-a"])
    }

    func testNamesTheSegmentMostOftenAtFault() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 50,
                        segments: ["wifi_link": "ok", "internet_path": "suspect"]),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 55,
                        segments: ["wifi_link": "ok", "internet_path": "suspect"]),
                    run(site: "phone-home", at: now.addingTimeInterval(-120), score: 60,
                        segments: ["wifi_link": "suspect", "internet_path": "ok"])]
        XCTAssertEqual(Trends.rank(runs).first?.worstSegment, "internet_path")
    }

    func testWorstSegmentIsNilWhenNothingWasEverAtFault() {
        let ranked = Trends.rank([run(site: "phone-home", at: Date(), score: 95,
                                      segments: ["wifi_link": "ok"])])
        XCTAssertNil(ranked.first?.worstSegment)
    }

    /// Chart points come back oldest first, because that is left to right.
    func testSeriesIsOldestFirst() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 90),
                    run(site: "phone-home", at: now.addingTimeInterval(-3600), score: 40)]
        let points = Trends.series(runs, metric: .score)
        XCTAssertEqual(points.map(\.value), [40, 90])
    }

    func testSeriesSkipsRunsMissingTheMetric() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: nil),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 70)]
        XCTAssertEqual(Trends.series(runs, metric: .score).count, 1)
    }
}
```

- [ ] **Step 2: Add the two fields the tests need to StoredRun**

`Trends` needs a download figure and the tests pass one. Add to `StoredRun`, after `wifiLinkAttempts`:

```swift
    /// Headline numbers, lifted out of the run so a chart does not have to
    /// re-read every record. Nil when that workload did not report.
    public let downloadMbps: Double?
```

Add `downloadMbps: Double?` as the last parameter of `StoredRun.init` (with a `= nil` default so Task 4's tests keep compiling) and assign it. Decoding an older file that lacks the key must not fail: because the property is optional, the synthesised decoder already tolerates it.

- [ ] **Step 3: Run to verify the tests fail**

Run: `swift test --filter TrendsTests`
Expected: FAIL, "cannot find 'Trends' in scope"

- [ ] **Step 4: Implement Trends**

Create `Sources/WiFiProbeKit/Trends.swift`:

```swift
import Foundation

/// What the Trends tab shows, computed over the runs kept on the device.
///
/// Pure functions over `[StoredRun]`, so this is unit-tested directly and
/// the SwiftUI layer above it holds no arithmetic.
///
/// A phone produces one point per tap rather than one every ten seconds,
/// so this deliberately does not try to be Grafana. It answers the
/// question a phone is placed to answer, which is which of the networks
/// you actually visit is any good.
public enum Trends {

    public enum Metric: String, CaseIterable, Sendable {
        case score, download, latency

        public var title: String {
            switch self {
            case .score: return "Score"
            case .download: return "Speed"
            case .latency: return "WiFi link"
            }
        }

        public var unit: String {
            switch self {
            case .score: return ""
            case .download: return "Mbps"
            case .latency: return "ms"
            }
        }

        func value(from run: StoredRun) -> Double? {
            switch self {
            case .score: return run.verdict?.score
            case .download: return run.downloadMbps
            case .latency: return run.verdict?.wifiLinkRTTms
            }
        }
    }

    public struct SiteSummary: Sendable, Equatable, Identifiable {
        public let site: String
        public let runCount: Int
        public let medianScore: Double?
        public let medianDownloadMbps: Double?
        public let medianWiFiLinkMs: Double?
        public let firstRun: Date
        public let lastRun: Date
        /// The segment most often not `ok` across this site's runs, or nil
        /// if nothing was ever at fault.
        public let worstSegment: String?

        public var id: String { site }
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Best median score first. A site with no scored run sorts last,
    /// rather than being dropped: "tested and never got a verdict" is
    /// information about that network.
    public static func rank(_ runs: [StoredRun]) -> [SiteSummary] {
        Dictionary(grouping: runs, by: \.site)
            .map { site, siteRuns in summarise(site: site, runs: siteRuns) }
            .sorted { left, right in
                switch (left.medianScore, right.medianScore) {
                case let (l?, r?): return l == r ? left.site < right.site : l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return left.site < right.site
                }
            }
    }

    static func summarise(site: String, runs: [StoredRun]) -> SiteSummary {
        var faults: [String: Int] = [:]
        for run in runs {
            for (segment, state) in run.verdict?.segments ?? [:] where state != "ok" {
                // no_data is an absent measurement, not a fault.
                if state != "no_data" { faults[segment, default: 0] += 1 }
            }
        }
        let worst = faults.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key

        let dates = runs.map(\.finishedAt)
        return SiteSummary(
            site: site,
            runCount: runs.count,
            medianScore: median(runs.compactMap { $0.verdict?.score }),
            medianDownloadMbps: median(runs.compactMap(\.downloadMbps)),
            medianWiFiLinkMs: median(runs.compactMap { $0.verdict?.wifiLinkRTTms }),
            firstRun: dates.min() ?? .distantPast,
            lastRun: dates.max() ?? .distantPast,
            worstSegment: worst)
    }

    /// Chart points, oldest first, skipping runs that never reported the
    /// metric asked for.
    public static func series(_ runs: [StoredRun],
                              metric: Metric) -> [(date: Date, value: Double)] {
        runs.sorted { $0.finishedAt < $1.finishedAt }
            .compactMap { run in
                metric.value(from: run).map { (date: run.finishedAt, value: $0) }
            }
    }

    /// The sentence under the ranking. Built here rather than in the view
    /// so it is covered by tests.
    public static func insight(for summary: SiteSummary) -> String? {
        guard let segment = summary.worstSegment else { return nil }
        let name: String
        switch segment {
        case "wifi_link": name = "the WiFi link itself"
        case "internet_path": name = "the internet path beyond the router"
        default: name = "the services being reached"
        }
        return "On \(readable(summary.site)), \(name) is what most often falls short."
    }

    /// The label as a person wrote it, without the prefix the app forces
    /// on to keep phone records out of the deployment dataset.
    public static func readable(_ site: String) -> String {
        site.hasPrefix(SiteLabel.prefix)
            ? String(site.dropFirst(SiteLabel.prefix.count)) : site
    }
}
```

- [ ] **Step 5: Add the insight test**

Append to `TrendsTests.swift`:

```swift
func testInsightNamesTheSegmentInPlainEnglish() {
    let now = Date()
    let runs = [run(site: "phone-home", at: now, score: 50,
                    segments: ["internet_path": "suspect"])]
    let summary = Trends.rank(runs)[0]
    XCTAssertEqual(Trends.insight(for: summary),
                   "On home, the internet path beyond the router is what most often falls short.")
}

func testInsightIsAbsentWhenNothingIsAtFault() {
    let summary = Trends.rank([run(site: "phone-home", at: Date(), score: 95)])[0]
    XCTAssertNil(Trends.insight(for: summary))
}
```

- [ ] **Step 6: Run to verify they pass**

Run: `swift test --filter TrendsTests`
Expected: PASS

- [ ] **Step 7: Run the whole suite and commit**

Run: `swift test`
Expected: PASS

```bash
git add Sources/WiFiProbeKit/Trends.swift \
        Sources/WiFiProbeKit/Store/StoredRun.swift \
        Tests/WiFiProbeKitTests/TrendsTests.swift
git commit -m "Mobile: rank the networks a phone has visited

Medians per site, best first, with the segment most often at fault.
Plays to what a phone has that a fixed probe does not, which is
breadth: it visits places a device left plugged in never will."
```

---

### Task 7: The app records what it ran

Wires the kit's new storage into the app, with no new screens yet. Ends with the existing single screen still working and every run being saved.

**Files:**
- Create: `WiFiProbe/AppStores.swift`
- Modify: `WiFiProbe/RunViewModel.swift`
- Test: manual, on device or simulator

**Interfaces:**
- Consumes: `RunStore`, `StoredRun`, `PendingStore(directory:)`, `RunOutcome.wifiLinkAttempts`.
- Produces:
  - `enum AppStores` with `static let runs: RunStore` and `static let pending: PendingStore`.
  - `RunViewModel.stageText: String` (the one plain line shown while running).
  - `RunViewModel.progressFraction: Double` (0 to 1).
  - `RunViewModel.savedRun: StoredRun?` (the run just written).
  - `RunOutcome.downloadMbps: Double?`.
  - `StoredRun.from(outcome:steps:verdict:)` static factory in the kit.

- [ ] **Step 1: Carry the download figure out of the run**

The Trends chart needs a speed number and the verdict does not carry one, so the run reports its own.

In `Sources/WiFiProbeKit/RunCoordinator.swift`, add to `RunOutcome`:

```swift
    /// The throughput this run measured, for the on-device chart. The
    /// verdict does not carry it, so it comes from the run's own record.
    public let downloadMbps: Double?
```

Declare `var downloadMbps: Double?` beside `gatewayRTT` in `run(site:progress:)`, and in the application-workload loop, immediately after a successful `runner(...)` call, add:

```swift
                    if workload == .download,
                       case .number(let mbps)? = metrics["throughput_mbps"] {
                        downloadMbps = mbps
                    }
```

Add `downloadMbps: downloadMbps,` to the `RunOutcome` constructed at the end of the function, and to its initialiser if it has an explicit one.

- [ ] **Step 2: Add the factory to the kit**

In `Sources/WiFiProbeKit/Store/StoredRun.swift`, add:

```swift
public extension StoredRun {
    /// Build the on-disk record from what a finished run produced.
    static func from(outcome: RunOutcome,
                     steps: [RunStep],
                     verdict: Verdict?) -> StoredRun {
        StoredRun(
            id: outcome.runID,
            site: outcome.site,
            startedAt: outcome.startedAt,
            finishedAt: outcome.finishedAt,
            recordCount: outcome.recordCount,
            failedCount: outcome.failedCount,
            gateway: outcome.gateway,
            wifiLinkMethod: outcome.wifiLinkMethod.rawValue,
            wifiLinkAttempts: outcome.wifiLinkAttempts.map {
                Attempt(method: $0.method.rawValue, answered: $0.answered, detail: $0.detail)
            },
            steps: steps.map { step in
                var failure: String?
                var ok = true
                if case .failed(let reason) = step.state { failure = reason; ok = false }
                return Step(workload: step.workload.rawValue,
                            endpoint: step.endpoint.rawValue,
                            target: step.target, ok: ok, error: failure)
            },
            verdict: verdict.map { verdict in
                VerdictSnapshot(
                    score: verdict.health?.score,
                    quality: verdict.health?.quality,
                    availabilityPct: verdict.health?.availability?.pct,
                    label: verdict.health?.label,
                    headline: verdict.headline,
                    segments: verdict.segments ?? [:],
                    wifiLinkRTTms: verdict.wifiLinkRTTms)
            },
            downloadMbps: outcome.downloadMbps)
    }
}
```

- [ ] **Step 3: Write the failing test for the factory**

Append to `Tests/WiFiProbeKitTests/RunStoreTests.swift`:

```swift
/// A failed step has to survive into the stored run: the whole point of
/// History is being able to look at what went wrong afterwards.
func testFactoryCarriesFailedStepsAndTheirReasons() {
    var step = RunStep(workload: .web, endpoint: .real, target: "https://bbc.co.uk")
    step.state = .failed("timed out")
    let outcome = RunOutcome(
        runID: "r1", site: "phone-home", startedAt: Date(), finishedAt: Date(),
        recordCount: 1, failedCount: 1, gateway: "10.0.0.1",
        wifiLinkMethod: .icmp,
        wifiLinkAttempts: [GatewayProbe.Attempt(method: .icmp, answered: true,
                                                detail: "3.2 ms")],
        gatewaySilentButInternetWorks: false,
        downloadMbps: 55.4)
    let stored = StoredRun.from(outcome: outcome, steps: [step], verdict: nil)
    XCTAssertEqual(stored.steps.count, 1)
    XCTAssertFalse(stored.steps[0].ok)
    XCTAssertEqual(stored.steps[0].error, "timed out")
    XCTAssertEqual(stored.wifiLinkMethod, "icmp")
    XCTAssertEqual(stored.downloadMbps, 55.4)
}
```

If `RunStep.init` and `RunOutcome.init` are internal, mark them `public` in `RunCoordinator.swift`. `RunStep.state` also needs to be settable from the test, so make it `public var`.

- [ ] **Step 4: Run the test**

Run: `swift test --filter RunStoreTests`
Expected: PASS. Write the test before the factory if you want to see it fail first; the ordering above puts the code first only because the factory's signature is what the test has to match.

- [ ] **Step 5: Create the shared stores**

Create `WiFiProbe/AppStores.swift`:

```swift
import Foundation
import WiFiProbeKit

/// The two on-disk stores, shared by every screen.
///
/// Created once rather than per view: two `RunStore` actors over the same
/// directory would not corrupt anything, since a run is written once and
/// never edited, but they would disagree about what is there until both
/// re-read it.
enum AppStores {
    static let runs: RunStore = {
        let directory = (try? RunStore.defaultDirectory())
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runs")
        return RunStore(directory: directory)
    }()

    static let pending: PendingStore = {
        PendingStore(directory: try? PendingStore.defaultDirectory())
    }()
}
```

- [ ] **Step 6: Save the run and expose progress**

In `WiFiProbe/RunViewModel.swift`:

Replace `private let store = PendingStore()` with:

```swift
    private let store = AppStores.pending
    private(set) var savedRun: StoredRun?
```

Add, next to the other observable properties:

```swift
    /// The one plain line shown while a run is in progress, instead of
    /// eleven rows naming workloads and endpoints.
    private(set) var stageText = ""
    /// How far through, for the ring. Eleven steps is the usual count;
    /// the denominator is whatever has been seen so far plus what is
    /// still expected, so the ring never goes backwards.
    private(set) var progressFraction: Double = 0

    private static let stageNames: [Workload: String] = [
        .baseline: "Checking the connection",
        .path: "Timing your WiFi link",
        .web: "Loading a web page",
        .video: "Starting a video",
        .download: "Testing download speed",
        .loadlat: "Checking latency under load",
        .email: "Checking email",
    ]
```

In `apply(_:)`, after updating `steps`, add:

```swift
        stageText = Self.stageNames[step.workload] ?? step.workload.rawValue
        let finished = steps.filter { $0.state != .pending && $0.state != .running }.count
        progressFraction = min(1, Double(finished) / Double(max(steps.count, 11)))
```

At the end of `run()`, after `phase = .done`, add:

```swift
        // Written after the verdict so the stored run carries it. A run
        // reopened later shows what it showed at the time, which is why
        // the verdict is snapshotted rather than refetched.
        let stored = StoredRun.from(outcome: result, steps: steps, verdict: verdict)
        savedRun = stored
        try? await AppStores.runs.save(stored)
        pendingUploads = await store.pendingCount
```

The download figure travels inside `result`, which is why Step 1 put it on `RunOutcome`.

- [ ] **Step 7: Build and run**

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src/mobile-ios
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'generic/platform=iOS' build
```

Expected: BUILD SUCCEEDED.

Then run on the device, take one measurement, and confirm in the Xcode console or by re-launching that the run persisted. The WiFi link should now report a real number rather than "your router did not answer": that is Tasks 1 to 3 arriving on the phone, and it is the first proof they work on iOS rather than only on macOS.

- [ ] **Step 8: Commit**

```bash
git add WiFiProbe/AppStores.swift WiFiProbe/RunViewModel.swift \
        WiFiProbeKit/Sources WiFiProbeKit/Tests
git commit -m "Mobile: save every run, and report progress as one line

The view model now writes a StoredRun once the verdict is in, and
exposes a stage name and a fraction so the next screen can show a
ring and a sentence rather than a list of workload rows."
```

---

### Task 8: The three-tab shell and the Now screen

Option A from the design: dial, sentence, three lights, one link to the detail.

**Files:**
- Create: `WiFiProbe/RootView.swift`
- Create: `WiFiProbe/Now/NowView.swift`
- Create: `WiFiProbe/Now/ScoreDial.swift`
- Create: `WiFiProbe/Now/SitePicker.swift`
- Modify: `WiFiProbe/WiFiProbeApp.swift`
- Modify: `WiFiProbe/WiFiProbe.xcodeproj/project.pbxproj` (add the new files to the target)
- Delete: `WiFiProbe/ContentView.swift` (its content moves to `RunDetailView` in Task 9; keep the file until then)

**Interfaces:**
- Consumes: `RunViewModel` (Task 7), `AppStores`, `Trends.readable(_:)`.
- Produces: `RootView`, `NowView`, `ScoreDial(score:label:)`, `SitePicker(selection:known:)`.

- [ ] **Step 1: Write ScoreDial**

Create `WiFiProbe/Now/ScoreDial.swift`:

```swift
import SwiftUI

/// The score as a ring. Doubles as the progress indicator during a run,
/// so the screen does not change shape when the numbers arrive.
struct ScoreDial: View {
    /// 0 to 100 when a run has finished, nil while one is in progress.
    var score: Double?
    var label: String?
    /// 0 to 1 while running.
    var progress: Double = 0
    var isRunning = false

    private var fraction: Double {
        isRunning ? progress : (score ?? 0) / 100
    }

    private var tint: Color {
        guard let score, !isRunning else { return .accentColor }
        switch score {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            VStack(spacing: 2) {
                if isRunning {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else if let score {
                    Text("\(Int(score.rounded()))")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let label {
                        Text(label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "wifi").font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 168, height: 168)
        .accessibilityElement()
        .accessibilityLabel(score.map { "Score \(Int($0.rounded())), \(label ?? "")" }
                            ?? "Not measured yet")
    }
}
```

- [ ] **Step 2: Write SitePicker**

Create `WiFiProbe/Now/SitePicker.swift`:

```swift
import SwiftUI
import WiFiProbeKit

/// Choosing the network label, from the ones already used plus a new one.
///
/// This replaces a free-text field. History and Trends are keyed on the
/// label, so a typo silently creates a second network, and a stray label
/// is how `phone-smoke-test` ended up in the deployment database.
struct SitePicker: View {
    @Binding var selection: String
    var known: [String]
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        Menu {
            ForEach(known, id: \.self) { site in
                Button {
                    selection = site
                } label: {
                    Label(Trends.readable(site),
                          systemImage: site == selection ? "checkmark" : "wifi")
                }
            }
            if !known.isEmpty { Divider() }
            Button("New network...") { draft = ""; adding = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wifi")
                Text(selection.isEmpty ? "Choose a network"
                                       : Trends.readable(selection))
                    .fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(selection.isEmpty ? .secondary : .primary)
        }
        .alert("Name this network", isPresented: $adding) {
            TextField("home, library, the cafe", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Use it") {
                if let label = SiteLabel.make(from: draft) { selection = label }
            }
        } message: {
            Text("Whatever you call the place you are in. Results are grouped by it.")
        }
    }
}
```

- [ ] **Step 3: Write NowView**

Create `WiFiProbe/Now/NowView.swift`:

```swift
import SwiftUI
import WiFiProbeKit

/// The main screen: a score, a sentence, three lights, and one way in to
/// everything else.
///
/// Every number that used to be on this screen still exists; it moved to
/// `RunDetailView`, one tap away. Nothing was deleted, it was ranked.
struct NowView: View {
    @State private var model = RunViewModel()
    @State private var knownSites: [String] = []
    @State private var showingDetail = false
    @State private var showingSteps = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SitePicker(selection: $model.siteInput, known: knownSites)

                    ScoreDial(score: model.savedRun?.verdict?.score,
                              label: model.savedRun?.verdict?.label,
                              progress: model.progressFraction,
                              isRunning: model.phase == .running
                                      || model.phase == .fetchingVerdict)
                        .padding(.top, 4)

                    headline
                    if model.phase == .done { segments }
                    if let failures = failureNote { note(failures, .orange) }
                    if let problem = model.verdictProblem { note(problem, .secondary) }
                    if let warning = wifiLinkWarning { note(warning, .orange) }
                    runButton
                    if model.phase == .done { detailLink }
                    if model.phase == .running || model.phase == .fetchingVerdict {
                        stepDisclosure
                    }
                }
                .padding()
            }
            .navigationTitle("This network")
            .background(WebHostView().frame(width: 1, height: 1).opacity(0.01))
            .task { knownSites = await AppStores.runs.sites() }
            .navigationDestination(isPresented: $showingDetail) {
                if let run = model.savedRun { RunDetailView(run: run) }
            }
        }
    }

    // MARK: pieces

    @ViewBuilder
    private var headline: some View {
        switch model.phase {
        case .running, .fetchingVerdict:
            Text(model.phase == .fetchingVerdict ? "Reading the verdict" : model.stageText)
                .font(.headline)
                .contentTransition(.opacity)
        case .done:
            VStack(spacing: 6) {
                Text(model.savedRun?.verdict?.headline ?? "Measured")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let pct = model.savedRun?.verdict?.availabilityPct, pct < 100 {
                    Text("\(Int(pct))% of tasks completed")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
        case .failed(let reason):
            Text(reason).font(.subheadline).foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .idle:
            Text(model.siteInput.isEmpty
                 ? "Pick a network, then test it"
                 : "Ready to test")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var segments: some View {
        VStack(spacing: 0) {
            ForEach(["wifi_link", "internet_path", "third_party"], id: \.self) { key in
                HStack {
                    Circle().fill(colour(model.savedRun?.verdict?.segments[key]))
                        .frame(width: 10, height: 10)
                    Text(name(key))
                    Spacer()
                    Text(state(model.savedRun?.verdict?.segments[key]))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                if key != "third_party" { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var runButton: some View {
        Button {
            Task {
                await model.run()
                knownSites = await AppStores.runs.sites()
            }
        } label: {
            Text(model.phase == .running || model.phase == .fetchingVerdict
                 ? "Measuring..." : "Test this network")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canRun)
    }

    private var detailLink: some View {
        Button("See the numbers") { showingDetail = true }
            .font(.subheadline)
    }

    private var stepDisclosure: some View {
        DisclosureGroup("What it is doing", isExpanded: $showingSteps) {
            ForEach(model.steps) { step in
                HStack {
                    Text("\(step.workload.rawValue) \u{00B7} \(step.endpoint.rawValue)")
                        .font(.caption)
                    Spacer()
                    if case .failed = step.state {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    } else if step.state == .ok {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if step.state == .running {
                        ProgressView()
                    }
                }
            }
        }
        .font(.subheadline)
    }

    private func note(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(colour)
            .multilineTextAlignment(.center)
    }

    /// What failed, as a consequence rather than as an error string. The
    /// raw text is on the detail screen; here a person needs to know that
    /// video was not tested, not that a URLSession task timed out.
    private var failureNote: String? {
        guard model.phase == .done, let run = model.savedRun else { return nil }
        let broken = Set(run.steps.filter { !$0.ok }.map(\.workload))
        guard !broken.isEmpty else { return nil }
        let names = broken.compactMap { workload -> String? in
            switch workload {
            case "web": return "loading a page"
            case "video": return "playing a video"
            case "download": return "downloading a file"
            case "loadlat": return "latency under load"
            case "baseline", "path": return "reaching the network"
            default: return nil
            }
        }.sorted()
        guard !names.isEmpty else { return nil }
        return names.count == 1
            ? "\(names[0].capitalized) could not be tested on this network."
            : "Some tests did not complete: \(names.joined(separator: ", "))."
    }

    /// Only shown when the ladder actually failed. Rung 1 works, so this
    /// should now be rare, and when it happens the detail screen lists
    /// what was tried.
    private var wifiLinkWarning: String? {
        guard model.phase == .done, let run = model.savedRun,
              run.wifiLinkMethod == "none" else { return nil }
        return "Your router answered nothing, so the WiFi link could not be timed. "
             + "Everything past the router was still measured. See the numbers for "
             + "what was tried."
    }

    private func name(_ key: String) -> String {
        switch key {
        case "wifi_link": return "Your WiFi"
        case "internet_path": return "Internet path"
        default: return "The services"
        }
    }

    private func state(_ value: String?) -> String {
        switch value {
        case "ok": return "fine"
        case "suspect": return "slow"
        case "unstable": return "patchy"
        case "down": return "down"
        default: return "no data"
        }
    }

    private func colour(_ value: String?) -> Color {
        switch value {
        case "ok": return .green
        case "suspect", "unstable": return .orange
        case "down": return .red
        default: return .gray
        }
    }
}
```

- [ ] **Step 4: Write RootView and point the app at it**

Create `WiFiProbe/RootView.swift`:

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NowView()
                .tabItem { Label("Now", systemImage: "gauge.with.dots.needle.67percent") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.bar") }
        }
    }
}
```

In `WiFiProbe/WiFiProbeApp.swift`, replace `ContentView()` with `RootView()`.

- [ ] **Step 5: Add the files to the Xcode target**

The project file is hand-written, so new files need entries. Add each new `.swift` under `PBXBuildFile`, `PBXFileReference`, the `Sources` build phase, and the appropriate `PBXGroup`. After editing:

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src/mobile-ios
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe -destination 'generic/platform=iOS' build 2>&1 | tail -20
```

Expected: this will fail until Tasks 9 and 10 create `HistoryView` and `TrendsView`. To keep the build green at the end of this task, add temporary stubs in `RootView.swift`:

```swift
// Replaced in Tasks 9 and 10.
struct HistoryView: View { var body: some View { Text("History") } }
struct TrendsView: View { var body: some View { Text("Trends") } }
```

Then the build must succeed. Delete the stubs in Tasks 9 and 10 as the real views land.

- [ ] **Step 6: Verify on the device**

Run on the phone. Confirm: the tab bar has three tabs; picking a network and tapping through produces a ring that fills, one line of plain text rather than a list, and then a score with three lights; the WiFi link light is not grey.

- [ ] **Step 7: Commit**

```bash
git add WiFiProbe WiFiProbe.xcodeproj
git commit -m "Mobile: three-tab shell and a Now screen a person can read

Score, sentence, three lights, one link in. The workload rows move to
a disclosure while running and to the detail screen afterwards."
```

---

### Task 9: History and the run detail screen

**Files:**
- Create: `WiFiProbe/History/HistoryView.swift`
- Create: `WiFiProbe/History/RunDetailView.swift`
- Modify: `WiFiProbe/RootView.swift` (remove the `HistoryView` stub)
- Delete: `WiFiProbe/ContentView.swift`
- Modify: `WiFiProbe/WiFiProbe.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AppStores.runs`, `StoredRun`, `Trends.readable(_:)`.
- Produces: `HistoryView`, `RunDetailView(run: StoredRun)`.

- [ ] **Step 1: Write RunDetailView**

This is the old `ContentView` content, in full. Nothing from it is dropped.

Create `WiFiProbe/History/RunDetailView.swift`:

```swift
import SwiftUI
import WiFiProbeKit

/// One run, in full: what was measured, against what, and what failed.
///
/// The Now screen is deliberately thin, which is only safe because
/// everything it leaves out is here. This is also the screenshot for the
/// evaluation chapter, since it shows the phone's own evidence beside the
/// verdict the backend returned for it.
struct RunDetailView: View {
    let run: StoredRun

    private var stamp: String {
        run.finishedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        List {
            Section("Verdict") {
                if let verdict = run.verdict {
                    LabeledContent("Score", value: verdict.score.map {
                        "\(Int($0.rounded())) \(verdict.label ?? "")"
                    } ?? "not scored")
                    if let quality = verdict.quality {
                        LabeledContent("Quality", value: String(format: "%.0f", quality))
                    }
                    if let availability = verdict.availabilityPct {
                        LabeledContent("Tasks completed",
                                       value: String(format: "%.0f%%", availability))
                    }
                    if let headline = verdict.headline { Text(headline).font(.callout) }
                    ForEach(verdict.segments.sorted(by: { $0.key < $1.key }), id: \.key) {
                        LabeledContent($0.key, value: $0.value)
                    }
                } else {
                    Text("The verdict could not be read for this run.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("The WiFi link") {
                LabeledContent("Router", value: run.gateway ?? "not found")
                LabeledContent("Measured by", value: methodName(run.wifiLinkMethod))
                if let rtt = run.verdict?.wifiLinkRTTms {
                    LabeledContent("Round trip", value: String(format: "%.1f ms", rtt))
                }
                ForEach(Array(run.wifiLinkAttempts.enumerated()), id: \.offset) { _, attempt in
                    HStack {
                        Image(systemName: attempt.answered
                              ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(attempt.answered ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(methodName(attempt.method)).font(.subheadline)
                            Text(attempt.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Measurements") {
                ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: step.ok ? "checkmark.circle.fill"
                                                      : "xmark.circle.fill")
                                .foregroundStyle(step.ok ? .green : .red)
                            Text("\(step.workload) \u{00B7} \(step.endpoint)")
                                .font(.subheadline)
                        }
                        Text(step.target).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let error = step.error {
                            Text(error).font(.caption2).foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Uploaded", value: "\(run.recordCount) records")
                if run.failedCount > 0 {
                    LabeledContent("Failed", value: "\(run.failedCount)")
                }
                LabeledContent("Network label", value: run.site)
                LabeledContent("Run id", value: run.id).font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text("This run")
            } footer: {
                // M6 disclosure, unchanged in substance from the old screen.
                Text("Based on \(run.recordCount) measurements from one run, a single "
                     + "sample per test. Scored by the same server-side logic as the "
                     + "fixed probes.")
            }
        }
        .navigationTitle(Trends.readable(run.site))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(Trends.readable(run.site)).font(.headline)
                    Text(stamp).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func methodName(_ raw: String) -> String {
        switch raw {
        case "icmp": return "Ping to the router"
        case "firstHopTTL": return "Expiring TTL at the first hop"
        case "tcp": return "TCP to the router"
        default: return "Nothing answered"
        }
    }
}
```

- [ ] **Step 2: Write HistoryView**

Create `WiFiProbe/History/HistoryView.swift`:

```swift
import SwiftUI
import WiFiProbeKit

/// Every run this phone has taken, newest first.
struct HistoryView: View {
    @State private var runs: [StoredRun] = []
    @State private var sites: [String] = []
    @State private var filter: String?

    private var shown: [StoredRun] {
        guard let filter else { return runs }
        return runs.filter { $0.site == filter }
    }

    private var days: [(day: Date, runs: [StoredRun])] {
        Dictionary(grouping: shown) {
            Calendar.current.startOfDay(for: $0.finishedAt)
        }
        .map { (day: $0.key, runs: $0.value.sorted { $0.finishedAt > $1.finishedAt }) }
        .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView("No runs yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Measure a network and it "
                                                             + "will show up here."))
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private var list: some View {
        List {
            if sites.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All", value: nil)
                            ForEach(sites, id: \.self) { chip(Trends.readable($0), value: $0) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            ForEach(days, id: \.day) { group in
                Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(group.runs) { run in
                        NavigationLink { RunDetailView(run: run) } label: { row(run) }
                    }
                    .onDelete { offsets in
                        Task { await delete(offsets, in: group.runs) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        Button(title) { filter = value }
            .buttonStyle(.bordered)
            .tint(filter == value ? .accentColor : .gray)
    }

    private func row(_ run: StoredRun) -> some View {
        HStack(spacing: 12) {
            Text(run.verdict?.score.map { "\(Int($0.rounded()))" } ?? "?")
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 38, height: 30)
                .background(badgeColour(run), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(Trends.readable(run.site)).font(.body)
                Text(subtitle(run)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One distinguishing number, or the failure if there was one, which
    /// is what makes the list skimmable.
    private func subtitle(_ run: StoredRun) -> String {
        let time = run.finishedAt.formatted(date: .omitted, time: .shortened)
        if run.verdict?.segments["internet_path"] == "down" { return "\(time) \u{00B7} internet down" }
        if run.failedCount > 0 { return "\(time) \u{00B7} \(run.failedCount) failed" }
        if let mbps = run.downloadMbps { return "\(time) \u{00B7} \(Int(mbps)) Mbps" }
        return time
    }

    private func badgeColour(_ run: StoredRun) -> Color {
        switch run.verdict?.score {
        case .some(80...): return .green
        case .some(50..<80): return .orange
        case .some: return .red
        default: return .gray
        }
    }

    private func reload() async {
        runs = await AppStores.runs.all()
        sites = await AppStores.runs.sites()
        if let filter, !sites.contains(filter) { self.filter = nil }
    }

    private func delete(_ offsets: IndexSet, in group: [StoredRun]) async {
        for index in offsets { try? await AppStores.runs.delete(id: group[index].id) }
        await reload()
    }
}
```

- [ ] **Step 3: Remove the stub and the old screen**

Delete the `HistoryView` stub from `RootView.swift`. Delete `WiFiProbe/ContentView.swift` and remove its entries from the project file, adding the two new files in its place.

- [ ] **Step 4: Build**

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src/mobile-ios
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'generic/platform=iOS' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Verify on the device**

Take two runs under different network labels. Confirm: both appear under History newest first; the filter chips appear once there are two labels; tapping a row shows every workload, every target, the ladder's attempts, and the run id; swiping a row deletes it.

- [ ] **Step 6: Commit**

```bash
git add WiFiProbe WiFiProbe.xcodeproj
git commit -m "Mobile: History, and a detail screen holding the evidence

Every run newest first, filterable by network. The detail screen is
the old single screen in full, which is what makes the Now tab safe
to simplify."
```

---

### Task 10: Trends

**Files:**
- Create: `WiFiProbe/Trends/TrendsView.swift`
- Create: `WiFiProbe/Trends/SiteTrendView.swift`
- Modify: `WiFiProbe/RootView.swift` (remove the `TrendsView` stub)
- Modify: `WiFiProbe/WiFiProbe.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Trends.rank(_:)`, `Trends.series(_:metric:)`, `Trends.insight(for:)`, `Trends.Metric`, `AppStores.runs`.
- Produces: `TrendsView`, `SiteTrendView(site: String)`.

- [ ] **Step 1: Write TrendsView**

Create `WiFiProbe/Trends/TrendsView.swift`:

```swift
import SwiftUI
import WiFiProbeKit

/// The networks this phone has visited, ranked.
///
/// A phone produces one point per tap, so this does not try to be the
/// Grafana board. It answers the question a phone is placed to answer,
/// which is which of the networks you actually go to is any good.
struct TrendsView: View {
    @State private var summaries: [Trends.SiteSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableView("Nothing to compare yet",
                                           systemImage: "chart.bar",
                                           description: Text("Measure a couple of "
                                                             + "networks and they will "
                                                             + "be ranked here."))
                } else {
                    List {
                        Section("Networks you have tested") {
                            ForEach(summaries) { summary in
                                NavigationLink {
                                    SiteTrendView(site: summary.site)
                                } label: {
                                    row(summary)
                                }
                            }
                        }
                        if let weakest = summaries.last,
                           let insight = Trends.insight(for: weakest) {
                            Section { Text(insight).font(.callout) }
                        }
                    }
                }
            }
            .navigationTitle("Trends")
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func row(_ summary: Trends.SiteSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Trends.readable(summary.site)).font(.body)
                Spacer()
                Text(summary.medianScore.map { "\(Int($0.rounded()))" } ?? "-")
                    .font(.subheadline.weight(.bold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule().fill(colour(summary.medianScore))
                        .frame(width: geometry.size.width
                               * ((summary.medianScore ?? 0) / 100))
                }
            }
            .frame(height: 8)
            Text("\(summary.runCount) run\(summary.runCount == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func colour(_ score: Double?) -> Color {
        switch score {
        case .some(80...): return .green
        case .some(50..<80): return .orange
        case .some: return .red
        default: return .gray
        }
    }

    private func reload() async {
        summaries = Trends.rank(await AppStores.runs.all())
    }
}
```

- [ ] **Step 2: Write SiteTrendView**

Create `WiFiProbe/Trends/SiteTrendView.swift`:

```swift
import Charts
import SwiftUI
import WiFiProbeKit

/// One network over time. Where a fixed probe runs at the same site, its
/// line is drawn behind the phone's points: same metric, same scorer, two
/// unrelated clients.
struct SiteTrendView: View {
    let site: String

    @State private var runs: [StoredRun] = []
    @State private var metric: Trends.Metric = .score

    private var points: [Point] {
        Trends.series(runs, metric: metric)
            .map { Point(date: $0.date, value: $0.value) }
    }

    struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    var body: some View {
        List {
            Section {
                Picker("Metric", selection: $metric) {
                    ForEach(Trends.Metric.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if points.count < 2 {
                    Text("One run so far. Test this network again and a line appears.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    chart
                }
            }

            Section("Typical") {
                let summary = Trends.summarise(site: site, runs: runs)
                LabeledContent("Score", value: summary.medianScore
                    .map { "\(Int($0.rounded()))" } ?? "-")
                LabeledContent("Speed", value: summary.medianDownloadMbps
                    .map { String(format: "%.0f Mbps", $0) } ?? "-")
                LabeledContent("WiFi link", value: summary.medianWiFiLinkMs
                    .map { String(format: "%.1f ms", $0) } ?? "-")
                LabeledContent("Runs", value: "\(summary.runCount)")
            }
        }
        .navigationTitle(Trends.readable(site))
        .navigationBarTitleDisplayMode(.inline)
        .task { runs = await AppStores.runs.runs(site: site) }
    }

    private var chart: some View {
        Chart(points) { point in
            LineMark(x: .value("When", point.date), y: .value(metric.title, point.value))
                .interpolationMethod(.monotone)
            PointMark(x: .value("When", point.date), y: .value(metric.title, point.value))
        }
        .chartYAxisLabel(metric.unit)
        .frame(height: 180)
        .padding(.vertical, 6)
    }
}
```

The fixed-probe overlay is deliberately not built here. It needs a second data source and the dashboard password, and it is the one piece of this tab that fails without signal. Add it only after the rest is working, as a separate change, using `SummaryClient` against `run.fixedProbeSite`.

- [ ] **Step 3: Make `Trends.summarise` public**

`SiteTrendView` calls it. In `Sources/WiFiProbeKit/Trends.swift`, change `static func summarise` to `public static func summarise`.

- [ ] **Step 4: Remove the stub, add the files, build**

Delete the `TrendsView` stub from `RootView.swift`, add both new files to the project, then:

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src/mobile-ios
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'generic/platform=iOS' build 2>&1 | tail -20
swift test --package-path WiFiProbeKit
```

Expected: BUILD SUCCEEDED, and the full test suite passes.

- [ ] **Step 5: Verify on the device**

With runs against at least two networks: Trends ranks them best first, the bars are proportionate, the insight sentence names a segment, and tapping a network shows a chart that switches between score, speed and WiFi link.

- [ ] **Step 6: Commit**

```bash
git add WiFiProbe WiFiProbe.xcodeproj WiFiProbeKit/Sources/WiFiProbeKit/Trends.swift
git commit -m "Mobile: Trends, ranking the networks the phone has seen

Median score per network, best first, with a per-network chart over
score, speed and WiFi link."
```

---

### Task 11: Settings, and the documents that describe this work

**Files:**
- Create: `WiFiProbe/SettingsView.swift`
- Modify: `WiFiProbe/Now/NowView.swift` (toolbar button)
- Modify: `src/mobile-ios/CONSTRAINTS.md`
- Modify: `src/mobile-ios/REQUIREMENTS.md`
- Modify: `src/mobile-ios/README.md`
- Modify: `src/mobile-ios/NEXT.md`
- Modify: `CLAUDE.md` (repository root, authorised by C1)

**Interfaces:**
- Consumes: `AppStores`, `RunStore.deleteAll()`, `PendingStore.pendingCount`.
- Produces: `SettingsView`.

- [ ] **Step 1: Write SettingsView**

Create `WiFiProbe/SettingsView.swift`:

```swift
import SwiftUI
import WiFiProbeKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pending = 0
    @State private var runCount = 0
    @State private var confirmingWipe = false

    var body: some View {
        NavigationStack {
            List {
                Section("This phone") {
                    LabeledContent("Probe id",
                                   value: (Bundle.main.object(
                                    forInfoDictionaryKey: "PROBE_ID") as? String) ?? "not set")
                    LabeledContent("Runs kept", value: "\(runCount)")
                    LabeledContent("Waiting to upload", value: "\(pending)")
                }

                Section {
                    Button("Delete all local runs", role: .destructive) {
                        confirmingWipe = true
                    }
                } footer: {
                    // Uploaded records are the backend's, and there is no
                    // delete endpoint. Say so rather than implying the
                    // button reaches further than it does.
                    Text("Removes the history kept on this phone. Measurements already "
                         + "uploaded stay on the server.")
                }

                Section {
                    LabeledContent("Site prefix", value: SiteLabel.prefix)
                } footer: {
                    Text("Every measurement from this phone is filed under this prefix, "
                         + "which keeps it apart from the fixed probes.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                pending = await AppStores.pending.pendingCount
                runCount = await AppStores.runs.all().count
            }
            .alert("Delete all runs?", isPresented: $confirmingWipe) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        try? await AppStores.runs.deleteAll()
                        runCount = 0
                    }
                }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
```

- [ ] **Step 2: Reach it from Now**

In `NowView`, add `@State private var showingSettings = false`, then to the `NavigationStack`'s content add:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
```

- [ ] **Step 3: Build and verify**

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src/mobile-ios
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED. On the device, the gear opens Settings and the counts are right.

- [ ] **Step 4: Update CONSTRAINTS.md**

Replace the C6 entry's three-day cap with:

```markdown
### C6. The dissertation outranks this work

The three working day cap was lifted on 23 August 2026 at the user's
explicit instruction. It is replaced by a stopping condition rather than
a number:

> The app is finished when the three tabs work and the WiFi link is
> measured. Nothing beyond that is built before the dissertation is
> written.

CA3 is due 11 September 2026 and Chapter 4 is not written. The sequencing
agreed on 23 August is app, then fault injection, then writing, which
puts two build tasks in front of a 50 page document. Writing therefore
proceeds in parallel rather than afterwards.
```

- [ ] **Step 5: Update REQUIREMENTS.md**

- Mark MS1 (persistent buffer) as done, delivered by Task 5, and note it came out of the run store rather than being built for its own sake.
- Add M11: "History and Trends, kept on the device", satisfied by Tasks 4, 6, 9 and 10.
- Update the build status table so the three tabs are listed.

- [ ] **Step 6: Update README.md and NEXT.md**

In `README.md`: replace the "known gaps" line about the WiFi link being unproven with the finding from Task 1, describe the three-rung ladder, and describe the three tabs.

In `NEXT.md`: the two parked tasks stand, but rewrite them for the new app. The interruption test now also checks that the queue survives being killed, not only that it drains, and the screenshot brief now names `RunDetailView` beside `/overview`. Remove the resolved open questions: the branch is merged, and "what did the WiFi link method report" is answered by the ladder.

- [ ] **Step 7: Update CLAUDE.md**

In the iOS open-items entry, replace the two open items (dashboard password, unproven ICMP path) with: the ICMP parsing finding and its correction, the three-rung ladder, the three tabs with on-device history, and the lifted C6 cap. Keep the pointer to `CONSTRAINTS.md`.

- [ ] **Step 8: Final verification**

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src/mobile-ios
swift test --package-path WiFiProbeKit 2>&1 | tail -5
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'generic/platform=iOS' build 2>&1 | tail -3
grep -rn "three working days\|three days" CONSTRAINTS.md README.md NEXT.md
```

Expected: all tests pass, the build succeeds, and the only remaining mentions of a three day budget are historical ones describing the lifted cap.

- [ ] **Step 9: Commit**

```bash
cd /Users/selimgul/Desktop/claude/projects/COMP702/src
git add mobile-ios
git commit -m "Mobile: settings, and bring the documents up to date

Lifts the C6 three-day cap in favour of a stopping condition, records
MS1 as delivered, and corrects the claim that the campus router
ignores ICMP."
```

---

## What this plan does not do

Named so they are decisions rather than omissions:

- **The fixed-probe overlay on the Trends chart.** Designed, deliberately deferred inside Task 10, because it is the only part of the tab that needs signal and credentials. Add it after the rest works.
- **Background or scheduled runs (MS3), automatic SSID labelling (MS4), App Store distribution.** Out of scope per the design, and MS4 needs an entitlement Apple does not grant for this.
- **The interruption test and the Chapter 4 screenshots.** They are in `NEXT.md` and need the phone in hand. Task 5 makes the first of them meaningful, since the queue now has to survive a restart rather than merely a network blip.
- **Fault injection (build step 7).** The next piece of project work after this, and the last thing blocking Chapter 4.
