import SwiftUI
import MacVaultCore

/// Rule-based review of caches and logs (also used for global developer caches).
struct RuleFindingsList: View {
    @Bindable var scan: RuleScanModel

    var body: some View {
        let found = scan.findings.filter { !$0.candidates.isEmpty }
        let checked = scan.findings.filter { $0.candidates.isEmpty }
        List {
            // Rules that found something first; the rest are listed compactly below.
            ForEach(found) { findings in
                Section {
                    ForEach(findings.candidates) { candidate in
                        CandidateRow(candidate: candidate, isSelected: binding(for: candidate.id), showsCategory: false,
                                     showsConsequence: false, disabled: !OperationsModel.canModifyFiles)
                    }
                    // What the rule covers and what happens after removal, once per rule. A row rather than
                    // a section footer, so it wraps in narrow windows.
                    VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                        Text(findings.rule.explanation)
                        Text("After removal: \(findings.rule.consequence)")
                        if findings.protectedCount > 0 || findings.tooRecentCount > 0 {
                            Text(notes(findings)).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .combine)
                } header: {
                    // The rule's size shares its right edge with the sizes of the rows below.
                    ListSectionHeader(title: findings.rule.title, badge: StatusBadge(risk: findings.rule.risk),
                                      value: ByteFormat.string(findings.totalBytes)) {
                        Button(allSelected(findings) ? "Deselect All" : "Select All") { toggleAll(findings) }
                            .controlSize(.small)
                            .disabled(!OperationsModel.canModifyFiles)
                            .help(OperationsModel.canModifyFiles ? "Select or deselect every item of this rule" : OperationsModel.readOnlyExplanation)
                    }
                }
            }
            if !checked.isEmpty {
                Section {
                    ForEach(checked) { findings in
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "checkmark.circle").foregroundStyle(.tertiary).accessibilityHidden(true)
                            Text(findings.rule.title).font(.rowTitle).lineLimit(1)
                            StatusBadge(risk: findings.rule.risk)
                            Spacer(minLength: Spacing.s)
                            Text(([emptyText(findings)] + (findings.protectedCount > 0 || findings.tooRecentCount > 0 ? [notes(findings)] : []))
                                    .joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        .help("\(findings.rule.explanation)\nAfter removal: \(findings.rule.consequence)")
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    ListSectionHeader(title: found.isEmpty ? "Checked" : "Also checked")
                }
            }
        }
        .listStyle(.inset)
        .listInCard()
    }

    /// Size found per rule, for the summary card.
    static func segments(_ scan: RuleScanModel, tint: Color) -> [ChartSegment] {
        scan.findings.enumerated().map { index, findings in
            ChartSegment(id: findings.rule.id, label: findings.rule.title, bytes: findings.totalBytes,
                         color: index == 0 ? tint : Palette.series[(index + 1) % Palette.series.count])
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { scan.selection.contains(id) },
                set: { if $0 { scan.selection.insert(id) } else { scan.selection.remove(id) } })
    }

    private func allSelected(_ findings: RuleFindings) -> Bool {
        findings.candidates.allSatisfy { scan.selection.contains($0.id) }
    }

    private func toggleAll(_ findings: RuleFindings) {
        let ids = Set(findings.candidates.map(\.id))
        if allSelected(findings) { scan.selection.subtract(ids) } else { scan.selection.formUnion(ids) }
    }

    private func emptyText(_ findings: RuleFindings) -> String {
        if findings.locationMissing { return "Not present on this Mac." }
        if let error = findings.locationError { return "Could not be read: \(error)" }
        return "Nothing to review."
    }

    private func notes(_ findings: RuleFindings) -> String {
        var parts: [String] = []
        if findings.protectedCount > 0 { parts.append("\(findings.protectedCount) item(s) are always kept (system or protected)") }
        if findings.tooRecentCount > 0 { parts.append("\(findings.tooRecentCount) item(s) changed recently and are kept") }
        return parts.joined(separator: " · ")
    }
}

struct CleanerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.cleaner
        VStack(spacing: 0) {
            ScreenHeader(item: .cleaner, subtitle: subtitle(scan)) {
                if scan.isScanning {
                    ProgressView().controlSize(.small)
                    Text(scan.currentRule ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop") { scan.cancel() }
                        .help("Stop looking. Nothing has been changed.")
                } else {
                    Button(scan.findings.isEmpty ? "Find Items" : "Check Again") { scan.scan(policy: model.operations.policy) }
                        .disabled(model.operations.isExecuting)
                        .help(model.operations.isExecuting ? "Wait until items are moved to the Trash." : "Look for caches and old logs. Read-only.")
                }
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.cleanup])
                if let error = scan.error { InlineBanner(kind: .error, title: "Review could not finish", message: error) }
                OperationHistoryList(types: [.cleanup])
                if scan.findings.isEmpty && scan.isScanning {
                    LoadingState(title: "Looking for caches and logs…", message: scan.currentRule)
                } else if scan.findings.isEmpty {
                    EmptyState(title: "Review caches and logs", symbol: SidebarItem.cleaner.symbol,
                               message: "MacVault lists app caches and old logs in your Library with their exact paths and sizes. Nothing is changed until you approve a list.") {
                        Button("Find Items") { scan.scan(policy: model.operations.policy) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ReviewSummaryCard(title: "Found", symbol: "sparkles", tint: Palette.cleaner,
                                      totalBytes: scan.findings.reduce(0) { $0 + $1.totalBytes },
                                      itemCount: scan.allCandidates.count,
                                      selectedCount: scan.selectedCandidates.count, selectedBytes: scan.selectedBytes,
                                      segments: RuleFindingsList.segments(scan, tint: Palette.cleaner),
                                      info: "Measured size of the items each rule offers. Apple and system caches are never offered.")
                    RuleFindingsList(scan: scan)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxHeight: .infinity, alignment: .top)

            ReviewFooter(count: scan.selectedCandidates.count, bytes: scan.selectedBytes, buttonTitle: "Review & Move to Trash…",
                         disabled: model.operations.isExecuting || scan.isScanning) {
                Task {
                    await model.operations.review(.cleanup, title: "Caches and logs", candidates: scan.selectedCandidates,
                                                  inUseCheck: { RunningApps.cleanupConflict($0) }) {
                        if case .finished(let manifest) = model.operations.phase { scan.removeProcessed(manifest) }
                    }
                }
            }
        }
        .navigationTitle("Cleaner")
    }

    private func subtitle(_ scan: RuleScanModel) -> String {
        "Caches and logs · " + (scan.lastScanned.map { "checked \($0.relative) · rules \(RuleCatalog.version)" } ?? "rules \(RuleCatalog.version)")
    }
}
