import SwiftUI
import AppKit
import Charts
import MacVaultCore

// MacVault's design system. Every screen uses these tokens and components instead of one-off values.
// Visual direction: Documentation/DesignReferences (widget cards on a quiet canvas, large radius,
// big rounded numbers, pills, Swift Charts with rings, highlighted bars and average rules).

// MARK: - Tokens

/// 4-point spacing scale. Page content is inset `l` horizontally.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Radius {
    /// Cards and tiles.
    static let card: CGFloat = 18
    /// Banners, inner panels and treemap.
    static let inner: CGFloat = 10
    /// Icon squares and bars.
    static let small: CGFloat = 6
}

enum Dimensions {
    /// Every screen header has this height.
    static let headerHeight: CGFloat = 60
    /// Reading-heavy pages stay this wide at most.
    static let readableWidth: CGFloat = 1320
    /// The widget grid adds a column for every this much width (up to four).
    static let widgetColumnMinWidth: CGFloat = 250
    /// Lists that grow with use (history, problems, issues) scroll beyond this height.
    static let boundedListHeight: CGFloat = 160
    static let sheetWidth: CGFloat = 640
    /// Settings form width at most: the grouped form's ~700 pt column plus its own insets, so its
    /// sections line up with the screen header instead of floating in the middle.
    static let formWidth: CGFloat = 740
    /// Menu bar extra width.
    static let menuBarWidth: CGFloat = 320
    /// Size of the tinted icon square in screen headers.
    static let headerIcon: CGFloat = 32
    /// Ring of the volume capacity card and of the scan composition card.
    static let capacityRing: CGFloat = 136
    static let compositionRing: CGFloat = 168
    /// Width of the composition column next to a scan breakdown.
    static let compositionWidth: CGFloat = 248
    /// Totals column of summary cards, and the label column of category bars.
    static let summaryTotalsWidth: CGFloat = 200
    static let barLabelWidth: CGFloat = 128
    /// Search fields in screen headers.
    static let searchFieldWidth: CGFloat = 180
}

enum Motion {
    /// Short, restrained transition; nil when Reduce Motion is on.
    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }
}

// MARK: - Colour

/// One accent hue per feature (icons, charts, tiles), plus the canvas and card surfaces.
/// Hues are system colours, so they adapt to light and dark mode and to Increase Contrast.
enum Palette {
    static let storage = Color(nsColor: .systemBlue)
    static let analyzer = Color(nsColor: .systemIndigo)
    static let cleaner = Color(nsColor: .systemGreen)
    static let developer = Color(nsColor: .systemPurple)
    static let applications = Color(nsColor: .systemOrange)
    static let duplicates = Color(nsColor: .systemTeal)
    static let activity = Color(nsColor: .systemPink)
    static let settings = Color(nsColor: .systemGray)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)

    /// Series colours for rings and legends, in order.
    static let series: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemTeal),
        Color(nsColor: .systemOrange), Color(nsColor: .systemPink), Color(nsColor: .systemGreen),
        Color(nsColor: .systemYellow), Color(nsColor: .systemIndigo),
    ]
    /// "Other", remainders and unused capacity.
    static let neutral = Color.secondary.opacity(0.35)
    /// Empty part of bars and rings.
    static let track = Color.primary.opacity(0.07)

    /// Window canvas behind cards: soft grey in light mode, near-black in dark mode.
    static let canvas = dynamic(light: NSColor(white: 0.94, alpha: 1), dark: NSColor(white: 0.09, alpha: 1))
    /// Card surface: white in light mode, a raised near-black in dark mode.
    static let card = dynamic(light: .white, dark: NSColor(white: 0.155, alpha: 1))
    static let cardBorder = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07))
    /// Secondary text on a bold (tinted) card: at least 4.5:1 against every feature tint.
    static let onBoldSecondary = Color.white.opacity(0.9)
    static let cardShadow = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 0, alpha: 0.35))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension SidebarItem {
    var tint: Color {
        switch self {
        case .overview: return Palette.storage
        case .analyzer: return Palette.analyzer
        case .cleaner: return Palette.cleaner
        case .applications: return Palette.applications
        case .duplicates: return Palette.duplicates
        case .developer: return Palette.developer
        case .activity: return Palette.activity
        case .settings: return Palette.settings
        }
    }
}

