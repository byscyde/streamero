import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StreameroKit

/// Records requests and answers from fixtures keyed by "METHOD path".
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var routes: [String: (Int, Data)] = [:]

    var requests: [URLRequest] { lock.withLock { _requests } }
    var last: URLRequest? { requests.last }

    func route(_ method: String, _ path: String, status: Int = 200, fixture: String) {
        routes["\(method) \(path)"] = (status, Fixture.data(fixture))
    }
    func route(_ method: String, _ path: String, status: Int = 200, json: String) {
        routes["\(method) \(path)"] = (status, Data(json.utf8))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let (status, data) = routes[key] ?? (404, Data("{\"message\":\"no route \(key)\"}".utf8))
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

extension URLRequest {
    var bodyJSON: [String: Any]? { httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    func query(_ name: String) -> [String] {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }
}

final class ServiceConfigTests: XCTestCase {
    func testURLNormalisationAndDefaults() {
        XCTAssertEqual(ServiceInstance.normalisedURL(" son.streamero.net/ ")?.absoluteString, "https://son.streamero.net")
        XCTAssertEqual(ServiceInstance.normalisedURL("http://192.168.1.10:8989")?.absoluteString, "http://192.168.1.10:8989")
        XCTAssertNil(ServiceInstance.normalisedURL(""))
        XCTAssertNil(ServiceInstance.normalisedURL("ftp://x.test"))
        XCTAssertEqual(ServiceKind.jellyfin.defaultURL, "https://streamero.net")
        XCTAssertEqual(ServiceKind.seerr.defaultURL, "https://req.streamero.net")
        XCTAssertEqual(ServiceKind.radarr.defaultURL, "https://rad.streamero.net")
        XCTAssertEqual(ServiceKind.sonarr.defaultURL, "https://son.streamero.net")
        XCTAssertFalse(ServiceInstance(kind: .sonarr).isConfigured, "needs an API key")
        XCTAssertTrue(ServiceInstance(kind: .sonarr, apiKey: "k").isConfigured)
    }

    func testEachServiceGetsItsPrefixAndAuthHeader() throws {
        let cases: [(ServiceKind, String, String, String)] = [
            (.sonarr, "https://son.streamero.net/api/v3/system/status", "X-Api-Key", "k"),
            (.radarr, "https://rad.streamero.net/api/v3/system/status", "X-Api-Key", "k"),
            (.lidarr, "https://lid.streamero.net/api/v1/system/status", "X-Api-Key", "k"),
            (.prowlarr, "https://prow.streamero.net/api/v1/system/status", "X-Api-Key", "k"),
            (.seerr, "https://req.streamero.net/api/v1/system/status", "X-Api-Key", "k"),
            (.bazarr, "https://baz.streamero.net/api/system/status", "X-API-KEY", "k"),
        ]
        for (kind, url, header, value) in cases {
            let client = try ServiceClients.client(for: ServiceInstance(kind: kind, apiKey: "k"))
            let request = try client.request(.get, "system/status")
            XCTAssertEqual(request.url?.absoluteString, url, "\(kind)")
            XCTAssertEqual(request.value(forHTTPHeaderField: header), value, "\(kind)")
        }
        let jellyfin = try ServiceClients.client(for: ServiceInstance(kind: .jellyfin, apiKey: "tok"), deviceId: "dev1", appVersion: "2.0.0")
        let auth = try jellyfin.request(.get, "System/Info").value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("MediaBrowser "))
        XCTAssertTrue(auth.contains("Token=\"tok\"") && auth.contains("DeviceId=\"dev1\"") && auth.contains("Client=\"Streamero\""))
    }

    func testQueryEncoding() throws {
        let client = ServiceClient(baseURL: URL(string: "https://req.streamero.net/")!, prefix: "api/v1")
        let url = try client.url("search", query: [URLQueryItem(name: "query", value: "dune part+two & co")])
        XCTAssertEqual(url.absoluteString, "https://req.streamero.net/api/v1/search?query=dune%20part%2Btwo%20%26%20co")
    }

    func testErrorsAreMapped() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/series", status: 401, json: "{}")
        mock.route("GET", "/api/v3/movie", status: 500, json: "{\"message\":\"Database is locked\"}")
        let sonarr = SonarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .sonarr, apiKey: "bad"), transport: mock))
        do { _ = try await sonarr.series(); XCTFail() } catch { XCTAssertEqual(error as? ServiceError, .unauthorized) }
        let radarr = RadarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .radarr, apiKey: "k"), transport: mock))
        do { _ = try await radarr.movies(); XCTFail() } catch {
            XCTAssertEqual(error as? ServiceError, .http(status: 500, message: "Database is locked"))
        }
    }
}

