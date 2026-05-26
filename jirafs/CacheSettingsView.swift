import SwiftUI
import JiraFSCore

struct CacheSettingsView: View {
    @Binding var ttl: Configuration.CacheTTLConfig
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Local draft — edits are committed only on Save.
    @State private var draft: Configuration.CacheTTLConfig

    init(ttl: Binding<Configuration.CacheTTLConfig>, onSave: @escaping () -> Void) {
        self._ttl = ttl
        self.onSave = onSave
        self._draft = State(initialValue: ttl.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cache Settings")
                .font(.title2.bold())
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formSection("TTL") {
                        ttlRow("Projects",      value: $draft.projects)
                        Divider().padding(.leading, 100)
                        ttlRow("Issues",        value: $draft.issues)
                        Divider().padding(.leading, 100)
                        ttlRow("Issue Detail",  value: $draft.issueDetail)
                        Divider().padding(.leading, 100)
                        ttlRow("Attachments",   value: $draft.attachments)
                        Divider().padding(.leading, 100)
                        ttlRow("File Content",  value: $draft.attachmentBinary)
                    }

                    HStack {
                        Button("Reset to Defaults") {
                            draft = .default
                        }
                        Spacer()
                    }
                    .padding(.horizontal)

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Changes take effect after remounting each instance.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    ttl = draft
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 400)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func ttlRow(_ label: String, value: Binding<TimeInterval>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
                .padding(.trailing, 10)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text("sec")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Text("(\(formatMinutes(value.wrappedValue)))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let mins = seconds / 60
        if mins < 1 { return "\(Int(seconds))s" }
        if mins == mins.rounded(.toNearestOrAwayFromZero) && mins == Double(Int(mins)) {
            return "\(Int(mins)) min"
        }
        return String(format: "%.1f min", mins)
    }

    @ViewBuilder
    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}
