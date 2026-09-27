import Foundation

/// Opening a project from the web dashboard.
///
/// The phone could make terminals only in projects already on the board, so starting work in any
/// other repo meant walking back to the Mac to click Open Folder. The web gets the same act, but
/// fenced to one place: the folders directly inside ~/PycharmProjects, which is where this user's
/// projects live. The server has no authentication, and "add any path on the disk to the board, then
/// open a shell in it" is not something a LAN request should be able to ask for.
extension AppState {
    static var workspaceRoot: URL {
        FV.home.appendingPathComponent("PycharmProjects", isDirectory: true)
    }

    private struct WorkspaceFolder: Encodable {
        let name: String
        let path: String
        let git: Bool
        /// The board's project id when it is already open there, so the page can go to it.
        let projectId: String?
        let modified: Double
    }

    private struct WorkspaceListing: Encodable {
        let root: String
        let folders: [WorkspaceFolder]
    }

    /// GET /workspace — every folder directly inside the root, most recently changed first.
    func workspaceListing() -> Data {
        let fm = FileManager.default
        let root = Self.workspaceRoot
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        let open = Dictionary(projects.map { ($0.path, $0.id.uuidString) },
                              uniquingKeysWith: { first, _ in first })
        var folders: [WorkspaceFolder] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // A symlink to a directory reports false here; resolve before deciding it is not one.
            var isDir: ObjCBool = false
            guard values?.isDirectory == true
                    || (fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
            else { continue }
            folders.append(WorkspaceFolder(
                name: url.lastPathComponent, path: url.path,
                git: fm.fileExists(atPath: url.appendingPathComponent(".git").path),
                projectId: open[url.path],
                modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        folders.sort { $0.modified > $1.modified }
        let body = WorkspaceListing(root: root.path, folders: folders)
        return (try? JSONEncoder().encode(body)) ?? Data(#"{"folders":[]}"#.utf8)
    }

    /// `raw` if it names a folder directly inside the root, else nil.
    ///
    /// Compared after standardising, so `…/PycharmProjects/x/..` or `…/PycharmProjects/../y` cannot
    /// pass for a child; and only one level down, because a nested folder is part of a project, not
    /// a project. The path handed back is the unresolved one the listing showed — the board dedupes
    /// projects by path, and a resolved symlink would open the same folder a second time.
    func workspaceFolder(_ raw: String) -> String? {
        let root = Self.workspaceRoot.standardizedFileURL.path
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        guard url.deletingLastPathComponent().path == root,
              !url.lastPathComponent.hasPrefix(".") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url.path
    }
}
