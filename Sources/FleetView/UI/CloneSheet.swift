import SwiftUI
import AppKit

struct CloneSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var repo = ""
    @State private var parentDir = FV.home.appendingPathComponent("PycharmProjects").path
    @State private var cloning = false
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
                    .textFieldStyle(.plain).disabled(cloning).onSubmit(startClone)
            }

            field(label: "Into folder") {
                HStack(spacing: 8) {
                    TextField("", text: $parentDir).textFieldStyle(.plain).disabled(cloning)
                    Button { pickParent() } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundColor(Theme.subtext).disabled(cloning)
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
                if cloning {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Cloning…").font(.system(size: 12)).foregroundColor(Theme.subtext)
                }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(cloning)
                Button(action: startClone) { Text("Clone").fontWeight(.medium) }
                    .buttonStyle(.borderedProminent)
                    .disabled(cloning || repo.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func startClone() {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !cloning else { return }
        error = nil; cloning = true
        let dir = parentDir
        Task {
            do {
                let dest = try await Git.clone(repo: r, into: dir)
                await MainActor.run { state.addProject(path: dest); cloning = false; dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; cloning = false }
            }
        }
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
