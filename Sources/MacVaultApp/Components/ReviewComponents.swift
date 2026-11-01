import SwiftUI
import MacVaultCore

// MARK: - Risk

extension StatusBadge {
    init(risk: RiskLevel) {
        switch risk {
        case .low: self.init(text: risk.displayName, symbol: "checkmark.shield.fill", tint: Palette.success)
        case .medium: self.init(text: risk.displayName, symbol: "exclamationmark.shield.fill", tint: Palette.warning)
        case .high: self.init(text: risk.displayName, symbol: "exclamationmark.triangle.fill", tint: Palette.error)
        case .protected: self.init(text: risk.displayName, symbol: "lock.shield.fill", tint: .secondary)
        case .notAssessed: self.init(text: risk.displayName, symbol: "questionmark.circle.fill", tint: .secondary)
        }
    }

    init(manifest status: ManifestStatus) {
        switch status {
        case .completed: self.init(text: status.displayName, symbol: "checkmark.circle.fill", tint: Palette.success)
        case .partial, .interrupted: self.init(text: status.displayName, symbol: "exclamationmark.triangle.fill", tint: Palette.warning)
        case .failed: self.init(text: status.displayName, symbol: "xmark.octagon.fill", tint: Palette.error)
        case .cancelled, .discarded, .nothingMoved: self.init(text: status.displayName, symbol: "stop.circle.fill", tint: .secondary)
        case .draft, .approved, .executing: self.init(text: status.displayName, symbol: "clock.fill", tint: .accentColor)
        }
    }
}

// MARK: - Candidate row