// MARK: - Typography

/// The named type scale. Numbers use the rounded design with monospaced digits; paths are monospaced.
extension Font {
    /// Screen header title.
    static let pageTitle = Font.title2.weight(.bold)
    /// Card and section titles.
    static let cardTitle = Font.headline
    /// Row titles in lists.
    static let rowTitle = Font.callout.weight(.medium)
    /// The hero number of a card ("412 GB").
    static let heroNumber = Font.system(size: 40, weight: .bold, design: .rounded)
    static let heroUnit = Font.system(size: 20, weight: .semibold, design: .rounded)
    /// Numbers in small tiles.
    static let tileNumber = Font.system(size: 28, weight: .bold, design: .rounded)
    static let tileUnit = Font.system(size: 15, weight: .semibold, design: .rounded)
    /// Numbers in metric rows.
    static let metricNumber = Font.system(.title3, design: .rounded).weight(.semibold)
    static let metricUnit = Font.system(.callout, design: .rounded).weight(.semibold)
    /// Sizes at the end of list rows.
    static let rowValue = Font.system(.callout, design: .rounded).weight(.semibold)
    /// Uppercase tag pills.
    static let tag = Font.caption2.weight(.bold)
    /// Title of an empty card ("No scans yet").
    static let emptyTitle = Font.title3.weight(.semibold)
    /// Paths (middle-truncated).
    static let path = Font.callout.monospaced()
    static let smallPath = Font.caption.monospaced()
}

// MARK: - Surfaces

private struct CardFillsHeightKey: EnvironmentKey { static let defaultValue = false }
private struct OnBoldSurfaceKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set inside a `.bold` card: secondary text uses `Palette.onBoldSecondary` instead of `.secondary`.
    var onBoldSurface: Bool {
        get { self[OnBoldSurfaceKey.self] }
        set { self[OnBoldSurfaceKey.self] = newValue }
    }

    /// Set by `WidgetGrid`, so the cards of a row share the row's height.
    var cardFillsHeight: Bool {
        get { self[CardFillsHeightKey.self] }
        set { self[CardFillsHeightKey.self] = newValue }
    }
}

extension View {
    /// Card surface: large continuous radius, hairline border, soft shadow.
    func cardSurface(radius: CGFloat = Radius.card) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: 1))
            .shadow(color: Palette.cardShadow, radius: 6, y: 2)
    }

    /// The window canvas behind a screen (also under the toolbar).
    func canvasBackground() -> some View {
        background(Palette.canvas.ignoresSafeArea())
    }

    /// A list or table placed in a card: its own background is hidden so the card shows.
    func listInCard() -> some View {
        scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .cardSurface()
    }
}

/// Soft glow of a data shape in dark mode (ref. 02); light mode stays crisp (ref. 01).
private struct DarkGlow: ViewModifier {
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.shadow(color: colorScheme == .dark ? color.opacity(0.45) : .clear, radius: 6)
    }
}

extension View {
    func darkGlow(_ color: Color) -> some View { modifier(DarkGlow(color: color)) }
}

// MARK: - Card

/// How a card is filled. `.bold` is the saturated hero tile of ref. 03: the card's tint fills it
/// and its content is white. Use it for at most one tile per screen.
enum CardStyle { case plain, bold }

/// A card with an optional header: tinted symbol, bold title, info glyph (full text in its help) and
/// trailing actions.
struct Card<Content: View>: View {
    let title: String?
    let symbol: String?
    let tint: Color
    let info: String?
    let style: CardStyle
    let trailing: AnyView?
    @ViewBuilder let content: Content
    @Environment(\.cardFillsHeight) private var fillsHeight

