import Foundation

struct MockTorrentProvider: TorrentProviding {
    func loadTorrents() -> [TorrentSummary] {
        [
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
    }
}
