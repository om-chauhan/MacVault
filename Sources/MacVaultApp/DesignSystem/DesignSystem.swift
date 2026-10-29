import SwiftUI
import MacVaultCore

/// 8-point spacing scale.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Motion {
    /// Short, restrained transition; nil when Reduce Motion is on.
    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    let title: String?
    let symbol: String?
    let trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, symbol: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if title != nil || trailing != nil {
                HStack(spacing: Spacing.xs) {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    if let title {
                        Text(title).font(.headline)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
            }
            content
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Metric

struct Metric: View {
    let label: String
    let value: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status badge

/// Status is always conveyed by text and symbol, never by color alone.
struct StatusBadge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityLabel(text)
    }

    init(text: String, symbol: String, tint: Color) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    init(status: ScanStatus) {
        switch status {
        case .completed: self.init(text: status.displayName, symbol: "checkmark.circle", tint: .green)
        case .partial: self.init(text: status.displayName, symbol: "exclamationmark.triangle", tint: .orange)
        case .running: self.init(text: status.displayName, symbol: "arrow.triangle.2.circlepath", tint: .accentColor)
        case .cancelled: self.init(text: status.displayName, symbol: "stop.circle", tint: .secondary)
        case .interrupted: self.init(text: status.displayName, symbol: "bolt.horizontal.circle", tint: .orange)
        case .failed: self.init(text: status.displayName, symbol: "xmark.octagon", tint: .red)
        }
    }

    static let planned = StatusBadge(text: "Planned", symbol: "clock", tint: .secondary)
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
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
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
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Helpers

extension Date {
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }
    var relative: String { formatted(.relative(presentation: .named)) }
}

func bytes(_ value: Int64?) -> String { ByteFormat.string(value) }

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}
