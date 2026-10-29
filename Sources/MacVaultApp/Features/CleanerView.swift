import SwiftUI
import MacVaultCore

/// Rule-based review of caches and logs (also used for global developer caches).
struct RuleFindingsList: View {
    @Bindable var scan: RuleScanModel

    var body: some View {
        List {
            ForEach(scan.findings) { findings in
                Section {
                    if findings.candidates.isEmpty {
                        Text(emptyText(findings)).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(findings.candidates) { candidate in
                        CandidateRow(candidate: candidate, isSelected: binding(for: candidate.id), showsCategory: false,
                                     disabled: !OperationsModel.canModifyFiles)
                    }
                } header: {
                    HStack(spacing: Spacing.xs) {
                        Text(findings.rule.title)
                        StatusBadge(risk: findings.rule.risk)
                        Spacer()
                        if !findings.candidates.isEmpty {
                            Text(ByteFormat.string(findings.totalBytes)).monospacedDigit()
                            Button(allSelected(findings) ? "Deselect All" : "Select All") { toggleAll(findings) }
                                .controlSize(.small)
                                .disabled(!OperationsModel.canModifyFiles)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(findings.rule.explanation)
                        Text("After removal: \(findings.rule.consequence)")
                        if findings.protectedCount > 0 || findings.tooRecentCount > 0 {
                            Text(notes(findings)).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
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
            header(scan)
            Divider()
            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.cleanup])
                if let error = scan.error { InlineBanner(kind: .error, title: "Review could not finish", message: error) }
                OperationHistoryList(types: [.cleanup])
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs)

            if scan.findings.isEmpty {
                ContentUnavailableView {
                    Label(scan.isScanning ? "Looking for caches and logs…" : "Review caches and logs",
                          systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text("MacVault lists app caches and old logs in your Library with their exact paths and sizes. Nothing is changed until you approve a list.")
                } actions: {
                    if !scan.isScanning {
                        Button("Find Items") { scan.scan(policy: model.operations.policy) }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                RuleFindingsList(scan: scan)
            }
            Divider()
            ReviewFooter(count: scan.selectedCandidates.count, bytes: scan.selectedBytes, buttonTitle: "Review & Move to Trash…",
                         disabled: model.operations.isExecuting || scan.isScanning) {
                Task {
                    await model.operations.review(.cleanup, title: "Caches and logs", candidates: scan.selectedCandidates) {
                        if case .finished(let manifest) = model.operations.phase { scan.removeProcessed(manifest) }
                    }
                }
            }
        }
        .navigationTitle("Cleaner")
    }

    private func header(_ scan: RuleScanModel) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Caches and logs").font(.headline)
                Text(scan.lastScanned.map { "Checked \($0.relative) · rules \(RuleCatalog.version)" } ?? "Rules \(RuleCatalog.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if scan.isScanning {
                ProgressView().controlSize(.small)
                Text(scan.currentRule ?? "").font(.caption).foregroundStyle(.secondary)
                Button("Stop") { scan.cancel() }
            } else {
                Button(scan.findings.isEmpty ? "Find Items" : "Check Again") { scan.scan(policy: model.operations.policy) }
                    .disabled(model.operations.isExecuting)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }
}