final class DateTests: XCTestCase {
    func testFlexibleDates() {
        let jellyfin = FlexibleDate.parse("2026-10-28T09:58:31.1234567Z")
        XCTAssertNotNil(jellyfin)
        XCTAssertEqual(jellyfin!.timeIntervalSince1970, FlexibleDate.parse("2026-10-28T09:58:31.123Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(FlexibleDate.parse("2026-10-27T18:22:10.000Z"))
        XCTAssertNotNil(FlexibleDate.parse("2024-02-27T00:00:00Z"))
        XCTAssertNotNil(FlexibleDate.parse("2024-02-27T00:00:00"), "no zone → UTC")
        XCTAssertNotNil(FlexibleDate.parse("2024-02-27T00:00:00+02:00"))
        XCTAssertEqual(ISODay.string(FlexibleDate.parse("2024-02-27")!), "2024-02-27")
        XCTAssertNil(FlexibleDate.parse("yesterday"))
        XCTAssertFalse(Format.isRealDate(FlexibleDate.parse("0001-01-01T00:00:00.0000000Z")))
    }
}

final class ArrTests: XCTestCase {
    func sonarr(_ mock: MockTransport) throws -> SonarrClient {
        SonarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .sonarr, apiKey: "k"), transport: mock))
    }

    func testSeriesAndQueueDecode() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/series", fixture: "sonarr_series")
        mock.route("GET", "/api/v3/queue", fixture: "sonarr_queue")
        let client = try sonarr(mock)
        let series = try await client.series()
        XCTAssertEqual(series.first?.title, "Severance")
        XCTAssertEqual(series.first?.images?.poster?.host, "artworks.thetvdb.com")
        XCTAssertEqual(series.first?.episodeProgress ?? 0, 0.789, accuracy: 0.001)
        XCTAssertEqual(series.first?.seasons?.count, 2)

        let queue = try await client.queue()
        XCTAssertEqual(queue.totalRecords, 2)
        XCTAssertEqual(mock.last?.query("includeEpisode"), ["true"])
        let first = ActivityDownload(serviceId: UUID(), kind: .sonarr, item: queue.records[0])
        XCTAssertEqual(first.title, "Severance")
        XCTAssertEqual(first.subtitle, "S02E03 · Who Is Alive?")
        XCTAssertEqual(first.progress, 0.75, accuracy: 0.001)
        XCTAssertEqual(first.timeLeft, "4m")
        XCTAssertNil(first.problem)
        let stuck = ActivityDownload(serviceId: UUID(), kind: .sonarr, item: queue.records[1])
        XCTAssertEqual(stuck.problem, "No files found are eligible for import")
    }

    func testUpdateKeepsUnknownFields() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/series/12", json: #"{"id":12,"title":"Severance","monitored":true,"seasonFolder":true,"tags":[3],"alternateTitles":[{"title":"Odvajanje"}]}"#)
        mock.route("PUT", "/api/v3/series/12", json: #"{"id":12,"title":"Severance","monitored":false}"#)
        try await sonarr(mock).setMonitored(seriesId: 12, false)
        let body = try XCTUnwrap(mock.last?.bodyJSON)
        XCTAssertEqual(mock.last?.httpMethod, "PUT")
        XCTAssertEqual(body["monitored"] as? Bool, false)
        XCTAssertEqual(body["id"] as? Int, 12, "ids stay integral")
        XCTAssertNotNil(body["alternateTitles"], "unmodelled fields survive the round trip")
        XCTAssertEqual(body["tags"] as? [Int], [3])
    }

    func testAddFromLookupAndCommands() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/series/lookup", json: #"[{"title":"Severance","tvdbId":371980,"images":[],"seasons":[{"seasonNumber":1}]}]"#)
        mock.route("POST", "/api/v3/series", json: #"{"id":99,"title":"Severance"}"#)
        mock.route("POST", "/api/v3/command", json: #"{"id":1,"name":"SeriesSearch","status":"queued"}"#)
        let client = try sonarr(mock)
        let results = try await client.lookup("severance")
        XCTAssertEqual(mock.last?.query("term"), ["severance"])
        let added = try await client.add(results[0], qualityProfileId: 4, rootFolderPath: "/tv")
        XCTAssertEqual(added.id, 99)
        let body = try XCTUnwrap(mock.last?.bodyJSON)
        XCTAssertEqual(body["qualityProfileId"] as? Int, 4)
        XCTAssertEqual(body["rootFolderPath"] as? String, "/tv")
        XCTAssertEqual(body["tvdbId"] as? Int, 371980)
        XCTAssertEqual((body["addOptions"] as? [String: Any])?["searchForMissingEpisodes"] as? Bool, true)

        try await client.searchEpisodes([501, 502])
        let command = try XCTUnwrap(mock.last?.bodyJSON)
        XCTAssertEqual(command["name"] as? String, "EpisodeSearch")
        XCTAssertEqual(command["episodeIds"] as? [Int], [501, 502])
    }

    func testRadarrAndCalendar() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/movie", fixture: "radarr_movies")
        let radarr = RadarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .radarr, apiKey: "k"), transport: mock))
        let movies = try await radarr.movies()
        XCTAssertEqual(movies[0].movieFile?.quality?.name, "Bluray-2160p")
        XCTAssertEqual(movies[0].images?.poster?.host, "image.tmdb.org")
        let now = FlexibleDate.parse("2026-10-28T00:00:00Z")!
        XCTAssertNil(CalendarEntry.from(movies[0], now: now), "all release dates are in the past")
        let upcoming = try XCTUnwrap(CalendarEntry.from(movies[1], now: now))
        XCTAssertEqual(upcoming.subtitle, "In cinemas")
        XCTAssertEqual(ISODay.string(upcoming.date), "2026-12-18")
    }

    func testLidarrAndProwlarr() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v1/artist", fixture: "lidarr_artists")
        mock.route("GET", "/api/v1/indexer", fixture: "prowlarr_indexers")
        mock.route("GET", "/api/v1/search", fixture: "prowlarr_search")
        mock.route("POST", "/api/v1/search", json: "{}")
        let lidarr = LidarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .lidarr, apiKey: "k"), transport: mock))
        let artists = try await lidarr.artists()
        XCTAssertEqual(artists.first?.artistName, "Daft Punk")
        XCTAssertEqual(artists.first?.statistics?.albumCount, 4)

        let prowlarr = ProwlarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .prowlarr, apiKey: "k"), transport: mock))
        let indexers = try await prowlarr.indexers()
        XCTAssertEqual(indexers.map(\.enable), [true, false])
        let releases = try await prowlarr.search("big buck bunny", indexerIds: [1, 2])
        XCTAssertEqual(mock.last?.query("indexerIds"), ["1", "2"])
        XCTAssertEqual(releases.first?.seeders, 120)
        try await prowlarr.grab(releases[0])
        XCTAssertEqual(mock.last?.bodyJSON?["indexerId"] as? Int, 1)
        XCTAssertEqual(mock.last?.bodyJSON?["guid"] as? String, "magnet:?xt=urn:btih:abc")
    }
}