    init(_ title: String? = nil, symbol: String? = nil, tint: Color = .accentColor, info: String? = nil,
         style: CardStyle = .plain, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.info = info
        self.style = style
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: Spacing.s) {
            if title != nil || trailing != nil {
                CardHeader(title: title ?? "", symbol: symbol, tint: style == .bold ? .white : tint, info: info) { trailing }
            }
            content
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        Group {
            switch style {
            case .plain:
                stack.cardSurface()
            case .bold:
                // White content on the tint; controls and secondary text render as on a dark surface.
                // Secondary and tertiary text stay at least 4.5:1 against the tint.
                stack
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                    .environment(\.onBoldSurface, true)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(tint)
                            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.10), .black.opacity(0.22)],
                                                     startPoint: .top, endPoint: .bottom)))
                    }
                    .shadow(color: tint.opacity(0.25), radius: 8, y: 3)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .accentColor
    var info: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let symbol {
                Image(systemName: symbol).font(.cardTitle).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(title).font(.cardTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
            if let info { InfoGlyph(text: info) }
            Spacer(minLength: Spacing.xs)
            trailing
        }
    }
}

/// "i" glyph whose help (tooltip) and VoiceOver label carry an explanation.
struct InfoGlyph: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.tertiary)
            .help(text)
            .accessibilityLabel("About")
            .accessibilityValue(text)
    }
}

/// Small icon buttons grouped in a capsule (card header actions). Each button needs a label.
struct ActionsPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Spacing.s) { content }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .overlay(Capsule().strokeBorder(Palette.cardBorder, lineWidth: 1))
    }
}

// MARK: - Empty and loading states

/// A card's honest "no data yet" state: optional symbol, title and one or two lines.
struct CardEmptyState: View {
    let title: String
    let message: String
    var symbol: String? = nil
    @Environment(\.onBoldSurface) private var onBold

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            if let symbol {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.emptyTitle)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(onBold ? AnyShapeStyle(Palette.onBoldSecondary) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Screen-level empty, loading or error state: a `ContentUnavailableView` centred in the space left.
struct EmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: String, symbol: String, message: String? = nil) {
        self.init(title: title, symbol: symbol, message: message) { EmptyView() }
    }
}

/// Screen-level loading state: a spinner and what is happening, centred in the space left.
struct LoadingState: View {
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: Spacing.s) {
            ProgressView().controlSize(.large)
            Text(title).font(.cardTitle).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: Dimensions.formWidth / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Screen header

/// The first row of every screen: tinted icon, title, one line of status, and trailing actions.
struct ScreenHeader<Trailing: View>: View {
    let item: SidebarItem
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: item.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Dimensions.headerIcon, height: Dimensions.headerIcon)
                .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                // The title is never truncated; the status line truncates first (full text in its help).
                Text(item.title).font(.pageTitle).lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(subtitle)
                }
            }
            Spacer(minLength: Spacing.s)
            // Actions keep their full width; the title and status truncate first.
            HStack(spacing: Spacing.xs) { trailing }
                .layoutPriority(1)
        }
        .padding(.horizontal, Spacing.l)
        .frame(height: Dimensions.headerHeight)
    }
}

// MARK: - Numbers

/// A measured value with its unit smaller and secondary ("412 GB"). Unknown values read "Unknown".
struct ValueText: View {
    enum Size { case hero, tile, metric }
    let value: String
    var size: Size = .hero
    @Environment(\.onBoldSurface) private var onBold

    var body: some View {
        let (number, unit) = Self.split(value)
        (Text(number).font(numberFont)
            + Text(unit.isEmpty ? "" : " " + unit).font(unitFont)
                .foregroundStyle(onBold ? AnyShapeStyle(Palette.onBoldSecondary) : AnyShapeStyle(.secondary)))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(value)
    }

    private var numberFont: Font {
        switch size {
        case .hero: return .heroNumber
        case .tile: return .tileNumber
        case .metric: return .metricNumber
        }
    }

    private var unitFont: Font {
        switch size {
        case .hero: return .heroUnit
        case .tile: return .tileUnit
        case .metric: return .metricUnit
        }
    }

    /// "1.5 GB" → ("1.5", "GB"); "Unknown" → ("Unknown", "").
    static func split(_ value: String) -> (String, String) {
        guard let space = value.lastIndex(of: " ") else { return (value, "") }
        let unit = value[value.index(after: space)...]
        guard !unit.isEmpty, unit.allSatisfy(\.isLetter) else { return (value, "") }
        return (String(value[..<space]), String(unit))
    }
}

