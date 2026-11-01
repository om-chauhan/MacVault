import SwiftUI
import MacVaultCore

/// One-time consent: every permission MacVault uses, its real status, and one button that asks for
/// all of them. Shown on first launch and from Settings or the Overview banner afterwards.
struct PermissionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let permissions = model.permissions
        let hasLocations = !model.access.locations.isEmpty
        let items = permissions.items(hasScanLocations: hasLocations)
        let outstanding = items.filter { $0.status.needsAttention }
        VStack(alignment: .leading, spacing: Spacing.m) {
            SheetHeader(title: "Allow MacVault to read your Mac",
                        subtitle: "One-time setup. MacVault only reads; nothing is moved or deleted without your approval.",
                        symbol: "lock.shield.fill", tint: Palette.analyzer)

            Card(flush: true) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        PermissionRow(item: item, busy: permissions.isRequesting) { act(on: item) }
                        if item.id != items.last?.id { Divider().padding(.leading, Spacing.m + Dimensions.headerIcon + Spacing.s) }
                    }
                }
            }

            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Palette.analyzer).accessibilityHidden(true)
                Text("By allowing, you let MacVault read the locations above to measure what uses space. Reading never changes a file. The only change MacVault can ever make is to move items you approve, one list at a time, to the Trash. You can change any of these later in System Settings or in MacVault › Settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(outstanding.isEmpty ? "Done" : "Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("permissionsNotNow")
                Spacer()
                if permissions.isRequesting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS…").font(.caption).foregroundStyle(.secondary)
                }
                if !outstanding.isEmpty {
                    Button("Allow All") { allowAll() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(permissions.isRequesting)
                        .help("Asks macOS for every permission above in one pass. System Settings opens only for Full Disk Access, which macOS does not let apps request directly.")
                        .accessibilityIdentifier("permissionsAllowAll")
                }
            }
        }
        .padding(Spacing.l)
        .frame(width: Dimensions.sheetWidth)
        .task { await permissions.refresh() }
        .onDisappear { model.settings.permissionsConsentShown = true }
    }

    private func allowAll() {
        Task {
            await model.permissions.requestAll {
                if model.access.locations.isEmpty {
                    if PermissionsModel.supportsFullDiskAccess {
                        await model.selectWholeMac()
                    } else {
                        await model.chooseAndAddLocation()
                    }
                }
            }
        }
    }

    private func act(on item: PermissionItem) {
        Task {
            switch item.kind {
            case .fullDiskAccess:
                PermissionsModel.openSystemSettings(.fullDiskAccess)
            case .protectedFolders:
                if item.status == .notRequested { await model.permissions.requestProtectedFolders() }
                else { PermissionsModel.openSystemSettings(.filesAndFolders) }
            case .scanLocations:
                if PermissionsModel.supportsFullDiskAccess { await model.selectWholeMac() } else { await model.chooseAndAddLocation() }
            case .notifications:
                if item.status == .notRequested { await model.permissions.requestNotifications() }
                else { PermissionsModel.openSystemSettings(.notifications) }
            }
        }
    }
}

private struct PermissionRow: View {
    let item: PermissionItem
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Dimensions.headerIcon, height: Dimensions.headerIcon)
                .background(Palette.analyzer.gradient, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                HStack(spacing: Spacing.xs) {
                    Text(item.title).font(.rowTitle)
                    PermissionBadge(status: item.status)
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .unavailable(let reason) = item.status {
                    Text(reason).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Spacing.s)
            if let title = item.actionTitle {
                Button(title, action: action)
                    .controlSize(.small)
                    .disabled(busy)
                    .frame(width: Dimensions.permissionActionWidth, alignment: .trailing)
                    .accessibilityIdentifier("permission-\(item.kind.rawValue)")
            } else {
                Color.clear.frame(width: Dimensions.permissionActionWidth, height: 1)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

struct PermissionBadge: View {
    let status: PermissionStatus

    var body: some View {
        switch status {
        case .granted: StatusBadge(text: status.label, symbol: "checkmark.circle.fill", tint: Palette.success)
        case .notRequested: StatusBadge(text: status.label, symbol: "questionmark.circle.fill", tint: Palette.warning)
        case .denied: StatusBadge(text: status.label, symbol: "xmark.circle.fill", tint: Palette.error)
        case .unavailable: StatusBadge(text: status.label, symbol: "minus.circle.fill", tint: .secondary)
        }
    }
}
