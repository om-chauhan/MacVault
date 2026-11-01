import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacVaultCore

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var minimumSeverity: AuditSeverity? = nil
    @State private var selection: AuditEvent.ID?
    @State private var sortOrder = [KeyPathComparator(\AuditEvent.createdAt, order: .reverse)]
    @State private var exportError: String?

    private var events: [AuditEvent] { model.recentEvents.sorted(using: sortOrder) }
    private var selected: AuditEvent? { model.recentEvents.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(item: .activity, subtitle: subtitle) {
                TextField("Search activity", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Dimensions.searchFieldWidth)
                    .onSubmit { reload() }
                    .help("Search messages, event types and operation IDs. Press Return to search the whole log.")
                Picker("Severity", selection: $minimumSeverity) {
                    Text("All severities").tag(AuditSeverity?.none)
                    Text("Notice and above").tag(AuditSeverity?.some(.notice))
                    Text("Warnings and errors").tag(AuditSeverity?.some(.warning))
                    Text("Errors only").tag(AuditSeverity?.some(.error))
                }
                .labelsHidden()
                .fixedSize()
                .help("Show events of at least this severity")
                Menu {
                    Section("Home folder replaced with ~") {
                        Button("JSON…") { export(.json, .homeFolder) }
                        Button("CSV…") { export(.csv, .homeFolder) }
                    }
                    Section("Full paths") {
                        Button("JSON with Full Paths…") { export(.json, .none) }
                        Button("CSV with Full Paths…") { export(.csv, .none) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .disabled(model.store == nil)
                .help(model.store == nil ? "The activity log is unavailable." : "Exports the whole activity log. Redacted exports replace your home folder and account name.")
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let exportError {
                    InlineBanner(kind: .error, title: "Export failed", message: exportError, actionTitle: "Dismiss") { self.exportError = nil }
                }

                if model.store == nil {
                    EmptyState(title: "Activity log unavailable", symbol: "exclamationmark.triangle",
                               message: model.startupError ?? "The local database could not be opened.")
                } else if events.isEmpty {
                    EmptyState(title: search.isEmpty && minimumSeverity == nil ? "No activity yet" : "No matching activity",
                               symbol: SidebarItem.activity.symbol,
                               message: search.isEmpty && minimumSeverity == nil
                                   ? "Scans, access changes and data management actions are recorded here."
                                   : "Try another search or a lower severity.")
                } else {
                    // The table takes the width; the selected event's detail is a fixed-width inspector card.
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Card(flush: true) {
                            Table(events, selection: $selection, sortOrder: $sortOrder) {
                                TableColumn("Time", value: \.createdAt) { e in
                                    // Compact (day and month, time to the second); the full date is in the
                                    // help and the detail pane.
                                    Text(e.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()))
                                        .monospacedDigit().lineLimit(1)
                                        .help(e.createdAt.formatted(date: .complete, time: .standard))
                                }
                                // Ideal widths sum to what fits beside the inspector at the minimum window;
                                // the message column takes the rest in wider windows. The event type is in
                                // the detail (and searchable), not a column.
                                .width(min: 110, ideal: 124, max: 200)
                                TableColumn("Severity", value: \.severity.rawValue) { e in
                                    HStack(spacing: Spacing.xxs) { SeverityIcon(severity: e.severity); Text(e.severity.rawValue.capitalized) }
                                }
                                .width(min: 70, ideal: 78, max: 110)
                                TableColumn("Message", value: \.message) { e in
                                    Text(e.message).lineLimit(1).truncationMode(.middle).help("\(e.message)\n\(e.eventType)")
                                }
                                .width(min: 80, ideal: 90)
                            }
                            .alternatingRowBackgrounds(.disabled)
                            .scrollContentBackground(.hidden)
                        }
                        .environment(\.cardFillsHeight, true)

                        EventDetail(event: selected)
                            .frame(width: Dimensions.inspectorWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .cardSurface()
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Activity")
        .onChange(of: minimumSeverity) { _, _ in reload() }
        .onChange(of: search) { _, newValue in if newValue.isEmpty { reload() } }
        .task { reload() }
    }

    /// What the table shows: the log is append-only; counts are of the events listed.
    private var subtitle: String {
        let events = model.recentEvents
        guard !events.isEmpty else { return "Append-only log of scans, access changes, reviews and moves" }
        let warnings = events.filter { $0.severity == .warning }.count
        let errors = events.filter { $0.severity == .error }.count
        var parts = [counted(events.count, "event")]
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func export(_ format: ActivityExporter.Format, _ redaction: ActivityExporter.Redaction) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacVault Activity \(Date().formatted(.iso8601.year().month().day())).\(format.fileExtension)"
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            exportError = await model.exportActivity(format: format, redaction: redaction, to: url)
            reload()
        }
    }

    private func reload() {
        Task { await model.reloadActivity(search: search, minimumSeverity: minimumSeverity) }
    }
}

struct EventDetail: View {
    let event: AuditEvent?

    var body: some View {
        if let event {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(spacing: Spacing.xs) {
                        SeverityIcon(severity: event.severity)
                        TagPill(text: event.severity.rawValue, tint: tint(event.severity))
                        Spacer(minLength: 0)
                    }
                    Text(event.eventType).font(.headline.monospaced()).textSelection(.enabled)
                    Text(event.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        detailRow("Time", event.createdAt.formatted(date: .complete, time: .standard))
                        if let op = event.operationId { detailRow("Operation ID", op, monospaced: true) }
                    }
                    if let details = prettyDetails(event.detailsJSON) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Details").font(.cardTitle)
                            Text(details).font(.smallPath).textSelection(.enabled)
                                .padding(Spacing.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.track, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        }
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(title: "No selection", symbol: "sidebar.right", message: "Select an event to see its details.")
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .smallPath : .callout).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func tint(_ severity: AuditSeverity) -> Color {
        switch severity {
        case .info: return .secondary
        case .notice: return Palette.storage
        case .warning: return Palette.warning
        case .error: return Palette.error
        }
    }

    private func prettyDetails(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return json }
        return String(decoding: pretty, as: UTF8.self)
    }
}