/// Label above a value, with an optional caption below.
struct Metric: View {
    let label: String
    let value: String
    var caption: String? = nil
    var size: ValueText.Size = .metric

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ValueText(value: value, size: size)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(caption.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Pills

/// Status pill. Status is always conveyed by text and symbol, never by colour alone.
struct StatusBadge: View {
    let text: String
    let symbol: String
    let tint: Color
    /// Wraps onto a second line in narrow places instead of keeping its full width.
    var wraps = false

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).foregroundStyle(.primary.opacity(0.85))
        }
        .font(.caption.weight(.semibold))
        .lineLimit(wraps ? 2 : 1)
        .fixedSize(horizontal: !wraps, vertical: true)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs / 2)
        // A capsule on one line; a rounded rectangle when it wraps.
        .background(tint.opacity(0.16), in: wraps ? AnyShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)) : AnyShape(Capsule()))
        // The text stays a static text (UI tests and VoiceOver read it); the symbol is decorative.
    }

    init(text: String, symbol: String, tint: Color, wraps: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.wraps = wraps
    }

    init(status: ScanStatus) {
        switch status {
        case .completed: self.init(text: status.displayName, symbol: "checkmark.circle.fill", tint: Palette.success)
        case .partial: self.init(text: status.displayName, symbol: "exclamationmark.triangle.fill", tint: Palette.warning)
        case .running: self.init(text: status.displayName, symbol: "arrow.triangle.2.circlepath", tint: .accentColor)
        case .cancelled: self.init(text: status.displayName, symbol: "stop.circle.fill", tint: .secondary)
        case .interrupted: self.init(text: status.displayName, symbol: "bolt.horizontal.circle.fill", tint: Palette.warning)
        case .failed: self.init(text: status.displayName, symbol: "xmark.octagon.fill", tint: Palette.error)
        }
    }
}

/// Uppercase tag ("LOW RISK", "LAST SCAN").
struct TagPill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.tag)
            .tracking(0.4)
            .foregroundStyle(.primary.opacity(0.8))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs / 2)
            .background(tint.opacity(0.18), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// Change of a byte value: arrow, signed amount and a caption ("↑ 1.2 GB since Oct 25").
/// `higherIsBetter` picks green for an increase (available space) or for a decrease.
struct DeltaPill: View {
    let delta: Int64
    var caption: String? = nil
    var higherIsBetter = true

    var body: some View {
        let good = delta == 0 ? nil : ((delta > 0) == higherIsBetter)
        let tint: Color = good == nil ? .secondary : (good! ? Palette.success : Palette.error)
        let symbol = delta > 0 ? "arrow.up" : (delta < 0 ? "arrow.down" : "equal")
        let amount = delta == 0 ? "No change" : (delta > 0 ? "+" : "−") + ByteFormat.string(abs(delta))
        HStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs / 2) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(amount).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs / 2)
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(delta >= 0 ? "Up" : "Down") \(ByteFormat.string(abs(delta)))\(caption.map { ", \($0)" } ?? "")")
    }
}

/// Value label on a chart (highlighted bar, current value).
struct ValueBubble: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Palette.card)
            .padding(.horizontal, Spacing.xs - 2)
            .padding(.vertical, Spacing.xxs / 2)
            .background(tint, in: Capsule())
            .fixedSize()
    }
}

// MARK: - Banner

struct InlineBanner: View {
    enum Kind { case info, warning, error }
    let kind: Kind
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return Palette.warning
        case .error: return Palette.error
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(Spacing.s)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Charts

struct ChartSegment: Identifiable, Equatable {
    let id: String
    let label: String
    let bytes: Int64
    let color: Color
}

/// Donut with gaps between segments and a value in the middle (rings in refs 03 and 04).
struct RingChart<Center: View>: View {
    let segments: [ChartSegment]
    var lineRatio: CGFloat = 0.74
    @ViewBuilder var center: Center

