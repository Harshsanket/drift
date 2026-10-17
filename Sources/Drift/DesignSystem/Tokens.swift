import SwiftUI

enum DesignSystem {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
    }

    /// Shared geometry for the window chrome: the compact titlebar header,
    /// the separated capsule controls and the floating status bar.
    enum Metrics {
        /// Uniform height for every header control and the floating status bar.
        static let controlHeight: CGFloat = 32
        /// Breathing room above and below the header controls, so the capsules
        /// never sit flush against the window's top edge.
        static let headerPadding: CGFloat = 10
        /// The compact titlebar strip the header row lives in: the controls plus
        /// their padding, so the traffic lights, the sidebar toggle and the
        /// title read as one row.
        static let headerHeight: CGFloat = controlHeight + 2 * headerPadding
        /// What the system reserves for the hidden titlebar. The header draws
        /// over this band; only the remainder is pushed down onto the content.
        static let titlebarBand: CGFloat = 32
        /// Clears the standard traffic-light cluster (x 9…69) plus breathing room.
        static let trafficLightInset: CGFloat = 86
        static let statusBarHeight: CGFloat = 32
        /// Natural height of the details panel above the status bar. The panel
        /// is revealed by scaling this height with the model's animation
        /// progress, so the table viewport and its stripes retreat per frame.
        static let detailsPanelHeight: CGFloat = 265
        /// Torrent table geometry: SwiftUI's table cell hosting adds 8pt of
        /// style padding to cell content, so 4 + 18 + 4 (+ 8) = 34pt rows.
        static let tableRowHeight: CGFloat = 34
        static let tableCellHeight: CGFloat = 18
        static let tableCellVPad: CGFloat = 4
        static let tableCellHPad: CGFloat = 10
        static let iconSize: CGFloat = 14
        static let searchIconSize: CGFloat = 11
        static let titleSize: CGFloat = 15
        /// Gap between neighbouring standalone controls.
        static let controlGap: CGFloat = 10
        static let titleLeading: CGFloat = 12
        static let headerTrailing: CGFloat = 16
        static let hairline: CGFloat = 0.5
        /// Sidebar width assumed when working out how much header room is left.
        static let sidebarReserve: CGFloat = 220
        /// Floating status bar: margins measured from the main content edges.
        static let statusBarSideMargin: CGFloat = 14
        static let statusBarBottomMargin: CGFloat = 16
    }

    enum Palette {
        static let accent = Color.blue
        static let downloading = Color.blue
        static let seeding = Color.green
        static let completed = Color(red: 0.0, green: 0.32, blue: 0.64)
        static let stopped = Color.secondary
        static let stalled = Color.orange
        static let error = Color.red
        static let connectionOK = Color.green
        static let connectionDown = Color.red
    }

    enum Format {
        static func size(_ bytes: Int64) -> String {
            bytes.formatted(.byteCount(style: .memory))
        }

        static func speed(_ bytesPerSecond: Int64) -> String {
            guard bytesPerSecond > 0 else { return "0 B/s" }
            return bytesPerSecond.formatted(.byteCount(style: .memory)) + "/s"
        }

        static func eta(_ seconds: TimeInterval?) -> String {
            guard let seconds, seconds > 0, seconds < 100 * 3600 else { return "∞" }
            let total = Int(seconds)
            let h = total / 3600
            let m = (total % 3600) / 60
            if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
            let s = total % 60
            if m > 0 { return "\(m)m \(String(format: "%02d", s))s" }
            return "\(s)s"
        }

        /// Elapsed duration, e.g. "2h 14m", "18m 03s", "42s".
        static func duration(_ seconds: TimeInterval) -> String {
            guard seconds > 0 else { return "—" }
            let total = Int(seconds)
            let days = total / 86_400
            let hours = (total % 86_400) / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
            if minutes > 0 { return "\(minutes)m \(String(format: "%02d", secs))s" }
            return "\(secs)s"
        }

        static func percent(_ progress: Double) -> String {
            (progress * 100).formatted(.number.precision(.fractionLength(0))) + "%"
        }
    }
}
