// The safe repairs an install test is allowed to try. Each one is a normal
// FixPlan action, so the pack can undo it and the audit sees the result.
import Foundation

enum LaunchTestRepair {

    struct Report: Sendable {
        var changed = false
        var notes: [String] = []
        var actions: [String] = []
    }

    static func apply(_ result: LaunchTest.Result, appID: Int, name: String,
                      progress: @escaping @Sendable (String) -> Void = { _ in }) -> Report {
        guard result.issue.repairable else { return Report() }
        guard let folder = Store.gameFolder(for: appID, name: name),
              var recipe = FixPack.read(in: folder) else { return Report() }
        // A routing-only install deliberately has no OnlineFix loader. Its test
        // failure is not a broken pack, and adding the loader here would undo the
        // player's choice without asking.
        let hasLoader = recipe.entries.contains {
            ($0.path as NSString).lastPathComponent.lowercased() == "onlinefix64.dll"
        }
        guard hasLoader else {
            var report = Report()
            report.notes.append("This is a routing-only install, so the test was left as it is.")
            return report
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        var report = Report()

        switch result.issue {
        case .drmStub:
            applyStub(folder: folder, scan: scan, appID: appID, recipe: &recipe,
                      report: &report, progress: progress)
        case .crashHandler:
            applyCrashHandlers(scan: scan, appID: appID, folder: folder,
                               recipe: &recipe, report: &report)
        case .overlay, .dllList, .onlineFixInterface, .missingDLL:
            let package = loadPackage(folder: folder, recipe: recipe)
            let log = PhotonLog.read(gameFolder: folder, prefix: scan.prefix)
            let audit = FixAudit.run(appID: appID, name: name, scan: scan,
                                     package: package, log: log)
            guard audit.changed else {
                report.notes.append(audit.notes.joined(separator: " "))
                return report
            }
            progress("Applying the audit repair…")
            do {
                let applied = try FixApply.apply(audit.plan, appID: appID, folder: folder,
                                                 progress: progress)
                record(applied, recipe: &recipe, folder: folder)
                report.changed = applied.changed
                report.notes.append(contentsOf: applied.notes)
                report.notes.append(contentsOf: audit.notes)
                report.actions.append(contentsOf: audit.findings.map { "\($0.code): \($0.title)" })
            } catch {
                report.notes.append("Could not repair the fix: \(error.localizedDescription)")
            }
        default:
            break
        }

        if report.changed {
            if !recipe.notes.contains(where: { $0.hasPrefix("Launch test repair:") }) {
                recipe.notes.append("Launch test repair: \(result.issue.rawValue)")
            }
            try? FixPack.write(recipe, in: folder)
        }
        return report
    }

    private static func loadPackage(folder: URL, recipe: FixRecipe) -> FixPackage? {
        let root = FixPack.payloadURL(in: folder, for: "")
        guard Paths.fm.fileExists(atPath: root.path) else { return nil }
        return FixPackage.read(root: root, archiveName: recipe.packageName)
    }

    private static func applyStub(folder: URL, scan: GameScan, appID: Int,
                                  recipe: inout FixRecipe, report: inout Report,
                                  progress: @escaping @Sendable (String) -> Void) {
        let launch = scan.launchFolder
        let destination = launch.appendingPathComponent("StubDRM64.dll")
        let backup = destination.appendingPathExtension("onlinefix-backup")
        let payload = FixPack.payloadURL(in: folder, for: "StubDRM64.dll")
        let source: URL?
        if Paths.fm.fileExists(atPath: backup.path) { source = backup }
        else if Paths.fm.fileExists(atPath: payload.path) { source = payload }
        else { source = nil }
        guard let source else {
            report.notes.append("The DRM stub's untouched copy was not found, so it was not restored.")
            return
        }
        var plan = FixPlan()
        plan.copies.append(FixPlan.Copy(source: source, destination: destination,
                                        relative: FixPlan.relative(destination, in: folder)))
        for handler in FixApply.unityCrashHandlers(in: launch) {
            plan.removals.append(FixPlan.Removal(path: handler,
                                                 reason: "Unity's crash reporter stops this game"))
        }
        progress("Restoring the DRM stub…")
        do {
            let applied = try FixApply.apply(plan, appID: appID, folder: folder, progress: progress)
            let list = launch.appendingPathComponent("dlllist.txt")
            _ = FixApply.ensureDLLListEntries(["StubDRM64.dll"], at: list)
            record(applied, recipe: &recipe, folder: folder)
            report.changed = applied.changed
            report.notes.append(contentsOf: applied.notes)
            report.notes.append("Put StubDRM64.dll back and kept its dlllist.txt line.")
            report.actions.append("Restored StubDRM64.dll")
        } catch {
            report.notes.append("Could not restore the DRM stub: \(error.localizedDescription)")
        }
    }

    private static func applyCrashHandlers(scan: GameScan, appID: Int, folder: URL,
                                           recipe: inout FixRecipe, report: inout Report) {
        let handlers = FixApply.unityCrashHandlers(in: scan.launchFolder)
        guard !handlers.isEmpty else {
            report.notes.append("No Unity crash handler was found to move aside.")
            return
        }
        var plan = FixPlan()
        for handler in handlers {
            plan.removals.append(FixPlan.Removal(path: handler,
                                                 reason: "Unity's crash reporter stops this game"))
        }
        do {
            let applied = try FixApply.apply(plan, appID: appID, folder: folder)
            record(applied, recipe: &recipe, folder: folder)
            report.changed = applied.changed
            report.notes.append(contentsOf: applied.notes)
            report.actions.append("Moved \(handlers.map(\.lastPathComponent).joined(separator: ", ")) aside")
        } catch {
            report.notes.append("Could not move the crash reporter aside: \(error.localizedDescription)")
        }
    }

    private static func record(_ applied: FixApply.Result, recipe: inout FixRecipe, folder: URL) {
        for wrote in applied.wrote {
            guard let file = FixPack.file(wrote.relative, in: folder),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, let hash = Hash.sha256(file) else { continue }
            recipe.entries.removeAll { $0.path == wrote.relative }
            recipe.entries.append(FixRecipe.Entry(path: wrote.relative, size: Int64(size),
                                                  sha256: hash, created: wrote.created))
        }
        for relative in applied.removed where !recipe.removed.contains(relative) {
            recipe.removed.append(relative)
        }
        recipe.entries.sort { $0.path < $1.path }
        recipe.removed.sort()
    }
}