    var body: some View {
        Chart(segments) { segment in
            SectorMark(angle: .value("Size", Double(max(segment.bytes, 0))),
                       innerRadius: .ratio(lineRatio), angularInset: segments.count > 1 ? 1.5 : 0)
                .cornerRadius(4)
                .foregroundStyle(segment.color)
        }
        .chartLegend(.hidden)
        .darkGlow(segments.first?.color ?? .clear)
        .overlay { center }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.label) \(ByteFormat.string($0.bytes))" }.joined(separator: ", "))
    }
}

/// Legend row: dot, label, right-aligned value and share.
struct LegendRow: View {
    let color: Color
    let label: String
    let value: String
    var share: Double? = nil

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(color).frame(width: Spacing.xs, height: Spacing.xs).accessibilityHidden(true)
            Text(label).lineLimit(1).truncationMode(.middle).help(label)
            Spacer(minLength: Spacing.xs)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
            if let share {
                Text(Self.percent(share)).monospacedDigit().fontWeight(.semibold)
                    .frame(minWidth: Spacing.xl + Spacing.xs, alignment: .trailing)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)\(share.map { ", \(Self.percent($0))" } ?? "")")
    }

    static func percent(_ share: Double) -> String {
        share > 0 && share < 0.01 ? "<1%" : share.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Size per category as rounded horizontal bars with the share at the end (ref. 03).
struct CategoryBars: View {
    let segments: [ChartSegment]
    var maxRows = 5

    private var rows: [ChartSegment] {
        let sorted = segments.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard sorted.count > maxRows else { return sorted }
        let rest = sorted.dropFirst(maxRows - 1).reduce(0) { $0 + $1.bytes }
        return Array(sorted.prefix(maxRows - 1)) + [ChartSegment(id: "other", label: "Other", bytes: rest, color: Palette.neutral)]
    }

    var body: some View {
        let rows = rows
        let total = max(rows.reduce(0) { $0 + $1.bytes }, 1)
        let largest = max(rows.map(\.bytes).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(rows) { row in
                HStack(spacing: Spacing.xs) {
                    Text(row.label).font(.caption).lineLimit(1).truncationMode(.middle)
                        .frame(width: Dimensions.barLabelWidth, alignment: .leading).help(row.label)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track)
                            Capsule().fill(row.color.gradient)
                                .frame(width: max(Spacing.xs, geo.size.width * Double(row.bytes) / Double(largest)))
                                .darkGlow(row.color)
                        }
                    }
                    .frame(height: Spacing.s)
                    Text(ByteFormat.string(row.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 56, alignment: .trailing)
                    Text(LegendRow.percent(Double(row.bytes) / Double(total))).font(.caption.weight(.semibold)).monospacedDigit()
                        .frame(minWidth: Spacing.xl + Spacing.xs, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label), \(ByteFormat.string(row.bytes)), \(LegendRow.percent(Double(row.bytes) / Double(total)))")
            }
        }
    }
}