/// One reviewable item: checkbox, exact path, measured size, risk, and why it is offered.
struct CandidateRow: View {
    let candidate: RemovalCandidate
    @Binding var isSelected: Bool
    var showsCategory = true
    /// Off where the list's section already says what happens after removal.
    var showsConsequence = true
    /// An extra line under the path (for example how an app's data was matched).
    var note: StatusBadge? = nil
    var disabled = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
                .accessibilityLabel("Select \(candidate.name)")
                // A hint, not a value: the value stays the checked state.
                .accessibilityHint("\(sizeText), \(candidate.riskLevel.displayName). \(candidate.reason)")
                .accessibilityIdentifier("select-\(candidate.name)")
            Image(systemName: candidate.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.secondary).frame(width: Spacing.m).accessibilityHidden(true)
            // Size and risk at the trailing edge; below the path when the row is narrow (detail panes).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.s) {
                    details.frame(minWidth: 140, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: Spacing.xxs) { size; StatusBadge(risk: candidate.riskLevel) }
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    details
                    HStack(spacing: Spacing.xs) { size; StatusBadge(risk: candidate.riskLevel) }
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal([candidate.path]) }
            Button("Copy Path") { FinderActions.copy([candidate.path]) }
        }
        .help(candidate.reason)
        // Children stay separate so the checkbox remains its own control for VoiceOver and UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("candidate-\(candidate.name)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
            HStack(spacing: Spacing.xs) {
                Text(candidate.name).font(.rowTitle).lineLimit(1).truncationMode(.middle)
                if showsCategory { Text(candidate.category).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            PathText(path: candidate.path, small: true)
            if showsConsequence {
                Text(candidate.consequence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note { note.padding(.top, Spacing.xxs / 2) }
        }
    }

    private var size: some View {
        Text(sizeText).font(.rowValue).monospacedDigit()
    }

    private var sizeText: String {
        guard let size = candidate.logicalBytes else { return "Unknown" }
        return (candidate.sizeIsLowerBound ? "≥ " : "") + ByteFormat.string(size)
    }
}

// MARK: - Footer

/// Selection summary and the single entry point to the approval sheet. Docked at the bottom of a
/// screen (or pane); the summary and button stack when the width is too small for one row.
struct ReviewFooter: View {
    let count: Int
    let bytes: Int64
    let buttonTitle: String
    var disabled = false
    /// Why the button is disabled while `disabled` is true.
    var disabledReason = "Wait for the current task to finish."
    /// Help for the button; defaults to what it does.
    var help = "Opens a review of exactly what will be moved. Nothing changes until you approve it."
    var horizontalPadding = Spacing.l
    let action: () -> Void

    var body: some View {
        Group {
            if OperationsModel.canModifyFiles {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.m) {
                        summary
                        Spacer(minLength: Spacing.s)
                        button
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        summary
                        button.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                Label(OperationsModel.readOnlyExplanation, systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, Spacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: count == 0 ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .accessibilityHidden(true)
            Text(count == 0 ? "Nothing selected" : "\(count) selected · \(ByteFormat.string(bytes))")
                .font(.callout.weight(count == 0 ? .regular : .medium))
                .foregroundStyle(count == 0 ? .secondary : .primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var button: some View {
        Button(buttonTitle, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(count == 0 || disabled)
            .help(count == 0 ? "Select at least one item to review." : (disabled ? disabledReason : help + " (⌘↩)"))
            .fixedSize()
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
            SheetHeader(title: "Move \(manifest.items.count) item\(manifest.items.count == 1 ? "" : "s") to the Trash?",
                        subtitle: manifest.title, symbol: "trash.fill", tint: Palette.error)
                .accessibilityIdentifier("approvalTitle")

            HStack(alignment: .top, spacing: Spacing.l) {
                MetricGrid(items: [
                    MetricItem("Measured size", value: ByteFormat.string(manifest.estimatedBytes)),
                    MetricItem("Items", value: manifest.items.count.formatted()),
                ])
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    if highRisk > 0 { StatusBadge(text: "\(highRisk) high risk", symbol: "exclamationmark.triangle.fill", tint: Palette.error) }
                    if mediumRisk > 0 { StatusBadge(text: "\(mediumRisk) to review carefully", symbol: "exclamationmark.shield.fill", tint: Palette.warning) }
                    StatusBadge(text: "Reversible from the Trash", symbol: "arrow.uturn.backward.circle.fill", tint: Palette.success)
                }
            }
            .padding(Spacing.m)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))

            List(manifest.items) { item in
                VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(PathUtilities.abbreviatingHome(item.originalPath))
                            .font(.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            .help(item.originalPath)
                        Spacer(minLength: Spacing.xs)
                        Text(ByteFormat.string(item.expectedSizeBytes)).font(.rowValue).monospacedDigit()
                            .frame(minWidth: Dimensions.rowValueWidth, alignment: .trailing)
                        StatusBadge(risk: item.riskLevel)
                            .frame(minWidth: Dimensions.rowActionWidth, alignment: .trailing)
                    }
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs / 2)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // About as tall as its rows (two lines each), up to a bound; longer lists scroll.
            .frame(height: min(300, max(60, CGFloat(manifest.items.count) * 60)))
            .background(Palette.track, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))

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
                        .font(.callout.weight(.medium))
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("riskAcknowledgement")
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.error.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(Palette.error.opacity(0.3), lineWidth: 1))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("approvalCancel")
                Button("Move to Trash", role: .destructive, action: onApprove)
                    .disabled(highRisk > 0 && !acknowledgedRisk)
                    .help(highRisk > 0 && !acknowledgedRisk ? "Acknowledge the high-risk items first." : "Moves the items listed above to the Trash.")
                    .accessibilityIdentifier("approvalConfirm")
            }
        }
        .padding(Spacing.l)
        .frame(width: Dimensions.sheetWidth)
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
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Moving to the Trash… \(progress.processed) of \(progress.total)").font(.cardTitle).monospacedDigit()
                        ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                        PathText(path: progress.currentPath, small: true)
                    }
                    Spacer(minLength: Spacing.s)
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
            .accessibilityIdentifier("operationResult")
            if showDetails {
                Card {
                    // Bounded: a long list scrolls instead of pushing the screen past the window.
                    // As tall as its content, up to the bound.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                            ForEach(problems) { item in
                                HStack(alignment: .top) {
                                    Image(systemName: item.status == .failed ? "xmark.octagon" : "minus.circle")
                                        .foregroundStyle(item.status == .failed ? Palette.error : .secondary).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                                        PathText(path: item.originalPath, small: true)
                                        Text(item.status == .pending ? "Not processed" : (item.message ?? item.status.rawValue))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxHeight: Dimensions.boundedListHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { model.operations.dismissResult(); showDetails = false }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - History

struct OperationHistoryList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let types: Set<OperationType>
    @State private var expanded = false

    var body: some View {
        let manifests = model.operations.history(for: types)
        if !manifests.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // The whole header row toggles the list.
                Button {
                    withAnimation(Motion.standard(reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text("History").font(.callout.weight(.semibold))
                        Text(counted(manifests.count, "list")).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("History, \(counted(manifests.count, "list"))")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("historyToggle")

                if expanded {
                    Divider()
                    // Bounded: history grows with every operation and must not push the screen past the window.
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(manifests) { manifest in
                                DisclosureGroup {
                                    ForEach(manifest.items) { item in
                                        HStack(spacing: Spacing.xs) {
                                            PathText(path: item.originalPath, small: true)
                                            Spacer(minLength: Spacing.xs)
                                            Text(item.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                            if let trashPath = item.resultingPath, item.status == .trashed {
                                                Button("Show in Trash") { FinderActions.reveal([trashPath]) }
                                                    .controlSize(.mini)
                                                    .help("Put it back from Finder with File › Put Back")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: Spacing.xs) {
                                        Text(manifest.createdAt.shortDateTime).monospacedDigit().foregroundStyle(.secondary)
                                        Text(manifest.title).fontWeight(.medium).lineLimit(1)
                                        Spacer(minLength: Spacing.xs)
                                        Text("\(manifest.count(.trashed)) of \(manifest.items.count) moved").foregroundStyle(.secondary).monospacedDigit()
                                        StatusBadge(manifest: manifest.status)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                    // As tall as its content, up to the bound.
                    .frame(maxHeight: Dimensions.boundedListHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xxs)
            .cardSurface()
        }
    }
}
