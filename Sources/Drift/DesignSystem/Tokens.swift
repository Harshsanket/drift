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

    enum Palette {
        static let accent = Color.blue
        static let downloading = Color.blue
        static let seeding = Color.green
        static let completed = Color.gray
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

        static func percent(_ progress: Double) -> String {
            (progress * 100).formatted(.number.precision(.fractionLength(0))) + "%"
        }
    }
}
