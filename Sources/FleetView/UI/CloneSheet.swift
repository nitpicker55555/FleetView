import SwiftUI
import AppKit

struct CloneSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var repo = ""
    @State private var parentDir = FV.home.appendingPathComponent("PycharmProjects").path
    @State private var error: String?

    private var destPreview: String {
        (parentDir as NSString).appendingPathComponent(Git.repoName(from: repo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(Theme.accent)
                Text("Clone GitHub Repository").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
            }

            field(label: "Repository") {
                TextField("owner/repo  or  https://github.com/owner/repo", text: $repo)
                    .textFieldStyle(.plain).onSubmit(startClone)
            }

            field(label: "Into folder") {
                HStack(spacing: 8) {
                    TextField("", text: $parentDir).textFieldStyle(.plain)
                    Button { pickParent() } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundColor(Theme.subtext)
                }
            }

            if !repo.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("→ \(destPreview)")
                    .font(.system(size: 11)).foregroundColor(Theme.subtext.opacity(0.75))
                    .lineLimit(1).truncationMode(.middle)
            }

            if let error {
                Text(error).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.statusColor(.exited)).lineLimit(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label("克隆在后台进行，进度显示在顶栏，可以随时取消。", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).foregroundColor(Theme.subtext.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                Button(action: startClone) { Text("Clone").fontWeight(.medium) }
                    .buttonStyle(.borderedProminent)
                    .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470)
        .background(Theme.bg)
    }

    @ViewBuilder private func field<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.subtext)
            content()
                .padding(8)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke, lineWidth: 1))
                .foregroundColor(Theme.text)
        }
    }

    /// Hands the clone to the background and gets out of the way. Only what can be answered
    /// instantly is answered here — an empty field, a destination that already exists — because
    /// those are the two failures worth having a dialog still open for (see `Git.precheck`).
    private func startClone() {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        error = nil
        do {
            try Git.precheck(repo: r, into: parentDir)
        } catch {
            self.error = error.localizedDescription
            return
        }
        state.cloneRepository(r, into: parentDir)
        dismiss()
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: parentDir)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { parentDir = url.path }
    }
}
