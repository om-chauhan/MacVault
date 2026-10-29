import SwiftUI
import MacVaultCore

// MARK: - Risk

extension StatusBadge {
    init(risk: RiskLevel) {
        switch risk {
        case .low: self.init(text: risk.displayName, symbol: "checkmark.shield", tint: .green)
        case .medium: self.init(text: risk.displayName, symbol: "exclamationmark.shield", tint: .orange)
        case .high: self.init(text: risk.displayName, symbol: "exclamationmark.triangle", tint: .red)
        case .protected: self.init(text: risk.displayName, symbol: "lock.shield", tint: .secondary)
        case .notAssessed: self.init(text: risk.displayName, symbol: "questionmark.circle", tint: .secondary)
        }
    }

    init(manifest status: ManifestStatus) {
        switch status {
        case .completed: self.init(text: status.displayName, symbol: "checkmark.circle", tint: .green)
        case .partial, .interrupted: self.init(text: status.displayName, symbol: "exclamationmark.triangle", tint: .orange)
        case .failed: self.init(text: status.displayName, symbol: "xmark.octagon", tint: .red)
        case .cancelled, .discarded, .nothingMoved: self.init(text: status.displayName, symbol: "stop.circle", tint: .secondary)
        case .draft, .approved, .executing: self.init(text: status.displayName, symbol: "clock", tint: .accentColor)
        }
    }
}

// MARK: - Candidate row

/// One reviewable item: checkbox, exact path, measured size, risk, and why it is offered.
struct CandidateRow: View {
    let candidate: RemovalCandidate
    @Binding var isSelected: Bool
    var showsCategory = true
    var disabled = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
                .accessibilityLabel("Select \(candidate.name)")
            Image(systemName: candidate.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(candidate.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if showsCategory { Text(candidate.category).font(.caption).foregroundStyle(.secondary) }
                }
                Text(PathUtilities.abbreviatingHome(candidate.path))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text(candidate.consequence).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.s)
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText).monospacedDigit()
                StatusBadge(risk: candidate.riskLevel)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal([candidate.path]) }
            Button("Copy Path") { FinderActions.copy([candidate.path]) }
        }
        .help(candidate.reason)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }

    private var sizeText: String {
        guard let size = candidate.logicalBytes else { return "Unknown" }
        return (candidate.sizeIsLowerBound ? "≥ " : "") + ByteFormat.string(size)
    }
}

// MARK: - Footer

/// Selection summary and the single entry point to the approval sheet.
struct ReviewFooter: View {
    let count: Int
    let bytes: Int64
    let buttonTitle: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            if OperationsModel.canModifyFiles {
                Text(count == 0 ? "Nothing selected" : "\(count) selected · \(ByteFormat.string(bytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0 || disabled)
                    .help("Opens a review of exactly what will be moved. Nothing changes until you approve it.")
            } else {
                Label(OperationsModel.readOnlyExplanation, systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.bar)
    }
}

// MARK: - Approval sheet

struct ApprovalSheet: View {
    let pending: OperationsModel.PendingReview
    let onApprove: () -> Void
    let onCancel: () -> Void
    @State private var acknowledgedRisk = false

    private var manifest: OperationManifest { pending.manifest }
    private var highRisk: Int { manifest.items.filter { $0.riskLevel == .high }.count }
    private var mediumRisk: Int { manifest.items.filter { $0.riskLevel == .medium }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "trash").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(manifest.items.count) item\(manifest.items.count == 1 ? "" : "s") to the Trash?")
                        .font(.title2.weight(.semibold))
                    Text(manifest.title).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Spacing.xl) {
                Metric(label: "Measured size", value: ByteFormat.string(manifest.estimatedBytes))
                Metric(label: "Items", value: manifest.items.count.formatted())
                if mediumRisk > 0 { Metric(label: "Review carefully", value: mediumRisk.formatted()) }
                if highRisk > 0 { Metric(label: "High risk", value: highRisk.formatted()) }
            }

