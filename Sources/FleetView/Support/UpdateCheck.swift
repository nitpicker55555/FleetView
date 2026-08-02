import Foundation
import SwiftUI

/// Asks GitHub whether a newer FleetView has been released.
///
/// This is the one thing FleetView sends off the machine on its own, so it is deliberate about it:
/// one unauthenticated GET of the releases endpoint, at most once every six hours, and nothing about
/// you in the request beyond what any HTTP call carries. Set `"updates": false` in
/// `~/.fleetview/logging.json` to turn it off entirely.
///
/// A release the user has dismissed is remembered by version, so a banner appears once per release
/// rather than every launch.
@MainActor
final class UpdateCheck: ObservableObject {

    struct Release: Equatable {
        let version: String       // "0.2.0" — the tag with any leading v stripped
        let url: String           // the release page
        let notes: String
        /// The .zip asset, when the release ships one. Without it there is nothing to install and
        /// the offer is reduced to opening the page — which is what a source-only release deserves.
        let assetURL: String?
    }

    @Published private(set) var available: Release?

    /// Non-nil while a self-update is running ("下载中…"). Drives the pill, which is the only place
    /// left to say anything once the alert has been dismissed.
    @Published var status: String?

    /// What a check concluded. The pill can only ever say "there is a newer one", which is the right
    /// amount of noise for a check nobody asked for — but a menu item someone clicked has to answer
    /// either way, including "you are already on the latest" and "GitHub could not be reached".
    enum Outcome {
        case newer(Release)
        case current(String)      // the version already installed
        case failed(String)
    }

    private static let endpoint =
        "https://api.github.com/repos/nitpicker55555/FleetView/releases/latest"
    private static let interval: TimeInterval = 6 * 3600
    private let dismissedKey = "fv.update.dismissed"
    private let lastCheckKey = "fv.update.lastCheck"

    /// Look for a newer release. Cheap to call on launch — it returns immediately unless the
    /// interval has elapsed. `then` is for the menu item, which always forces and so is never the
    /// call the throttle turns away.
    func check(force: Bool = false, then: ((Outcome) -> Void)? = nil) {
        guard AuditConfig.current.updates else {
            then?(.failed("更新检查已关闭：~/.fleetview/logging.json 里 \"updates\": false"))
            return
        }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if !force, Date().timeIntervalSince1970 - last < Self.interval { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard let url = URL(string: Self.endpoint) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FleetView/\(FV.version)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                // GitHub answers a repo with no releases at all with a 404 body, which lands here
                // too — worth saying out loud when someone asked, silent when nobody did.
                let why = error?.localizedDescription ?? "GitHub 没有返回可用的版本信息"
                Task { @MainActor in then?(.failed(why)) }
                return
            }
            let latest = Self.normalise(tag)
            let notes = (obj["body"] as? String) ?? ""
            let page = (obj["html_url"] as? String)
                ?? "https://github.com/nitpicker55555/FleetView/releases"
            let asset = (obj["assets"] as? [[String: Any]])?.first {
                ($0["name"] as? String)?.hasSuffix(".zip") == true
            }?["browser_download_url"] as? String
            Task { @MainActor in
                guard let self else { return }
                guard Self.isNewer(latest, than: Self.normalise(FV.shortVersion)) else {
                    then?(.current(FV.shortVersion)); return
                }
                let release = Release(version: latest, url: page, notes: notes, assetURL: asset)
                // "Not this version" silences the pill, not a question you just asked by hand.
                if force || latest != UserDefaults.standard.string(forKey: self.dismissedKey) {
                    self.available = release
                }
                then?(.newer(release))
            }
        }.resume()
    }

    /// Stop offering this one. A later release will still be offered.
    func dismiss() {
        if let v = available?.version {
            UserDefaults.standard.set(v, forKey: dismissedKey)
        }
        available = nil
    }

    func openReleasePage() {
        guard let r = available, let url = URL(string: r.url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Version comparison

    /// "v0.2.0" / "0.2.0 (3)" → "0.2.0". Anything that is not a dotted number is dropped, so a tag
    /// like `v0.2.0-beta` compares as 0.2.0 rather than failing to parse.
    /// `nonisolated`: pure string work, and it is called from the URLSession callback, which is not
    /// on the main actor.
    nonisolated static func normalise(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
        var parts: [String] = []
        for chunk in cleaned.split(whereSeparator: { !$0.isNumber && $0 != "." }) {
            for p in chunk.split(separator: ".") where p.allSatisfy(\.isNumber) { parts.append(String(p)) }
            if !parts.isEmpty { break }
        }
        return parts.isEmpty ? "0" : parts.joined(separator: ".")
    }

    /// Numeric component-wise, so 0.10.0 is correctly newer than 0.9.0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