/// Found / selected summary above a review list: hero total, counts, and size per category.
struct ReviewSummaryCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let totalBytes: Int64
    let itemCount: Int
    let selectedCount: Int
    let selectedBytes: Int64
    let segments: [ChartSegment]
    var info: String? = nil

    var body: some View {
        Card(title, symbol: symbol, tint: tint, info: info) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.l) {
                    totals.frame(width: Dimensions.summaryTotalsWidth, alignment: .leading)
                    CategoryBars(segments: segments, maxRows: 4).frame(maxWidth: .infinity)
                }
                totals
            }
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ValueText(value: ByteFormat.string(totalBytes), size: .tile)
            Text("\(itemCount.formatted()) item\(itemCount == 1 ? "" : "s") found")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(selectedCount == 0 ? "Nothing selected" : "\(selectedCount.formatted()) selected · \(ByteFormat.string(selectedBytes))")
                .font(.caption.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widget grid

private struct WidgetSpanKey: LayoutValueKey { static let defaultValue = 1 }

extension View {
    /// Number of grid columns this tile spans (clamped to the columns available).
    func widgetSpan(_ columns: Int) -> some View { layoutValue(key: WidgetSpanKey.self, value: columns) }
}

/// Widget grid (ref. 04): columns are added as the width grows (one per `Dimensions.widgetColumnMinWidth`,
/// up to `maxColumns`), tiles flow left to right, and the tiles of a row share its height.
struct WidgetGrid: Layout {
    var maxColumns = 4
    var spacing: CGFloat = Spacing.m

    private func columns(for width: CGFloat) -> Int {
        let fit = Int((width + spacing) / (Dimensions.widgetColumnMinWidth + spacing))
        // Even column counts keep 2-wide tiles aligned.
        return max(1, min(maxColumns, fit >= 3 && fit < 4 ? 2 : fit))
    }

    private struct Placement { var index: Int; var column: Int; var span: Int; var row: Int }

    private func arrange(width: CGFloat, subviews: Subviews) -> (columns: Int, placements: [Placement], rowHeights: [CGFloat]) {
        let columns = columns(for: width)
        let unit = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var placements: [Placement] = []
        var rowHeights: [CGFloat] = []
        var column = 0, row = 0
        for (index, subview) in subviews.enumerated() {
            let span = min(max(subview[WidgetSpanKey.self], 1), columns)
            if column + span > columns { column = 0; row += 1 }
            let tileWidth = unit * CGFloat(span) + spacing * CGFloat(span - 1)
            let height = subview.sizeThatFits(ProposedViewSize(width: tileWidth, height: nil)).height
            if rowHeights.count <= row { rowHeights.append(0) }
            rowHeights[row] = max(rowHeights[row], height)
            placements.append(Placement(index: index, column: column, span: span, row: row))
            column += span
        }
        return (columns, placements, rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Dimensions.readableWidth
        let (_, _, heights) = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, placements, heights) = arrange(width: bounds.width, subviews: subviews)
        let unit = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        for placement in placements {
            let x = bounds.minX + CGFloat(placement.column) * (unit + spacing)
            let y = bounds.minY + heights[..<placement.row].reduce(0, +) + spacing * CGFloat(placement.row)
            let width = unit * CGFloat(placement.span) + spacing * CGFloat(placement.span - 1)
            subviews[placement.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                            proposal: ProposedViewSize(width: width, height: heights[placement.row]))
        }
    }
}

/// A `WidgetGrid` whose cards share their row's height.
struct WidgetGridView<Content: View>: View {
    var maxColumns = 4
    @ViewBuilder let content: Content

    var body: some View {
        WidgetGrid(maxColumns: maxColumns).callAsFunction { content }
            .environment(\.cardFillsHeight, true)
    }
}

// MARK: - Form rows

/// Settings row: title, then the current value and a stepper on the trailing side (as in System
/// Settings). The value is also the stepper's accessibility value.
struct StepperRow: View {
    let title: String
    let valueText: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Spacing.xs) {
                Text(valueText).monospacedDigit()
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityValue(valueText)
            }
        }
    }
}

// MARK: - Paths

/// A path in monospaced type, middle-truncated, with the full path in its help and context menu.
struct PathText: View {
    let path: String
    var small = false

    var body: some View {
        let shown = PathUtilities.abbreviatingHome(path)
        Text(shown)
            .font(small ? .smallPath : .path)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
            .contextMenu {
                Button("Reveal in Finder") { FinderActions.reveal([path]) }
                Button("Copy Path") { FinderActions.copy([path]) }
            }
        // No accessibility label override: the text already reads as the shown path, and an override
        // inside `LabeledContent` (Settings › Database) sends the accessibility tree into endless recursion.
    }
}

// MARK: - Helpers

extension Date {
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }
    var relative: String { formatted(.relative(presentation: .named)) }
}

func bytes(_ value: Int64?) -> String { ByteFormat.string(value) }

/// "1 file", "3 files" (digits grouped).
func counted(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count.formatted()) \(count == 1 ? singular : (plural ?? singular + "s"))"
}

extension String {
    /// Shortened to at most `limit` characters with an ellipsis in the middle, for titles that AppKit
    /// draws (menu buttons) and that SwiftUI can't truncate. The full text belongs in the help.
    func middleTruncated(_ limit: Int) -> String {
        guard count > limit, limit > 1 else { return self }
        let head = (limit - 1) / 2 + (limit - 1) % 2
        return String(prefix(head)) + "…" + String(suffix(limit - 1 - head))
    }
}