final class SeerrTests: XCTestCase {
    func client(_ mock: MockTransport) throws -> SeerrClient {
        SeerrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .seerr, apiKey: "k"), transport: mock))
    }

    func testRequestsDecodeAndActions() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v1/request", fixture: "seerr_requests")
        mock.route("POST", "/api/v1/request/41/approve", json: "{}")
        let seerr = try client(mock)
        let page = try await seerr.requests(filter: .pending)
        XCTAssertEqual(mock.last?.query("filter"), ["pending"])
        XCTAssertEqual(page.results.count, 2)
        XCTAssertEqual(page.results[0].requestStatus, .pending)
        XCTAssertEqual(page.results[0].requestedBy?.name, "Ana")
        XCTAssertEqual(page.results[1].requestedBy?.name, "admin", "empty displayName falls back to the Jellyfin user name")
        XCTAssertEqual(page.results[1].media?.mediaStatus, .processing)
        try await seerr.approve(41)
        XCTAssertEqual(mock.last?.httpMethod, "POST")
    }

    func testSearchSkipsPeopleAndTVRequestsAllSeasons() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v1/search", fixture: "seerr_search")
        mock.route("GET", "/api/v1/tv/95396", fixture: "seerr_tv")
        mock.route("POST", "/api/v1/request", json: "{}")
        let seerr = try client(mock)
        let results = try await seerr.search("dune")
        XCTAssertEqual(results.map(\.mediaType), ["movie", "tv"])
        XCTAssertEqual(results[0].year, "2024")
        XCTAssertEqual(results[0].mediaInfo?.mediaStatus, .available)
        XCTAssertEqual(results[0].posterURL?.absoluteString, "https://image.tmdb.org/t/p/w342/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg")

        try await seerr.request(results[1])
        let body = try XCTUnwrap(mock.last?.bodyJSON)
        XCTAssertEqual(body["mediaType"] as? String, "tv")
        XCTAssertEqual(body["mediaId"] as? Int, 95396)
        XCTAssertEqual(body["seasons"] as? [Int], [1, 2], "specials are not requested")

        try await seerr.request(results[0])
        XCTAssertNil(mock.last?.bodyJSON?["seasons"], "movies send no seasons")
    }
}

