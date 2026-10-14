import Foundation

enum TorrentFixture {
    static let torrents: [TorrentSummary] = [
        TorrentSummary(
            id: "8f14e45fceea167a5a36dedd4bea2543",
            name: "ubuntu-26.04-desktop-amd64.iso",
            status: .downloading,
            progress: 0.42,
            size: 5_100_000_000,
            downloadSpeed: 2_100_000,
            uploadSpeed: 120_000,
            eta: 1_800,
            timeActive: 8040,
            category: "linux",
            tags: ["distro"]
        ),
        TorrentSummary(
            id: "c9f0f895fb98ab9159f51fd0297e236d",
            name: "LinuxMint-23.1-cinnamon-64bit.iso",
            status: .seeding,
            progress: 1,
            size: 2_900_000_000,
            downloadSpeed: 0,
            uploadSpeed: 340_000,
            eta: nil,
            timeActive: 273600,
            category: "linux",
            tags: ["distro"]
        ),
        TorrentSummary(
            id: "45c48cce2e2d7fbdea1afc51c7c6ad26",
            name: "archlinux-2026.10.01-x86_64.iso",
            status: .completed,
            progress: 1,
            size: 1_200_000_000,
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            timeActive: 720,
            category: "linux",
            tags: ["distro"]
        ),
        TorrentSummary(
            id: "d3d9446802a44259755d38e6d163e820",
            name: "debian-13-netinst-amd64.iso",
            status: .stopped,
            progress: 0.15,
            size: 410_000_000,
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            timeActive: 42,
            category: "linux",
            tags: []
        ),
        TorrentSummary(
            id: "6512b4f97a3dad783b37359ca2e301b0",
            name: "Fedora-Workstation-Live-x86_64-43-1.6.iso",
            status: .stalled,
            progress: 0.67,
            size: 4_200_000_000,
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            timeActive: 3900,
            category: "linux",
            tags: ["distro"]
        ),
        TorrentSummary(
            id: "c20ad4d76fe97759aa27a0c99bff6710",
            name: "openSUSE-Leap-16.0-DVD-x86_64.iso",
            status: .downloading,
            progress: 0.9,
            size: 3_800_000_000,
            downloadSpeed: 5_400_000,
            uploadSpeed: 12_000,
            eta: 120,
            timeActive: 3312,
            category: "linux",
            tags: []
        ),
        TorrentSummary(
            id: "c51ce410c124a10e0db5e4b97fc2af39",
            name: "Some.very.long.release.name.2026.1080p.x265.REMUX.MULTI-VENOM-TRiToN",
            status: .seeding,
            progress: 1,
            size: 18_400_000_000,
            downloadSpeed: 0,
            uploadSpeed: 890_000,
            eta: nil,
            timeActive: 525600,
            category: nil,
            tags: ["home"]
        ),
        TorrentSummary(
            id: "aab3238922bcc25a6f606eb525ffdc56",
            name: "alpine-extended-3.22.0-x86_64.iso",
            status: .downloading,
            progress: 0.05,
            size: 200_000_000,
            downloadSpeed: 890_000,
            uploadSpeed: 0,
            eta: 180,
            timeActive: 200,
            category: "linux",
            tags: ["small", "test"]
        )
    ]

    static func details(for torrent: TorrentSummary) -> TorrentDetails {
        let seed = Int(torrent.id.prefix(8), radix: 16) ?? 0
        let piecesTotal = max(1, Int(torrent.size / (16 * 1024 * 1024)))
        let piecesHave = Int(Double(piecesTotal) * torrent.progress + 0.5)
        let addedOn = Date(timeIntervalSince1970: 1_770_000_000 + Double(seed % 100_000))
        let downloaded = Int64(Double(torrent.size) * torrent.progress)
        let uploaded = torrent.progress >= 1
            ? torrent.size / Int64(5 + seed % 5)
            : torrent.size / 100

        let general = GeneralInfo(
            hash: torrent.id,
            savePath: "/Users/genius/Downloads\(torrent.category.map { "/\($0)" } ?? "")",
            addedOn: addedOn,
            completedOn: torrent.progress >= 1 ? addedOn.addingTimeInterval(torrent.timeActive) : nil,
            comment: torrent.tags.contains("distro") ? "Official Linux distribution image" : "",
            downloaded: downloaded,
            uploaded: uploaded,
            piecesTotal: piecesTotal,
            piecesHave: piecesHave
        )

        return TorrentDetails(
            general: general,
            trackers: trackers(for: torrent),
            peers: peers(for: torrent),
            webSeeds: webSeeds(for: torrent),
            files: files(for: torrent)
        )
    }

