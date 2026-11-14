import CryptoKit
import Foundation

/// Firmware releases published on GitHub (by tools/release.sh), kept in a
/// local cache so the app still works offline: lighting networks often have
/// no internet. Each release is cached as <cache>/<version>/<board>.uf2/.bin
/// plus release.json, which is what FirmwareLibrary reads.
enum ReleaseStore {
    static let repo = "voxeltheater/starboard-v1"

    /// The GitHub API listing. The "releasesAPI" default overrides it (tests).
    static var apiURL: URL {
        if let s = UserDefaults.standard.string(forKey: "releasesAPI"), let url = URL(string: s) { return url }
        return URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100")!
    }

    static var cache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Starboard Updater/releases", isDirectory: true)
    }

    struct Summary {
        var releases = 0
        var downloaded: [String] = []   // "1.4 rgb12.uf2"
        var removed: [String] = []      // versions withdrawn from GitHub
    }

    /// Brings the cache in line with GitHub. Withdrawals come first: releases
    /// deleted on GitHub, and files removed from a release, are deleted from
    /// the cache before anything downloads, so a pulled release can't stay
    /// flashable because a later download failed. Then new or changed files
    /// download, each checked against GitHub's size and sha256 before it
    /// replaces anything. Blocking; call off the main thread. Throws, leaving
    /// the cache untouched, if the release list can't be fetched; throws after
    /// syncing everything else if a download fails.
    static func sync(api: URL = apiURL, into cache: URL = cache) throws -> Summary {
        var request = URLRequest(url: api, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("StarboardUpdater", forHTTPHeaderField: "User-Agent")
        let data = try fetch(request)
        let releases: [GHRelease]
        do {
            releases = try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw FirmwareError("GitHub's release list wasn't readable.")
        }

        // What should be cached: version -> (release, [(asset, local file name)]).
        var wanted: [String: (GHRelease, [(GHAsset, String)])] = [:]
        for release in releases where !release.draft {
            guard let version = release.version else { continue }
            let assets = release.assets.compactMap { asset in asset.localName.map { (asset, $0) } }
            if !assets.isEmpty { wanted[version] = (release, assets) }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var summary = Summary(releases: wanted.count)

        // 1. Withdrawals.
        for version in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where !version.hasPrefix(".") {
            let dir = cache.appendingPathComponent(version)
            guard let (_, assets) = wanted[version] else {
                try? fm.removeItem(at: dir)
                summary.removed.append(version)
                continue
            }
            let names = Set(assets.map(\.1)).union([ReleaseInfo.file])
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !names.contains(file) {
                try? fm.removeItem(at: dir.appendingPathComponent(file))
            }
        }

        // 2. Downloads. One failure doesn't stop the other releases.
        var failures: [String] = []
        for (version, (release, assets)) in wanted.sorted(by: { $0.key < $1.key }) {
            let dir = cache.appendingPathComponent(version, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let info = ReleaseInfo(tag: release.tag_name, prerelease: release.prerelease,
                                   published: release.published_at)
            try JSONEncoder().encode(info).write(to: dir.appendingPathComponent(ReleaseInfo.file))
            for (asset, name) in assets {
                let dest = dir.appendingPathComponent(name)
                if matches(dest, asset) { continue }
                let part = dir.appendingPathComponent(name + ".part")
                defer { try? fm.removeItem(at: part) }
                do {
                    try fetch(URLRequest(url: asset.browser_download_url, timeoutInterval: 30)).write(to: part)
                    guard matches(part, asset) else {
                        throw FirmwareError("failed its size or checksum check")
                    }
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: part, to: dest)
                    summary.downloaded.append("\(version) \(name)")
                } catch {
                    // Don't leave an old copy that GitHub no longer matches.
                    try? fm.removeItem(at: dest)
                    failures.append("\(asset.name): \(error.localizedDescription)")
                }
            }
        }
        if !failures.isEmpty {
            throw FirmwareError("Some downloads failed (\(failures.joined(separator: "; ")))")
        }
        return summary
    }

    /// Does the file at `url` match what GitHub says the asset is?
    private static func matches(_ url: URL, _ asset: GHAsset) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count == asset.size else { return false }
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return "sha256:" + hex == digest.lowercased()
        }
        return true
    }

    private static func fetch(_ request: URLRequest) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(FirmwareError("No response from GitHub."))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let hint = http.statusCode == 403 || http.statusCode == 429 ? " (rate limited; try again later)" : ""
                result = .failure(FirmwareError("GitHub answered \(http.statusCode)\(hint)."))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private struct GHRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let published_at: String?
        let assets: [GHAsset]

        /// "v1.3" -> "1.3". Only plain version strings, since it becomes a folder name.
        var version: String? {
            let v = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
            let ok = !v.isEmpty && v.first!.isNumber
                && v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            return ok ? v : nil
        }
    }

    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let digest: String?

        /// "starboard-1.3-rgb12.uf2" -> "rgb12.uf2"; nil for anything else.
        var localName: String? {
            for board in BoardType.allCases {
                for ext in ["uf2", "bin"] where name == "\(board.fileStem).\(ext)" || name.hasSuffix("-\(board.fileStem).\(ext)") {
                    return "\(board.fileStem).\(ext)"
                }
            }
            return nil
        }
    }
}

/// release.json in each cached release folder.
struct ReleaseInfo: Codable {
    static let file = "release.json"
    let tag: String
    let prerelease: Bool
    let published: String?
}
