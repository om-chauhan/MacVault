import SwiftUI

/// Placeholder for features that are not implemented. Has no functional controls by design:
/// the product rules forbid presenting unimplemented features as working.
struct PlannedFeatureView: View {
    enum Feature {
        case cleaner, applications, duplicates, developer

        var title: String {
            switch self {
            case .cleaner: return "Cleaner"
            case .applications: return "Applications"
            case .duplicates: return "Duplicates"
            case .developer: return "Developer Tools"
            }
        }

        var symbol: String {
            switch self {
            case .cleaner: return "sparkles.rectangle.stack"
            case .applications: return "square.grid.2x2"
            case .duplicates: return "doc.on.doc"
            case .developer: return "hammer"
            }
        }

        var summary: String {
            switch self {
            case .cleaner:
                return "Review cache, temporary and log candidates found by versioned rules, then move approved items to the Trash."
            case .applications:
                return "Inventory installed apps, show bundle size separately from related data, and review associated files before removal."
            case .duplicates:
                return "Find files with identical content, verified by a cryptographic hash, and choose which copy to keep."
            case .developer:
                return "Review Xcode DerivedData and archives, Flutter and Gradle build outputs, and Node package caches — separated from project data."
            }
        }

        var safeguards: [String] {
            switch self {
            case .cleaner:
                return ["Every item is shown with its exact path, size, risk and reason before approval",
                        "Each item is checked again immediately before it is moved",
                        "Items go to the Trash where possible; every outcome is logged"]
            case .applications:
                return ["App removal and leftover-data cleanup are separate actions",
                        "Associated files are candidates with a confidence level, never removed automatically",
                        "Running apps, login items and keychains are never touched without separate consent"]
            case .duplicates:
                return ["Nothing is ever deleted automatically",
                        "Savings are estimates — APFS clones can share storage"]
            case .developer:
                return ["Source code, Git data, credentials and signing assets are never offered as junk",
                        "Global caches and per-project artifacts are labelled separately"]
            }
        }
    }

    let feature: Feature

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: feature.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: Spacing.xs) {
                Text(feature.title).font(.title2.weight(.semibold))
                StatusBadge.planned
            }
            Text(feature.summary)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Built-in safeguards").font(.subheadline.weight(.medium))
                ForEach(feature.safeguards, id: \.self) { line in
                    Label(line, systemImage: "checkmark.shield").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.m)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 520)
            Text("Not available in this version. Nothing on this screen changes your files.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(feature.title)
    }
}