final class BazarrTests: XCTestCase {
    func testWantedAndDownload() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/episodes/wanted", fixture: "bazarr_wanted_episodes")
        mock.route("GET", "/api/episodes/history", fixture: "bazarr_history")
        mock.route("PATCH", "/api/episodes/subtitles", json: "")
        let bazarr = BazarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .bazarr, apiKey: "k"), transport: mock))
        let wanted = try await bazarr.wantedEpisodes()
        XCTAssertEqual(wanted.total, 1)
        let episode = try XCTUnwrap(wanted.data.first)
        XCTAssertEqual(episode.missingSubtitles.map(\.label), ["Croatian", "English (HI)"], "string booleans are understood")
        try await bazarr.downloadSubtitle(episode: episode, language: episode.missingSubtitles[0])
        let request = try XCTUnwrap(mock.last)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.query("seriesid"), ["12"])
        XCTAssertEqual(request.query("episodeid"), ["501"])
        XCTAssertEqual(request.query("language"), ["hr"])
        XCTAssertEqual(request.query("hi"), ["False"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-KEY"), "k")

        let history = try await bazarr.episodeHistory()
        XCTAssertEqual(history.first?.displayTitle, "Severance 2x2")
        XCTAssertEqual(history.first?.provider, "opensubtitlescom")
    }
}

final class JellyfinTests: XCTestCase {
    func client(_ mock: MockTransport) throws -> JellyfinClient {
        JellyfinClient(client: try ServiceClients.client(for: ServiceInstance(kind: .jellyfin, apiKey: "tok"), transport: mock))
    }

    func testSessionsUsersTasks() async throws {
        let mock = MockTransport()
        mock.route("GET", "/Sessions", fixture: "jellyfin_sessions")
        mock.route("GET", "/Users", fixture: "jellyfin_users")
        mock.route("GET", "/ScheduledTasks", fixture: "jellyfin_tasks")
        mock.route("POST", "/Sessions/a1b2c3/Playing/Stop", json: "")
        let jellyfin = try client(mock)
        let sessions = try await jellyfin.sessions()
        let playing = try XCTUnwrap(sessions.first { $0.isPlaying })
        XCTAssertEqual(playing.nowPlayingItem?.displayTitle, "Severance — S02E03 · Who Is Alive?")
        XCTAssertEqual(playing.progress, 0.5, accuracy: 0.001)
        XCTAssertTrue(playing.isTranscoding)
        XCTAssertEqual(sessions.filter(\.isPlaying).count, 1)
        try await jellyfin.send(.stop, to: playing.id)
        XCTAssertEqual(mock.last?.url?.path, "/Sessions/a1b2c3/Playing/Stop")

        let users = try await jellyfin.users()
        XCTAssertEqual(users.map(\.isAdmin), [true, false])
        XCTAssertTrue(users[1].isDisabled)
        XCTAssertFalse(Format.isRealDate(users[1].lastActivityDate))

        let tasks = try await jellyfin.scheduledTasks()
        XCTAssertTrue(tasks[0].isRunning)
        XCTAssertEqual(tasks[0].lastExecutionResult?.status, "Completed")
    }