    private static func trackers(for torrent: TorrentSummary) -> [TrackerRow] {
        switch torrent.status {
        case .stopped:
            return [
                TrackerRow(
                    url: "udp://tracker.example.org:1337/announce",
                    status: "Disabled",
                    peers: 0, seeds: 0, leeches: 0,
                    downloaded: 0
                )
            ]
        case .downloading:
            return [
                TrackerRow(
                    url: "udp://tracker.example.org:1337/announce",
                    status: "Working",
                    peers: 42, seeds: 18, leeches: 24,
                    downloaded: torrent.size / 3
                ),
                TrackerRow(
                    url: "https://tracker.example.com/announce",
                    status: "Working",
                    peers: 31, seeds: 12, leeches: 19,
                    downloaded: torrent.size / 4
                ),
                TrackerRow(
                    url: "udp://open.stealth.si:80/announce",
                    status: "Not working",
                    peers: 0, seeds: 0, leeches: 0,
                    downloaded: 0
                )
            ]
        case .seeding:
            return [
                TrackerRow(
                    url: "udp://tracker.example.org:1337/announce",
                    status: "Working",
                    peers: 12, seeds: 12, leeches: 0,
                    downloaded: torrent.size
                ),
                TrackerRow(
                    url: "https://tracker.example.com/announce",
                    status: "Working",
                    peers: 8, seeds: 8, leeches: 0,
                    downloaded: torrent.size / 2
                )
            ]
        case .completed:
            return [
                TrackerRow(
                    url: "udp://tracker.example.org:1337/announce",
                    status: "Working",
                    peers: 3, seeds: 3, leeches: 0,
                    downloaded: torrent.size
                ),
                TrackerRow(
                    url: "https://tracker.example.com/announce",
                    status: "Not contacted yet",
                    peers: 0, seeds: 0, leeches: 0,
                    downloaded: 0
                )
            ]
        case .stalled:
            return [
                TrackerRow(
                    url: "udp://tracker.example.org:1337/announce",
                    status: "Working",
                    peers: 0, seeds: 0, leeches: 0,
                    downloaded: torrent.size / 2
                ),
                TrackerRow(
                    url: "udp://open.stealth.si:80/announce",
                    status: "Not working",
                    peers: 0, seeds: 0, leeches: 0,
                    downloaded: 0
                )
            ]
        }
    }

    private static func peers(for torrent: TorrentSummary) -> [PeerRow] {
        switch torrent.status {
        case .downloading:
            return [
                PeerRow(ip: "192.168.1.42:6881", client: "qBittorrent 5.3.0", flags: "D U", connection: "μTP", progress: 0.68, downSpeed: 1_400_000, upSpeed: 40_000),
                PeerRow(ip: "10.0.0.7:51413", client: "Transmission 4.0.6", flags: "d x", connection: "BT", progress: 0.31, downSpeed: 420_000, upSpeed: 12_000),
                PeerRow(ip: "172.16.5.9:14567", client: "Deluge 2.1.1", flags: "D", connection: "μTP", progress: 0.91, downSpeed: 190_000, upSpeed: 0),
                PeerRow(ip: "203.0.113.88:6889", client: "libtorrent 2.0.10", flags: "d U", connection: "BT", progress: 0.14, downSpeed: 90_000, upSpeed: 68_000)
            ]
        case .seeding:
            return [
                PeerRow(ip: "192.168.1.77:6881", client: "qBittorrent 5.3.0", flags: "u x", connection: "μTP", progress: 1.0, downSpeed: 0, upSpeed: 260_000),
                PeerRow(ip: "198.51.100.23:51413", client: "Transmission 4.0.6", flags: "U", connection: "BT", progress: 1.0, downSpeed: 0, upSpeed: 80_000)
            ]
        case .completed, .stopped, .stalled:
            return []
        }
    }

