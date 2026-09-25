import Foundation
import Darwin
import BackendRuntime

@main struct RuntimeMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        let isUpdater = executable == "apply-update" || (executable == "BowserRuntimeTool" && args.first == "apply-update")
        if isUpdater && args.contains("--restart-ui") {
            do {
                let arguments = args.first == "apply-update" ? Array(args.dropFirst()) : args
                try MainActor.assumeIsolated { try runUpdateWindow(arguments) }
                return
            } catch { fputs("bowser runtime: \(error)\n", stderr); exit(1) }
        }
        Task { await run(); exit(0) }
        dispatchMain()
    }

    @MainActor static func run() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            var mode = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
            if mode == "BowserRuntimeTool" {
                guard !args.isEmpty else { throw RuntimeFailure("expected runtime tool command") }
                mode = args.removeFirst()
            }
            switch mode {
            case "BowserProdLauncher": try launchProduction()
            case "pin-production-runtime":
                guard args.count == 1 else { throw RuntimeFailure("pin-production-runtime HOME") }
                try pinProductionRuntime(URL(fileURLWithPath: args[0]))
            case "detach": try detach(args)
            case "bowser-mcp-bridge": try runMCP()
            case "apply-update": try await runUpdater(args)
            case "publish":
                guard args.count == 6 || (args.count == 7 && args[6] == "--live") else { throw RuntimeFailure("publish PENDING STAGE RUNTIME BUNDLE SHELL_ONLY BRAIN_ONLY [--live]") }
                let pending = URL(fileURLWithPath: args[0])
                try publish(pending, ["stage": args[1], "runtime": args[2], "bundle": args[3], "home": pending.deletingLastPathComponent().deletingLastPathComponent().path], shellOnly: args[4] == "1", brainOnly: args[5] == "1", live: args.last == "--live")
            case "restore-backup":
                guard args.count == 1 else { throw RuntimeFailure("restore-backup SNAPSHOT") }
                try restoreBackup(URL(fileURLWithPath: args[0]))
            case "backup-targets":
                guard args.count == 3 else { throw RuntimeFailure("backup-targets HOME RUNTIME BUNDLE") }
                let manifest: Message = ["home": args[0], "runtime": args[1], "bundle": args[2], "stage": args[0] + "/updates/unused"]
                for target in try backupTargets(manifest) { print(target.path) }
            case "cancel-update":
                guard args.count == 1 else { throw RuntimeFailure("cancel-update HOME") }
                let root = URL(fileURLWithPath: args[0]), pending = child(root, "updates/pending.json")
                let lock = try FileLock(child(root, "updates/pending.lock"), nonblocking: true)
                defer { withExtendedLifetime(lock) {} }
                if exists(pending) {
                    let manifest = try readJSON(pending)
                    guard manifest["backend_applied"] as? Bool != true,
                          manifest["live_allowed"] as? Bool != true else {
                        throw RuntimeFailure("Live components may already be active; quit Bowser to finish activation")
                    }
                    try remove(pending)
                    try remove(field(manifest, "stage"))
                }
                print("Pending update cancelled.")
            case "active-runtime":
                guard args.count == 1, let runtime = try readJSON(URL(fileURLWithPath: args[0]))["runtime"] as? String else { throw RuntimeFailure("invalid runtime pointer") }
                print(runtime)
            case "watcher-plist":
                guard args.count == 2 else { throw RuntimeFailure("watcher-plist PATH UPDATE_ROOT") }
                let root = args[1]
                let plist: Message = ["Label": "com.foxwiseai.bowser.pending-update", "ProgramArguments": [root + "/apply-update", root + "/pending.json", "--wait"], "RunAtLoad": true, "KeepAlive": ["PathState": [root + "/pending.json": true]], "ThrottleInterval": 10, "StandardOutPath": root + "/install.log", "StandardErrorPath": root + "/install.log"]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: args[0]), options: .atomic)
            default: throw RuntimeFailure("unknown runtime tool: \(mode)")
            }
        } catch { fputs("bowser runtime: \(error)\n", stderr); exit(1) }
    }
}
