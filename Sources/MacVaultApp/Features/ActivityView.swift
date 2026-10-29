import SwiftUI
import MacVaultCore

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var minimumSeverity: AuditSeverity? = nil
    @State private var selection: AuditEvent.ID?
    @State private var sortOrder = [KeyPathComparator(\AuditEvent.createdAt, order: .reverse)]

    private var events: [AuditEvent] { model.recentEvents.sorted(using: sortOrder) }
    private var selected: AuditEvent? { model.recentEvents.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                TextField("Search messages, event types or operation IDs", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit { reload() }
                Picker("Severity", selection: $minimumSeverity) {
                    Text("All severities").tag(AuditSeverity?.none)
                    Text("Notice and above").tag(AuditSeverity?.some(.notice))
                    Text("Warnings and errors").tag(AuditSeverity?.some(.warning))
                    Text("Errors only").tag(AuditSeverity?.some(.error))
                }
                .fixedSize()
                Spacer()
                Button("Export…") {}
                    .disabled(true)
                    .help("Planned: JSON/CSV export with path redaction")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            Divider()

            if model.store == nil {
                ContentUnavailableView("Activity log unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(model.startupError ?? "The local database could not be opened."))
            } else if events.isEmpty {
                ContentUnavailableView(search.isEmpty && minimumSeverity == nil ? "No activity yet" : "No matching activity",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Scans, access changes and data management actions are recorded here."))
            } else {
                HSplitView {
                    Table(events, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("Time", value: \.createdAt) { e in
                            Text(e.createdAt.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                        }
                        .width(min: 150, ideal: 170)
                        TableColumn("Severity", value: \.severity.rawValue) { e in
                            HStack(spacing: Spacing.xxs) { SeverityIcon(severity: e.severity); Text(e.severity.rawValue.capitalized) }
                        }
                        .width(min: 90, ideal: 100)
                        TableColumn("Event", value: \.eventType) { e in
                            Text(e.eventType).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        .width(min: 120, ideal: 140)
                        TableColumn("Message", value: \.message) { e in
                            Text(e.message).lineLimit(1)
                        }
                    }
                    .frame(minWidth: 520)

                    EventDetail(event: selected)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
            }
        }
        .navigationTitle("Activity")
        .onChange(of: minimumSeverity) { _, _ in reload() }
        .onChange(of: search) { _, newValue in if newValue.isEmpty { reload() } }
        .task { reload() }
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
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack { SeverityIcon(severity: event.severity); Text(event.eventType).font(.headline.monospaced()) }
                    Text(event.message).textSelection(.enabled)
                    Divider()
                    LabeledContent("Time", value: event.createdAt.formatted(date: .complete, time: .standard))
                    if let op = event.operationId {
                        LabeledContent("Operation ID") { Text(op).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    if let details = prettyDetails(event.detailsJSON) {
                        Text("Details").font(.subheadline.weight(.medium))
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No selection", systemImage: "sidebar.right",
                                   description: Text("Select an event to see its details."))
        }
    }

    private func prettyDetails(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return json }
        return String(decoding: pretty, as: UTF8.self)
    }
}
