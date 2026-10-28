import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StreameroKit

final class ProviderTests: XCTestCase {
    let downloadClientJSON = #"""
    {"enable":true,"protocol":"torrent","priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true,"name":"qBittorrent",
     "fields":[{"order":0,"name":"host","label":"Host","value":"localhost","type":"textbox","advanced":false},
               {"order":1,"name":"port","label":"Port","value":8080,"type":"number","advanced":false},
               {"order":2,"name":"useSsl","label":"Use SSL","value":false,"type":"checkbox","advanced":false},
               {"order":3,"name":"password","label":"Password","value":"secret","type":"password","advanced":false,"privacy":"password"},
               {"order":4,"name":"movieCategory","label":"Category","value":"radarr","type":"textbox","helpText":"Adding a category specific to Radarr avoids conflicts"},
               {"order":5,"name":"initialState","label":"Initial State","value":0,"type":"select","selectOptions":[{"value":0,"name":"Start","order":0},{"value":1,"name":"Force Start","order":1},{"value":2,"name":"Pause","order":2}]},
               {"order":6,"name":"internal","label":"Internal","value":"x","type":"textbox","hidden":"hidden"}],
     "implementationName":"qBittorrent","implementation":"QBittorrent","configContract":"QBittorrentSettings","infoLink":"https://wiki.servarr.com/radarr/supported#qbittorrent","tags":[],"id":3}
    """#

    func provider() throws -> Provider { Provider(raw: try JSONDecoder().decode(JSONValue.self, from: Data(downloadClientJSON.utf8))) }

    func testFieldsKindsAndDisplay() throws {
        let p = try provider()
        XCTAssertEqual(p.name, "qBittorrent")
        XCTAssertEqual(p.enableKey, "enable")
        XCTAssertTrue(p.isEnabled)
        let fields = Dictionary(uniqueKeysWithValues: p.fields.map { ($0.name, $0) })
        XCTAssertEqual(fields["host"]?.kind, .text)
        XCTAssertEqual(fields["port"]?.kind, .number)
        XCTAssertEqual(fields["port"]?.displayValue, "8080")
        XCTAssertEqual(fields["useSsl"]?.kind, .toggle)
        XCTAssertEqual(fields["password"]?.kind, .secret)
        XCTAssertEqual(fields["password"]?.displayValue, "••••••")
        XCTAssertEqual(fields["initialState"]?.kind, .select)
        XCTAssertEqual(fields["initialState"]?.displayValue, "Start")
        XCTAssertEqual(fields["initialState"]?.options.count, 3)
        XCTAssertTrue(fields["internal"]?.hidden == true)
        XCTAssertEqual(p.toggles.map(\.key), ["removeCompletedDownloads", "removeFailedDownloads"])
    }

    func testEditAndSaveSendsWholeResource() async throws {
        var p = try provider()
        p.setField("port", JSONValue(9090))
        p.setField("host", .string("qbit.streamero.net"))
        p.isEnabled = false
        p.setToggle("removeCompletedDownloads", false)
        let mock = MockTransport()
        mock.route("PUT", "/api/v3/downloadclient/3", json: try String(decoding: JSONEncoder().encode(p.raw), as: UTF8.self))
        let radarr = RadarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .radarr, apiKey: "k"), transport: mock))
        let saved = try await radarr.save(p, in: .downloadClient)
        XCTAssertFalse(saved.isEnabled)
        let body = try XCTUnwrap(mock.last?.bodyJSON)
        let fields = try XCTUnwrap(body["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first { $0["name"] as? String == "port" }?["value"] as? Int, 9090)
        XCTAssertEqual(fields.first { $0["name"] as? String == "host" }?["value"] as? String, "qbit.streamero.net")
        XCTAssertEqual(fields.first { $0["name"] as? String == "port" }?["label"] as? String, "Port", "field definitions are preserved")
        XCTAssertEqual(body["configContract"] as? String, "QBittorrentSettings")
        XCTAssertEqual(body["removeCompletedDownloads"] as? Bool, false)
    }

    func testNewProviderFromSchemaIsPosted() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/notification/schema", json: #"[{"id":0,"name":"","implementation":"Discord","implementationName":"Discord","onGrab":false,"supportsOnGrab":true,"onDownload":false,"supportsOnDownload":true,"onHealthIssue":false,"supportsOnHealthIssue":false,"fields":[{"name":"webHookUrl","label":"Webhook URL","type":"url","value":null}]}]"#)
        mock.route("POST", "/api/v3/notification", json: #"{"id":7,"name":"Discord"}"#)
        let sonarr = SonarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .sonarr, apiKey: "k"), transport: mock))
        var template = try await XCTUnwrapAsync(await sonarr.providerSchemas(.notification).first)
        XCTAssertTrue(template.isNew)
        XCTAssertEqual(template.toggles.map(\.key), ["onDownload", "onGrab"], "unsupported triggers are hidden")
        template.name = "Discord"
        template.setField("webHookUrl", .string("https://discord.test/hook"))
        template.setToggle("onGrab", true)
        let saved = try await sonarr.save(template, in: .notification)
        XCTAssertEqual(saved.id, 7)
        XCTAssertEqual(mock.last?.httpMethod, "POST")
        XCTAssertNil(mock.last?.bodyJSON?["id"], "new providers are created without an id")
        XCTAssertEqual(mock.last?.bodyJSON?["onGrab"] as? Bool, true)
        XCTAssertEqual(ProviderResource.available(for: .prowlarr).first, .indexer)
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

final class ArrSystemTests: XCTestCase {
    func testReleasesRejectionsInBothFormatsAndGrab() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v3/release", json: #"""
        [{"guid":"g1","indexerId":2,"indexer":"Example","title":"Severance.S02E03.1080p.WEB","size":2147483648,"quality":{"quality":{"name":"WEBDL-1080p"}},"ageHours":30.5,"seeders":50,"approved":true,"rejected":false,"rejections":[],"customFormatScore":15,"languages":[{"id":1,"name":"English"}],"protocol":"torrent"},
         {"guid":"g2","indexerId":2,"title":"Severance.S02E03.720p","approved":false,"rejections":["720p is not wanted in profile"]},
         {"guid":"g3","indexerId":3,"title":"Severance.S02E03.CAM","approved":false,"rejections":[{"reason":"Quality is below cutoff","type":"permanent"}]}]
        """#)
        mock.route("POST", "/api/v3/release", json: "{}")
        let sonarr = SonarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .sonarr, apiKey: "k"), transport: mock))
        let releases = try await sonarr.releases(for: .episode(501))
        XCTAssertEqual(mock.last?.query("episodeId"), ["501"])
        XCTAssertEqual(releases[0].quality, "WEBDL-1080p")
        XCTAssertEqual(releases[0].ageText, "30h")
        XCTAssertEqual(releases[0].languages, ["English"])
        XCTAssertEqual(releases[1].rejections, ["720p is not wanted in profile"])
        XCTAssertEqual(releases[2].rejections, ["Quality is below cutoff"])
        try await sonarr.grab(releases[0])
        XCTAssertEqual(mock.last?.bodyJSON?["guid"] as? String, "g1")
        XCTAssertEqual(mock.last?.bodyJSON?["indexerId"] as? Int, 2)
        _ = try await sonarr.releases(for: .season(seriesId: 12, season: 2))
        XCTAssertEqual(mock.last?.query("seasonNumber"), ["2"])
    }

    func testQualityProfileAndItemEdit() throws {
        let profileJSON = #"{"id":4,"name":"HD-1080p","upgradeAllowed":true,"cutoff":7,"items":[{"quality":{"id":4,"name":"HDTV-720p"},"allowed":false},{"quality":{"id":7,"name":"Bluray-1080p"},"allowed":true},{"name":"WEB 1080p","id":1001,"allowed":true,"items":[{"quality":{"id":3,"name":"WEBDL-1080p"}},{"quality":{"id":15,"name":"WEBRip-1080p"}}]}]}"#
        let profile = QualityProfileDetail(raw: try JSONDecoder().decode(JSONValue.self, from: Data(profileJSON.utf8)))
        XCTAssertEqual(profile.allowed, ["WEB 1080p (WEBDL-1080p, WEBRip-1080p)", "Bluray-1080p"])
        XCTAssertEqual(profile.cutoff, "Bluray-1080p")

        var raw = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":12,"monitored":true,"qualityProfileId":4,"tags":[1],"seriesType":"standard","seasonFolder":true,"seasons":[{"seasonNumber":1,"monitored":true},{"seasonNumber":2,"monitored":false}],"alternateTitles":[]}"#.utf8))
        var edit = ItemEdit(raw: raw)
        XCTAssertEqual(edit.monitoredSeasons, [1: true, 2: false])
        edit.qualityProfileId = 6
        edit.tags = [1, 3]
        edit.seriesType = "anime"
        edit.monitoredSeasons[2] = true
        edit.apply(to: &raw)
        XCTAssertEqual(raw["qualityProfileId"]?.intValue, 6)
        XCTAssertEqual(raw["tags"]?.arrayValue?.compactMap(\.intValue), [1, 3])
        XCTAssertEqual(raw["seriesType"]?.stringValue, "anime")
        XCTAssertEqual(raw["seasons"]?.arrayValue?.last?["monitored"]?.boolValue, true)
        XCTAssertNotNil(raw["alternateTitles"])
    }

    func testTasksBackupsLogs() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v1/system/task", json: #"[{"id":1,"name":"Check Health","taskName":"CheckHealth","interval":360,"lastExecution":"2026-10-28T06:00:00Z","nextExecution":"2026-10-28T12:00:00Z"}]"#)
        mock.route("POST", "/api/v1/command", json: #"{"id":5,"name":"CheckHealth"}"#)
        mock.route("GET", "/api/v1/log", json: #"{"page":1,"pageSize":100,"totalRecords":1,"records":[{"id":9,"time":"2026-10-28T09:00:00Z","level":"warn","logger":"IndexerStatusCheck","message":"Indexers unavailable"}]}"#)
        let prowlarr = ProwlarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .prowlarr, apiKey: "k"), transport: mock))
        let tasks = try await prowlarr.tasks()
        try await prowlarr.run(tasks[0])
        XCTAssertEqual(mock.last?.bodyJSON?["name"] as? String, "CheckHealth")
        let logs = try await prowlarr.logs(level: "warn")
        XCTAssertEqual(mock.last?.query("level"), ["warn"])
        XCTAssertEqual(logs.records.first?.message, "Indexers unavailable")
    }
}

final class DownloadClientTests: XCTestCase {
    func testQBittorrentSignsInOnceAndFallsBackToPause() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api/v2/torrents/info", status: 403, json: "Forbidden")
        mock.route("POST", "/api/v2/auth/login", json: "Ok.")
        let instance = ServiceInstance(kind: .qbittorrent, apiKey: "pw", username: "admin")
        let qbit = QBittorrentClient(client: try ServiceClients.client(for: instance, transport: mock), username: "admin", password: "pw")
        do { _ = try await qbit.torrents(); XCTFail("still forbidden after login") } catch { XCTAssertEqual(error as? ServiceError, .unauthorized) }
        let login = try XCTUnwrap(mock.requests.first { $0.url?.path == "/api/v2/auth/login" })
        XCTAssertEqual(String(decoding: login.httpBody ?? Data(), as: UTF8.self), "password=pw&username=admin")
        XCTAssertEqual(login.value(forHTTPHeaderField: "Content-Type"), Form.contentType)
        XCTAssertEqual(login.value(forHTTPHeaderField: "Referer"), "https://qbit.streamero.net")

        mock.route("GET", "/api/v2/torrents/info", json: #"[{"hash":"abc","name":"Big Buck Bunny","size":1000,"progress":0.5,"dlspeed":2048,"upspeed":0,"eta":3700,"state":"downloading","category":"radarr","ratio":0.1,"added_on":1761600000,"num_seeds":10,"num_leechs":2,"save_path":"/downloads"}]"#)
        let torrents = try await qbit.torrents(filter: .downloading)
        XCTAssertEqual(torrents.first?.stateTitle, "Downloading")
        XCTAssertEqual(torrents.first?.etaText, "1h 1m")
        XCTAssertEqual(mock.last?.query("filter"), ["downloading"])

        mock.route("POST", "/api/v2/torrents/pause", json: "")
        try await qbit.pause(["abc", "def"])
        XCTAssertEqual(mock.last?.url?.path, "/api/v2/torrents/pause", "qBittorrent 4 has no /stop")
        XCTAssertEqual(String(decoding: mock.last?.httpBody ?? Data(), as: UTF8.self), "hashes=abc%7Cdef")
        mock.route("POST", "/api/v2/auth/login", json: "Fails.")
        mock.routes["GET /api/v2/app/version"] = (403, Data())
        do { _ = try await qbit.version(); XCTFail() } catch { XCTAssertEqual(error as? ServiceError, .unauthorized, "wrong password is reported") }
    }

    func testSabnzbdQueueAndKeyErrors() async throws {
        let mock = MockTransport()
        mock.route("GET", "/api", json: #"{"queue":{"status":"Downloading","paused":false,"speed":"12.3 M","kbpersec":"12595.2","sizeleft":"1.2 GB","timeleft":"0:01:40","slots":[{"nzo_id":"SABnzbd_nzo_1","filename":"Severance.S02E03","percentage":"42","mb":"2048.0","mbleft":"1187.8","timeleft":"0:01:40","status":"Downloading","cat":"tv"}]}}"#)
        let sab = SabnzbdClient(client: try ServiceClients.client(for: ServiceInstance(kind: .sabnzbd, apiKey: "sabkey"), transport: mock))
        let queue = try await sab.queue()
        XCTAssertEqual(queue.slots.first?.progress ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(mock.last?.query("apikey"), ["sabkey"])
        XCTAssertEqual(mock.last?.query("mode"), ["queue"])
        XCTAssertEqual(mock.last?.query("output"), ["json"])
        mock.route("GET", "/api", json: #"{"status":false,"error":"API Key Incorrect"}"#)
        do { _ = try await sab.queue(); XCTFail() } catch { XCTAssertEqual(error as? ServiceError, .unauthorized) }
    }
}

final class AdminExtrasTests: XCTestCase {
    func testJellyfinPolicyLibrariesAndPermissions() async throws {
        let mock = MockTransport()
        mock.route("GET", "/Users/u2", json: #"{"Id":"u2","Name":"guest","Policy":{"IsAdministrator":false,"EnableAllFolders":true,"EnabledFolders":[],"EnableRemoteAccess":true,"MaxActiveSessions":0,"AuthenticationProviderId":"x"}}"#)
        mock.route("POST", "/Users/u2/Policy", json: "")
        let jellyfin = JellyfinClient(client: try ServiceClients.client(for: ServiceInstance(kind: .jellyfin, apiKey: "t"), transport: mock))
        var policy = try await jellyfin.policy(userId: "u2")
        XCTAssertTrue(policy.allLibraries)
        policy.allLibraries = false
        policy.enabledLibraries = ["lib-movies", "lib-tv"]
        policy.set(.enableRemoteAccess, false)
        policy.maxActiveSessions = 2
        try await jellyfin.save(policy, userId: "u2")
        let body = try XCTUnwrap(mock.last?.bodyJSON)
        XCTAssertEqual(body["EnableAllFolders"] as? Bool, false)
        XCTAssertEqual(body["EnabledFolders"] as? [String], ["lib-movies", "lib-tv"])
        XCTAssertEqual(body["EnableRemoteAccess"] as? Bool, false)
        XCTAssertEqual(body["MaxActiveSessions"] as? Int, 2)
        XCTAssertEqual(body["AuthenticationProviderId"] as? String, "x")

        mock.route("POST", "/Library/VirtualFolders", json: "")
        try await jellyfin.addLibrary(name: "4K Movies", type: .movies, paths: ["/media/4k", "/media/4k2"])
        XCTAssertEqual(mock.last?.query("paths"), ["/media/4k", "/media/4k2"])
        XCTAssertEqual(mock.last?.query("collectionType"), ["movies"])
    }

    func testSeerrPermissionsAndBazarrManualSearch() async throws {
        var permissions = SeerrPermissions(rawValue: 32 | 128)
        XCTAssertTrue(permissions.contains(.request))
        XCTAssertTrue(permissions.contains(.autoApprove))
        permissions.insert(.manageRequests)
        permissions.remove(.autoApprove)
        XCTAssertEqual(permissions.rawValue, 48)

        let mock = MockTransport()
        mock.route("GET", "/api/providers/episodes", json: #"{"data":[{"provider":"opensubtitlescom","subtitle":"opensubtitlescom|123","language":"hr","score":"95.8%","release_info":["Severance.S02E03.1080p.WEB"],"uploader":"x","hearing_impaired":"False","forced":"False","original_format":"False"}]}"#)
        mock.route("POST", "/api/providers/episodes", json: "")
        let bazarr = BazarrClient(client: try ServiceClients.client(for: ServiceInstance(kind: .bazarr, apiKey: "k"), transport: mock))
        let candidates = try await bazarr.searchSubtitles(episodeId: 501)
        XCTAssertEqual(candidates.first?.score, "95.8%")
        XCTAssertFalse(candidates.first?.hearingImpaired ?? true)
        try await bazarr.download(candidates[0], seriesId: 12, episodeId: 501)
        XCTAssertEqual(mock.last?.query("subtitle"), ["opensubtitlescom|123"])
        XCTAssertEqual(mock.last?.query("provider"), ["opensubtitlescom"])
        XCTAssertEqual(mock.last?.query("seriesid"), ["12"])
    }
}