    private static func webSeeds(for torrent: TorrentSummary) -> [WebSeedRow] {
        switch torrent.status {
        case .downloading:
            return [
                WebSeedRow(url: "https://releases.example.org/\(torrent.name)"),
                WebSeedRow(url: "https://mirror.example.net/linux/\(torrent.name)")
            ]
        case .seeding, .completed:
            return [WebSeedRow(url: "https://releases.example.org/\(torrent.name)")]
        case .stopped, .stalled:
            return []
        }
    }

    private static func files(for torrent: TorrentSummary) -> [FileRow] {
        if torrent.name.hasPrefix("Some.very.long.release") {
            let video = torrent.size * 96 / 100
            let subtitle = torrent.size * 3 / 1000
            let nfo = torrent.size - video - subtitle
            return [
                FileRow(name: "release.mkv", size: video, progress: torrent.progress, priority: .maximum),
                FileRow(name: "release.en.srt", size: subtitle, progress: torrent.progress, priority: .high),
                FileRow(name: "release.nfo", size: nfo, progress: min(1, torrent.progress * 2), priority: .normal)
            ]
        }
        if torrent.name.hasPrefix("Fedora-Workstation") {
            let main = torrent.size * 95 / 100
            let boot = torrent.size * 4 / 100
            let checksums = torrent.size / 200
            let license = torrent.size - main - boot - checksums
            return [
                FileRow(name: "\(torrent.name)/images/boot.iso", size: boot, progress: torrent.progress, priority: .high),
                FileRow(name: "\(torrent.name)/images/live.iso", size: main, progress: torrent.progress, priority: .maximum),
                FileRow(name: "\(torrent.name)/CHECKSUM", size: checksums, progress: torrent.progress, priority: .normal),
                FileRow(name: "\(torrent.name)/LICENSE", size: license, progress: torrent.progress, priority: .low)
            ]
        }
        if torrent.status == .stopped {
            return [
                FileRow(name: torrent.name, size: torrent.size, progress: torrent.progress, priority: .low)
            ]
        }
        return [
            FileRow(name: torrent.name, size: torrent.size, progress: torrent.progress, priority: .normal)
        ]
    }
}

final class MockTorrentProvider: TorrentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var added: [TorrentSummary] = []

    func loadTorrents() -> [TorrentSummary] {
        lock.lock()
        defer { lock.unlock() }
        return added + TorrentFixture.torrents
    }

    func loadDetails(for id: String) -> TorrentDetails {
        lock.lock()
        let addedCopy = added
        lock.unlock()
        if let torrent = addedCopy.first(where: { $0.id == id }) {
            return TorrentFixture.details(for: torrent)
        }
        guard let torrent = TorrentFixture.torrents.first(where: { $0.id == id }) else {
            return TorrentFixture.details(for: TorrentFixture.torrents[0])
        }
        return TorrentFixture.details(for: torrent)
    }

    func addTorrent(source: AddSource, savePath: String) -> TorrentSummary {
        let id = "add-" + UUID().uuidString.prefix(8)
        var name = "New torrent"
        var declaredSize: Int64?
        switch source {
        case .magnetOrURL(let string):
            let components = URLComponents(string: string)
            if let dn = components?.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty {
                let plusDecoded = dn.replacingOccurrences(of: "+", with: " ")
                name = plusDecoded.removingPercentEncoding ?? plusDecoded
            } else if let path = components?.path, !path.isEmpty, path != "/" {
                name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            } else if let host = components?.host, !host.isEmpty {
                name = host
            }
            if let xl = components?.queryItems?.first(where: { $0.name == "xl" })?.value,
               let bytes = Int64(xl) {
                declaredSize = bytes
            }
        case .torrentFile(let url):
            name = url.deletingPathExtension().lastPathComponent
        }
        let torrent = TorrentSummary(
            id: String(id),
            name: name,
            status: .downloading,
            progress: 0,
            size: declaredSize ?? Self.seededSize(for: String(id)),
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            tags: []
        )
        lock.lock()
        added.insert(torrent, at: 0)
        lock.unlock()
        return torrent
    }

    /// Deterministic per id (stable across refreshes within a run).
    private static func seededSize(for id: String) -> Int64 {
        500_000_000 + Int64(id.hashValue.magnitude % 3_500_000_000)
    }
}
