import AppKit
import SpaceKitCore
import SwiftUI

/// Colors for the app. Palettes are validated for color-vision deficiency and contrast in both
/// appearances (see docs/DESIGN.md); don't eyeball replacements — re-run the validator.
enum Theme {
    /// A color with separate light and dark steps.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
    }

    /// Categorical hues in fixed order: blue, orange, aqua, yellow, magenta, green, violet, red.
    /// Assigned to entities in sequence, never cycled; a 9th entity folds into `other`.
    static let categorical: [Color] = [
        dynamic(light: 0x2a78d6, dark: 0x3987e5),
        dynamic(light: 0xeb6834, dark: 0xd95926),
        dynamic(light: 0x1baf7a, dark: 0x199e70),
        dynamic(light: 0xeda100, dark: 0xc98500),
        dynamic(light: 0xe87ba4, dark: 0xd55181),
        dynamic(light: 0x008300, dark: 0x008300),
        dynamic(light: 0x4a3aa7, dark: 0x9085e9),
        dynamic(light: 0xe34948, dark: 0xe66767),
    ]

    /// Folded / unclassified data.
    static let other = dynamic(light: 0xb5b3ab, dark: 0x5c5b56)

    static func categorical(_ index: Int) -> Color {
        index >= 0 && index < categorical.count ? categorical[index] : other
    }

    // Status — reserved meaning, always shown with an icon and a label.
    static let good = Color(nsColor: NSColor(hex: 0x0ca30c))
    static let warning = Color(nsColor: NSColor(hex: 0xfab219))
    static let critical = Color(nsColor: NSColor(hex: 0xd03b3b))

    static func color(for level: SafetyLevel) -> Color {
        switch level {
        case .safe: return good
        case .review: return warning
        case .protected: return critical
        }
    }

    static func symbol(for level: SafetyLevel) -> String {
        switch level {
        case .safe: return "arrow.triangle.2.circlepath.circle.fill"
        case .review: return "exclamationmark.circle.fill"
        case .protected: return "lock.circle.fill"
        }
    }

    /// Age buckets on a one-hue ordinal ramp: light → dark in light mode, dark → light in dark mode.
    static let ageBuckets: [(label: String, maxDays: Double, color: Color)] = [
        ("This week", 7, dynamic(light: 0x86b6ef, dark: 0x184f95)),
        ("This month", 30, dynamic(light: 0x5598e7, dark: 0x256abf)),
        ("Last 6 months", 182, dynamic(light: 0x2a78d6, dark: 0x3987e5)),
        ("Last year", 365, dynamic(light: 0x1c5cab, dark: 0x6da7ec)),
        ("Older", .infinity, dynamic(light: 0x104281, dark: 0x9ec5f4)),
    ]

    static func ageColor(_ date: Date?) -> Color {
        guard let date else { return other }
        let days = Date().timeIntervalSince(date) / 86_400
        return (ageBuckets.first { days < $0.maxDays } ?? ageBuckets[ageBuckets.count - 1]).color
    }

    /// Stable color per storage category (identity follows the category, never its rank).
    static func color(for category: StorageCategory) -> Color {
        switch category.id {
        case StorageCategory.developer.id: return categorical[0]
        case StorageCategory.applications.id: return categorical[1]
        case StorageCategory.ai.id: return categorical[2]
        case StorageCategory.documents.id: return categorical[3]
        case StorageCategory.media.id: return categorical[4]
        case StorageCategory.caches.id: return categorical[5]
        case StorageCategory.system.id: return categorical[6]
        case StorageCategory.systemData.id: return categorical[7]
        default: return other
        }
    }

    static let surface = dynamic(light: 0xfcfcfb, dark: 0x1a1a19)
    static let hairline = dynamic(light: 0xe1e0d9, dark: 0x2c2c2a)
    static let mutedInk = Color(nsColor: NSColor(hex: 0x898781))
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension UInt64 {
    var bytesText: String { ByteCount.format(self) }
}

// MARK: - Small shared components

/// Icon + label + color, so safety is never conveyed by color alone.
struct SafetyBadge: View {
    let level: SafetyLevel
    var compact = false

    var body: some View {
        Label {
            Text(level.title)
        } icon: {
            Image(systemName: Theme.symbol(for: level)).foregroundStyle(Theme.color(for: level))
        }
        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        .font(.caption.weight(.medium))
        .help("\(level.title) — risk: \(level.risk)")
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// A headline number with a label — the "hero figure" pattern.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(tint ?? .secondary) }
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 28, weight: .semibold)).contentTransition(.numericText())
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Used/total bar for a volume.
struct CapacityBar: View {
    let capacity: VolumeCapacity
    var height: CGFloat = 8

    var tint: Color {
        capacity.usedFraction > 0.9 ? Theme.critical : capacity.usedFraction > 0.8 ? Theme.warning : Theme.categorical[0]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * capacity.usedFraction))
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(capacity.name): \(capacity.used.bytesText) of \(capacity.total.bytesText) used")
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Card container used across sections.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

/// Banner shown when scans can't see privacy-protected folders.
struct FullDiskAccessBanner: View {
    let unreadable: UInt64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unreadable) protected folders couldn't be read").font(.callout.weight(.semibold))
                Text(
                    "macOS hides Mail, Messages, Safari and other apps' data unless SpaceKit has Full Disk Access. Their space shows as Hidden."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
        }
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Lays children out left to right, wrapping to new lines (for legends).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if extra > width && !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], extra, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