    func testPolicyUpdateSendsWholePolicy() async throws {
        let mock = MockTransport()
        mock.route("GET", "/Users/u2", json: #"{"Id":"u2","Name":"guest","Policy":{"IsAdministrator":false,"IsDisabled":true,"EnableRemoteAccess":true,"MaxActiveSessions":3}}"#)
        mock.route("POST", "/Users/u2/Policy", json: "")
        try await client(mock).setDisabled(userId: "u2", false)
        let body = try XCTUnwrap(mock.last?.bodyJSON)
        XCTAssertEqual(body["IsDisabled"] as? Bool, false)
        XCTAssertEqual(body["MaxActiveSessions"] as? Int, 3)
        XCTAssertEqual(body["EnableRemoteAccess"] as? Bool, true)
    }

    func testAuthentication() async throws {
        let mock = MockTransport()
        mock.route("POST", "/Users/AuthenticateByName", json: #"{"AccessToken":"newtoken","User":{"Id":"u0","Name":"admin","Policy":{"IsAdministrator":true}}}"#)
        let anonymous = JellyfinClient(client: try ServiceClients.client(for: ServiceInstance(kind: .jellyfin), transport: mock))
        let result = try await anonymous.authenticate(username: "admin", password: "pw")
        XCTAssertEqual(result.accessToken, "newtoken")
        XCTAssertTrue(result.user.isAdmin)
        XCTAssertEqual(mock.last?.bodyJSON?["Username"] as? String, "admin")
        XCTAssertFalse((mock.last?.value(forHTTPHeaderField: "Authorization") ?? "").contains("Token="), "no token before sign-in")
    }
}

final class AggregateTests: XCTestCase {
    func testTimeLeftAndFormatting() {
        XCTAssertEqual(ActivityDownload.compactTimeLeft("01:02:03"), "1h 2m")
        XCTAssertEqual(ActivityDownload.compactTimeLeft("2.03:04:05"), "2d 3h")
        XCTAssertEqual(ActivityDownload.compactTimeLeft("00:00:09"), "9s")
        XCTAssertNil(ActivityDownload.compactTimeLeft("00:00:00"))
        XCTAssertEqual(Format.bytes(1536), "1.5 KB")
        XCTAssertEqual(Format.bytes(41_234_567_890), "38.4 GB")
        XCTAssertEqual(Format.ticks(36_000_000_000), "1:00:00")
        XCTAssertEqual(Format.ticks(1_850_000_000), "3:05")
    }

    func testDisksAndHealth() {
        let a = DiskSpace(path: "/data", label: nil, freeSpace: 100, totalSpace: 1000)
        let b = DiskSpace(path: "/config", label: nil, freeSpace: 900, totalSpace: 1000)
        let unique = DiskSummary.unique([a, b, a])
        XCTAssertEqual(unique.map(\.path), ["/data", "/config"], "duplicates removed, fullest first")
        XCTAssertEqual(unique[0].usedFraction, 0.9, accuracy: 0.0001)

        let issues = HealthIssue.sorted([
            HealthIssue(service: "Sonarr", severity: .notice, message: "Update available"),
            HealthIssue(service: "Radarr", severity: .error, message: "Download client unavailable"),
            HealthIssue(service: "Bazarr", severity: .warning, message: "Provider throttled"),
        ])
        XCTAssertEqual(issues.map(\.service), ["Radarr", "Bazarr", "Sonarr"])
    }

    func testCalendarGrouping() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d1 = FlexibleDate.parse("2026-11-01T20:00:00Z")!
        let d2 = FlexibleDate.parse("2026-11-01T08:00:00Z")!
        let d3 = FlexibleDate.parse("2026-11-03T08:00:00Z")!
        let entries = [d1, d2, d3].enumerated().map { CalendarEntry(id: "\($0.offset)", kind: .episode, date: $0.element, title: "x", subtitle: nil, posterURL: nil, hasFile: false) }
        let groups = CalendarEntry.groupedByDay(entries, calendar: cal)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries.map(\.id), ["1", "0"], "sorted by time within a day")
    }
}
