import SwiftUI
import MacVaultCore

/// One thing a maintenance screen checks or never touches, shown before the first search.
struct StartFact: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    var risk: RiskLevel? = nil

    init(_ title: String, symbol: String, detail: String, risk: RiskLevel? = nil) {
        id = title
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.risk = risk
    }

    /// A cleanup rule, exactly as the catalog defines it.
    init(rule: CleanupRule) {
        let symbol: String
        switch rule.category {
        case .caches: symbol = "internaldrive.fill"
        case .logs: symbol = "doc.text.fill"
        case .installers: symbol = "arrow.down.circle.fill"
        case .leftovers: symbol = "folder.badge.minus"
        case .developer: symbol = "hammer.fill"
        }
        self.init(rule.title, symbol: symbol, detail: rule.explanation, risk: rule.risk)
    }
}

/// The first thing a maintenance screen shows: what it will look for, what it never touches, and
/// one button to begin. The screen header carries no action in this state, so the button exists
/// once; after the first results the header offers "Check Again" and this view is gone.
struct StartScreen: View {
    let item: SidebarItem
    let title: String
    let message: String
    let actionTitle: String
    var actionDisabled = false
    var actionHelp = ""
    /// Scope or mode shown beside the button ("In ~/Projects · files ≥ 10 MB").
    var note: String? = nil
    let checksTitle: String
    let checks: [StartFact]
    let safety: [StartFact]
    let action: () -> Void

    var body: some View {
        ScrollView {
            // The tile takes its own row, so a long list of checks never stretches it; the two fact
            // cards share the row below (stacked at the minimum window width).
            WidgetGridView {
                startTile.widgetSpan(4)
                checksCard.widgetSpan(2)
                safetyCard.widgetSpan(2)
            }
            .padding(.bottom, Spacing.m)
            .frame(maxWidth: Dimensions.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var startTile: some View {
        Card(tint: item.tint, style: .bold) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Image(systemName: item.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.callout).foregroundStyle(Palette.onBoldSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Dimensions.readableWidth / 2, alignment: .leading)
                Spacer(minLength: Spacing.xs)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Spacing.m) { button; noteText }
                    VStack(alignment: .leading, spacing: Spacing.xs) { button; noteText }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var button: some View {
        Button(actionTitle, action: action)
            .buttonStyle(TileButtonStyle(tint: item.tint))
            .disabled(actionDisabled)
            .help(actionHelp)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("startAction")
    }

    @ViewBuilder
    private var noteText: some View {
        if let note {
            Text(note).font(.caption).foregroundStyle(Palette.onBoldSecondary)
                .lineLimit(2).truncationMode(.middle).help(note)
        }
    }

    private var checksCard: some View {
        Card(checksTitle, symbol: "list.bullet.rectangle.fill", tint: item.tint) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(checks) { fact in
                    factRow(fact, tint: item.tint)
                    if fact.id != checks.last?.id { Divider() }
                }
            }
        }
    }

    private var safetyCard: some View {
        Card("Never touched", symbol: "hand.raised.fill", tint: Palette.success,
             info: "Nothing is removed until you approve a list. Approved items go to the Trash, and each one is checked again right before it moves.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 400), spacing: Spacing.l, alignment: .top)],
                      alignment: .leading, spacing: Spacing.s) {
                ForEach(safety) { fact in factRow(fact, tint: Palette.success) }
            }
        }
    }

    private func factRow(_ fact: StartFact, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: fact.symbol)
                .foregroundStyle(tint)
                .frame(width: Spacing.l)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                HStack(spacing: Spacing.xs) {
                    Text(fact.title).font(.rowTitle)
                    if let risk = fact.risk { StatusBadge(risk: risk) }
                }
                Text(fact.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// White capsule button for a bold tile; the label takes the tile's tint.
private struct TileButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs + 2)
            .background(Color.white.opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.45)), in: Capsule())
            .foregroundStyle(isEnabled ? tint : tint.opacity(0.6))
            .contentShape(Capsule())
    }
}
