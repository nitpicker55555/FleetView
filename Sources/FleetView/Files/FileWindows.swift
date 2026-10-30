import AppKit
import FleetViewFiles
import SwiftUI

/// The open file windows, one per project.
///
/// Opening a project's files again brings its window forward rather than making a second one: two
/// windows on one folder would watch it twice, run git twice, and could each hold unsaved edits to
/// the same file.
@MainActor
final class FileWindows {
    static let shared = FileWindows()

    private var controllers: [UUID: FileWindowController] = [:]

    /// Open (or bring forward) a project's file window. `reveal`: a folder inside it to open in the
    /// tree, `file`: a file to open.
    func open(_ project: Project, app: AppState, reveal: String? = nil, file: String? = nil) {
        // No window server, no windows: the web dashboard's 📁 is the file browser there.
        guard !Headless.active else { return }
        let c: FileWindowController
        if let existing = controllers[project.id] {
            c = existing
        } else {
            FileRecovery.pruneOnce()
            c = FileWindowController(project: project, app: app)
            c.onClose = { [weak self] id in
                guard let self else { return }
                self.controllers.removeValue(forKey: id)
                // HEAD versions are kept for the windows that show them: none left, none kept.
                if self.controllers.isEmpty { BlobCache.shared.removeAll() }
            }
            controllers[project.id] = c
        }
        c.show()
        if let reveal { c.model.revealDirectory(reveal) }
        if let file, let rel = c.model.relative(file) { c.model.open(rel, pin: true) }
    }

    /// A card's commits: its project's window, on the 提交 page, listing what that card committed.
    func showCommits(of t: TerminalSession, app: AppState) {
        guard let p = app.projects.first(where: { $0.id == t.projectId }) else { return }
        open(p, app: app)
        controllers[p.id]?.model.showCommits(of: CommitAuthor(id: t.id, name: t.name, projectId: t.projectId, removed: false))
    }

    func open(projectId: UUID, app: AppState, reveal: String? = nil) {
        guard let p = app.projects.first(where: { $0.id == projectId }) else { return }
        open(p, app: app, reveal: reveal)
    }

    var hasUnsaved: Bool { controllers.values.contains { !$0.model.unsavedTabs.isEmpty } }

    /// ⌘+ / ⌘− / ⌘0 while a file window is in front: its text size, not the terminals'. Returns false
    /// when the key window is not a file window.
    func zoom(_ window: NSWindow?, by delta: Int?) -> Bool {
        guard let window, let c = controllers.values.first(where: { $0.model.window === window }) else { return false }
        c.model.editor.setFontSize(delta.map { c.model.editor.fontSize + $0 } ?? EditorBridge.defaultFontSize)
        return true
    }

    /// Before the app goes away (quit, or the self-updater handing off): save, discard or stay.
    /// `done(true)` means it may go.
    func settleUnsaved(reason: String, _ done: @escaping (Bool) -> Void) {
        let dirty = controllers.values.filter { !$0.model.unsavedTabs.isEmpty }
        guard !dirty.isEmpty else { done(true); return }
        let all = dirty.flatMap { $0.model.unsavedTabs }
        let a = NSAlert()
        a.messageText = all.count == 1 ? L(.filesUnsavedOne((all[0].path as NSString).lastPathComponent))
                                       : L(.filesUnsavedMany(all.count))
        a.informativeText = reason
        a.addButton(withTitle: L(.filesSaveAll))
        a.addButton(withTitle: L(.cancel))
        a.addButton(withTitle: L(.filesDontSave))
        dirty.first?.show()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            var remaining = dirty.count, allOK = true
            for c in dirty {
                c.model.saveTabs(c.model.unsavedTabs) { ok in
                    allOK = allOK && ok
                    remaining -= 1
                    if remaining == 0 { done(allOK) }
                }
            }
        case .alertThirdButtonReturn:
            for c in dirty { c.model.discardAll() }
            done(true)
        default:
            done(false)
        }
    }
}

/// One project's file window.
@MainActor
final class FileWindowController: NSObject, NSWindowDelegate {
    let model: FileBrowserModel
    private let window: NSWindow
    var onClose: ((UUID) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var appearance: NSKeyValueObservation?
    private var closingConfirmed = false

    init(project: Project, app: AppState) {
        model = FileBrowserModel(project: project, app: app)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L(.filesWindowTitle(project.name))
        window.subtitle = model.subtitle
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 420)
        // sRGB for the same reason as the terminal windows: an extended-range display otherwise backs
        // the window with half-float pixels at twice the memory, for colours that are all sRGB.
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: FileBrowserView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("FleetViewFiles")
        model.window = window

        // Nothing runs for a window nobody can see: no git, no reloads (see FileBrowserModel.visible).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.visible = self.window.occlusionState.contains(.visible) && !self.window.isMiniaturized
                }
            })
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.isKey = key }
            })
        }
        appearance = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.model.editor.applyTheme() } }
        }
        model.start()
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let dirty = model.unsavedTabs
        guard !dirty.isEmpty, !closingConfirmed else { return true }
        model.askAboutUnsaved(dirty) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .save:
                self.model.saveTabs(dirty) { ok in
                    if ok { self.closingConfirmed = true; self.window.close() }
                }
            case .discard:
                self.model.discardAll()
                self.closingConfirmed = true
                self.window.close()
            case .cancel: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        appearance = nil
        model.stop()
        window.contentView = nil
        onClose?(model.projectId)
    }
}
