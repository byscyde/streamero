import AVFoundation
import Foundation
import Observation
import StreameroCore
import SwiftData

@Model
final class DownloadRecord {
    enum State: String, Codable { case queued, downloading, paused, verifying, completed, failed }

    @Attribute(.unique) var itemKey: String // "track:<id>" or "video:<id>"
    var kind: String
    var itemId: String
    var title: String
    var subtitle: String
    var artworkURLString: String?
    var grantId: String?
    var profile: String?
    var codec: String?
    var lossless: Bool
    var expectedBytes: Int64
    var checksum: String?
    var stateRaw: String
    var progress: Double
    var localPath: String?
    var licenseExpiresAt: Date?
    var createdAt: Date
    var resumeData: Data?
    var errorMessage: String?
    var payload: Data? // encoded Track or Video for offline rendering
    var subtitlePaths: [String] = []

    init(kind: String, itemId: String, title: String, subtitle: String, artworkURL: URL?, payload: Data?) {
        self.itemKey = "\(kind):\(itemId)"
        self.kind = kind
        self.itemId = itemId
        self.title = title
        self.subtitle = subtitle
        self.artworkURLString = artworkURL?.absoluteString
        self.lossless = false
        self.expectedBytes = 0
        self.stateRaw = State.queued.rawValue
        self.progress = 0
        self.createdAt = Date()
        self.payload = payload
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    var artworkURL: URL? { artworkURLString.flatMap(URL.init(string:)) }
    var track: Track? { kind == "track" ? payload.flatMap { try? JSONDecoder.streamero.decode(Track.self, from: $0) } : nil }
    var video: Video? { kind == "video" ? payload.flatMap { try? JSONDecoder.streamero.decode(Video.self, from: $0) } : nil }
    var isLicenseValid: Bool { (licenseExpiresAt ?? .distantPast) > Date() }
}

struct LocalDownload {
    var url: URL
    var profile: StreamProfile?
    var codec: String?
    var lossless: Bool
}

/// Offline downloads. Entitlement is decided by the server (download grants); the device keeps an
/// offline licence that is renewed when online and deletes files the server reports as revoked.
@MainActor
@Observable
final class DownloadManager: NSObject {
    private(set) var records: [DownloadRecord] = []
    private(set) var usedBytes: Int64 = 0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private var assetSession: AVAssetDownloadURLSession!
    @ObservationIgnored private var tasks: [String: URLSessionTask] = [:]
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var delegateProxy: DownloadDelegate?

    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true // re-downloadable content stays out of iCloud backups
        var mutable = url
        try? mutable.setResourceValues(values)
        return url
    }()

    init(container: ModelContainer, settings: SettingsStore) {
        self.context = ModelContext(container)
        self.settings = settings
        super.init()
        let proxy = DownloadDelegate(owner: self)
        delegateProxy = proxy
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.scyde.streamero.downloads.files")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        fileSession = URLSession(configuration: cfg, delegate: proxy, delegateQueue: .main)
        let assetCfg = URLSessionConfiguration.background(withIdentifier: "com.scyde.streamero.downloads.assets")
        assetSession = AVAssetDownloadURLSession(configuration: assetCfg, assetDownloadDelegate: proxy, delegateQueue: .main)
        reload()
        // Interrupted while the app was suspended/killed: those tasks are still owned by the background session.
        fileSession.getAllTasks { [weak self] list in
            Task { @MainActor in for t in list { if let key = t.taskDescription { self?.tasks[key] = t } } }
        }
    }

    func attach(api: APIClient?) { self.api = api }

    // MARK: Queries