            List(manifest.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(PathUtilities.abbreviatingHome(item.originalPath))
                            .font(.callout.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Text(ByteFormat.string(item.expectedSizeBytes)).monospacedDigit()
                        StatusBadge(risk: item.riskLevel)
                    }
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180, maxHeight: 320)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Label("Items go to the Trash. You can put them back from Finder until you empty the Trash. Disk space is freed only when the Trash is emptied.",
                      systemImage: "arrow.uturn.backward.circle")
                Label("Each item is checked again right before it is moved. Anything that changed since this review, is in use, or is protected is skipped and reported.",
                      systemImage: "checkmark.shield")
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if highRisk > 0 {
                Toggle(isOn: $acknowledgedRisk) {
                    Text("I understand that \(highRisk) high-risk item\(highRisk == 1 ? " is" : "s are") included.")
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onApprove)
                    .disabled(highRisk > 0 && !acknowledgedRisk)
            }
        }
        .padding(Spacing.l)
        .frame(width: 640)
    }
}

// MARK: - Execution status

/// Progress while items are being moved, then a result with every skipped or failed item explained.
struct OperationStatusPanel: View {
    @Environment(AppModel.self) private var model
    let types: Set<OperationType>
    @State private var showDetails = false

    var body: some View {
        switch model.operations.phase {
        case .idle:
            EmptyView()
        case .executing(let progress):
            Card {
                HStack(spacing: Spacing.m) {
                    ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 220)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moving to the Trash… \(progress.processed) of \(progress.total)").font(.headline)
                        Text(PathUtilities.abbreviatingHome(progress.currentPath)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Stop", role: .cancel) { model.operations.cancel() }
                        .help("Stops after the current item. Remaining items are not touched.")
                }
            }
        case .finished(let manifest) where types.contains(manifest.type):
            result(manifest)
        case .failed(let message):
            InlineBanner(kind: .error, title: "Nothing more was changed", message: message,
                         actionTitle: "Dismiss") { model.operations.dismissResult() }
        case .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private func result(_ manifest: OperationManifest) -> some View {
        let trashed = manifest.count(.trashed)
        let problems = manifest.items.filter { $0.status == .skipped || $0.status == .failed || $0.status == .pending }
        VStack(alignment: .leading, spacing: Spacing.xs) {
            InlineBanner(kind: manifest.status == .completed ? .info : .warning,
                         title: "\(trashed) item\(trashed == 1 ? "" : "s") moved to the Trash (\(ByteFormat.string(manifest.trashedBytes)))",
                         message: manifest.status == .completed
                            ? "Empty the Trash in Finder to free the space. Until then you can put items back."
                            : (manifest.failureReason ?? manifest.status.displayName),
                         actionTitle: problems.isEmpty ? "Dismiss" : (showDetails ? "Hide Details" : "Show Details")) {
                if problems.isEmpty { model.operations.dismissResult() } else { showDetails.toggle() }
            }
            if showDetails {
                Card {
                    ForEach(problems) { item in
                        HStack(alignment: .top) {
                            Image(systemName: item.status == .failed ? "xmark.octagon" : "minus.circle")
                                .foregroundStyle(item.status == .failed ? .red : .secondary).accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(PathUtilities.abbreviatingHome(item.originalPath)).font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                                Text(item.status == .pending ? "Not processed" : (item.message ?? item.status.rawValue))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button("Dismiss") { model.operations.dismissResult(); showDetails = false }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - History

struct OperationHistoryList: View {
    @Environment(AppModel.self) private var model
    let types: Set<OperationType>

    var body: some View {
        let manifests = model.operations.history(for: types)
        if !manifests.isEmpty {
            DisclosureGroup("History (\(manifests.count))") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(manifests) { manifest in
                        DisclosureGroup {
                            ForEach(manifest.items) { item in
                                HStack {
                                    Text(PathUtilities.abbreviatingHome(item.originalPath)).font(.caption.monospaced())
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(item.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                    if let trashPath = item.resultingPath, item.status == .trashed {
                                        Button("Show in Trash") { FinderActions.reveal([trashPath]) }
                                            .controlSize(.mini)
                                            .help("Put it back from Finder with File › Put Back")
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(manifest.createdAt.shortDateTime).monospacedDigit()
                                Text(manifest.title).lineLimit(1)
                                Spacer()
                                Text("\(manifest.count(.trashed)) of \(manifest.items.count)").foregroundStyle(.secondary)
                                StatusBadge(manifest: manifest.status)
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(.top, Spacing.xs)
            }
        }
    }
}