    func reload() {
        records = (try? context.fetch(FetchDescriptor<DownloadRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        usedBytes = records.reduce(0) { $0 + (fileSize($1) ?? 0) }
    }

    func record(_ kind: String, _ id: String) -> DownloadRecord? { records.first { $0.itemKey == "\(kind):\(id)" } }

    func localFile(forTrack id: String) -> LocalDownload? {
        guard let r = record("track", id), r.state == .completed, r.isLicenseValid, let path = r.localPath else { return nil }
        let url = Self.directory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return LocalDownload(url: url, profile: r.profile.flatMap(StreamProfile.init(rawValue:)), codec: r.codec, lossless: r.lossless)
    }

    func localVideo(_ id: String) -> (asset: URL, subtitles: [URL])? {
        guard let r = record("video", id), r.state == .completed, r.isLicenseValid, let path = r.localPath else { return nil }
        let url = Self.directory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, r.subtitlePaths.map { Self.directory.appendingPathComponent($0) })
    }

    var completedTracks: [Track] { records.filter { $0.state == .completed && $0.kind == "track" && $0.isLicenseValid }.compactMap(\.track) }

    private func fileSize(_ r: DownloadRecord) -> Int64? {
        guard let p = r.localPath else { return nil }
        let url = Self.directory.appendingPathComponent(p)
        if r.kind == "video" { return directorySize(url) }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    // MARK: Commands

    func download(track: Track) async {
        guard track.downloadable, record("track", track.id)?.state != .completed else { return }
        let r = record("track", track.id) ?? insert(kind: "track", id: track.id, title: track.title, subtitle: track.artist.name, art: track.artworkUrl, payload: try? JSONEncoder.streamero.encode(track))
        await start(r)
    }

    func download(tracks: [Track]) async {
        for t in tracks where t.downloadable { await download(track: t) }
    }

    func download(video: Video) async {
        guard video.downloadable, record("video", video.id)?.state != .completed else { return }
        let r = record("video", video.id) ?? insert(kind: "video", id: video.id, title: video.title, subtitle: video.artist?.name ?? "Video", art: video.thumbnailUrl, payload: try? JSONEncoder.streamero.encode(video))
        await start(r)
    }

    private func insert(kind: String, id: String, title: String, subtitle: String, art: URL?, payload: Data?) -> DownloadRecord {
        let r = DownloadRecord(kind: kind, itemId: id, title: title, subtitle: subtitle, artworkURL: art, payload: payload)
        context.insert(r)
        save()
        return r
    }

    private func start(_ r: DownloadRecord) async {
        guard let api else { return }
        r.state = .queued
        r.errorMessage = nil
        save()
        do {
            if r.kind == "track" {
                if let data = r.resumeData {
                    r.resumeData = nil
                    launch(fileSession.downloadTask(withResumeData: data), for: r)
                    return
                }
                let grant = try await api.requestDownload(trackId: r.itemId, profile: settings.values.quality.download)
                r.grantId = grant.grantId
                r.profile = grant.profile
                r.codec = grant.mimeType == "audio/mp4" ? (grant.lossless == true ? "alac" : "aac") : grant.mimeType
                r.lossless = grant.lossless ?? false
                r.expectedBytes = Int64(grant.sizeBytes ?? 0)
                r.checksum = grant.checksumSha256
                r.licenseExpiresAt = grant.licenseExpiresAt
                guard let url = grant.url else { throw APIError.decoding("missing url") }
                var req = URLRequest(url: url)
                req.allowsCellularAccess = settings.values.downloadOverCellular
                launch(fileSession.downloadTask(with: req), for: r)
            } else {
                let grant = try await api.requestVideoDownload(videoId: r.itemId)
                r.grantId = grant.grantId
                r.licenseExpiresAt = grant.licenseExpiresAt
                guard let hls = grant.hlsUrl else { throw APIError.decoding("missing hls url") }
                let asset = AVURLAsset(url: hls)
                let options: [String: Any] = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 2_000_000]
                guard let task = assetSession.makeAssetDownloadTask(asset: asset, assetTitle: r.title, assetArtworkData: nil, options: options) else {
                    throw APIError.network("Could not create download")
                }
                launch(task, for: r)
                await downloadSubtitles(for: r)
            }
        } catch {
            r.state = .failed
            r.errorMessage = error.localizedDescription
            save()
        }
    }

    private func launch(_ task: URLSessionTask, for r: DownloadRecord) {
        task.taskDescription = r.itemKey
        tasks[r.itemKey] = task
        r.state = .downloading
        save()
        task.resume()
    }

    /// Sidecar WebVTT files so the custom subtitle renderer works offline too.
    private func downloadSubtitles(for r: DownloadRecord) async {
        guard let api, let stream = try? await api.videoStream(r.itemId) else { return }
        var paths: [String] = []
        for s in stream.subtitles {
            guard let (data, _) = try? await URLSession.shared.data(from: s.vttUrl) else { continue }
            let rel = "subtitles-\(r.itemId)-\(s.language)-\(s.kind).vtt"
            try? data.write(to: Self.directory.appendingPathComponent(rel), options: .completeFileProtectionUntilFirstUserAuthentication)
            paths.append(rel)
        }
        r.subtitlePaths = paths
        save()
    }

    func pause(_ r: DownloadRecord) {
        guard let task = tasks[r.itemKey] else { return }
        if let dl = task as? URLSessionDownloadTask {
            dl.cancel { [weak self] data in
                Task { @MainActor in
                    r.resumeData = data
                    r.state = .paused
                    self?.save()
                }
            }
        } else {
            task.suspend()
            r.state = .paused
            save()
        }
    }

    func resume(_ r: DownloadRecord) {
        if let task = tasks[r.itemKey], task.state == .suspended {
            task.resume()
            r.state = .downloading
            save()
        } else {
            Task { await start(r) }
        }
    }

    func retry(_ r: DownloadRecord) { Task { await start(r) } }

    func delete(_ r: DownloadRecord) {
        tasks[r.itemKey]?.cancel()
        tasks[r.itemKey] = nil
        removeFiles(r)
        if let grant = r.grantId, let api { Task { try? await api.revokeDownload(grant) } }
        context.delete(r)
        save()
    }

    func deleteAll() {
        for r in records { delete(r) }
        try? FileManager.default.removeItem(at: Self.directory)
        _ = Self.directory
        reload()
    }

    private func removeFiles(_ r: DownloadRecord) {
        if let p = r.localPath { try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(p)) }
        for p in r.subtitlePaths { try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(p)) }
    }

    /// Renews licences and deletes downloads the server no longer authorises (revoked, removed from
    /// the catalog, or made non-downloadable).
    func validateWithServer() async {
        guard let api else { return }
        let ids = records.compactMap(\.grantId)
        guard !ids.isEmpty, let result = try? await api.validateDownloads(ids) else { return }
        let valid = Dictionary(uniqueKeysWithValues: result.valid.map { ($0.grantId, $0.licenseExpiresAt) })
        for r in records {
            guard let g = r.grantId else { continue }
            if let exp = valid[g] { r.licenseExpiresAt = exp }
            else if result.revoked.contains(g) {
                removeFiles(r)
                context.delete(r)
            }
        }
        save()
    }

    func save() {
        try? context.save()
        reload()
    }

    // MARK: Delegate callbacks (main queue)

    fileprivate func progress(key: String, fraction: Double) {
        guard let r = records.first(where: { $0.itemKey == key }) else { return }
        r.progress = fraction
        if r.state != .downloading { r.state = .downloading }
    }

    fileprivate func finishedFile(key: String, location: URL) {
        guard let r = records.first(where: { $0.itemKey == key }) else { return }
        let rel = "\(r.itemId).m4a"
        let dest = Self.directory.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            try (dest as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        } catch {
            r.state = .failed
            r.errorMessage = "Could not save the file"
            save()
            return
        }
        r.localPath = rel
        r.state = .verifying
        save()
        let expected = r.checksum
        Task.detached(priority: .utility) {
            let ok: Bool
            if let expected { ok = (try? SHA256Hasher.hex(ofFile: dest)) == expected } else { ok = FileManager.default.fileExists(atPath: dest.path) }
            await MainActor.run {
                if ok { r.state = .completed; r.progress = 1 } else {
                    try? FileManager.default.removeItem(at: dest)
                    r.localPath = nil
                    r.state = .failed
                    r.errorMessage = "Integrity check failed — tap to retry"
                }
                self.save()
            }
        }
    }

    fileprivate func finishedAsset(key: String, location: URL) {
        guard let r = records.first(where: { $0.itemKey == key }) else { return }
        // AVAssetDownloadTask stores packages under the app's Library; keep a path relative to our folder by moving it.
        let rel = "\(r.itemId).movpkg"
        let dest = Self.directory.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: location, to: dest) } catch {
            r.state = .failed
            r.errorMessage = "Could not save the video"
            save()
            return
        }
        r.localPath = rel
        r.state = .completed
        r.progress = 1
        save()
    }

    fileprivate func failed(key: String, error: Error?) {
        tasks[key] = nil
        guard let r = records.first(where: { $0.itemKey == key }) else { return }
        guard let error else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { r.resumeData = data }
        r.state = .failed
        r.errorMessage = ns.code == NSURLErrorNotConnectedToInternet ? "Waiting for network" : error.localizedDescription
        save()
    }
}

/// URLSession delegates are non-isolated; this proxy forwards to the main-actor manager.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    weak var owner: DownloadManager?
    init(owner: DownloadManager) { self.owner = owner }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { owner?.progress(key: key, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        // The temp file is deleted when this method returns: move it synchronously first.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: tmp)
        MainActor.assumeIsolated { owner?.finishedFile(key: key, location: tmp) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        MainActor.assumeIsolated { owner?.failed(key: key, error: error) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loaded: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let key = assetDownloadTask.taskDescription else { return }
        let done = loaded.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
        let fraction = timeRangeExpectedToLoad.duration.seconds > 0 ? done / timeRangeExpectedToLoad.duration.seconds : 0
        MainActor.assumeIsolated { owner?.progress(key: key, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = assetDownloadTask.taskDescription else { return }
        MainActor.assumeIsolated { owner?.finishedAsset(key: key, location: location) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            owner?.backgroundCompletion?()
            owner?.backgroundCompletion = nil
        }
    }
}
