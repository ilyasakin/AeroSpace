import Common
import Foundation

struct ImportConfigCommand: Command {
    let args: ImportConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let sourcePath = (args.path.val as NSString).expandingTildeInPath
        guard let sourceText = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
            return .fail(io.err("Can't read '\(sourcePath)'"))
        }

        var options = ImportOptions()
        if let mod = args.mod4Target { options.mod4Target = mod }
        let result: ImportResult = switch args.format.val {
            case .i3: importI3Config(sourceText, options)
        }

        // The importer must never produce an unparsable config
        let parsed = parseConfig(result.toml)
        if !parsed.errors.isEmpty {
            io.err("The generated config unexpectedly failed to validate. Please report this bug:")
            for error in parsed.errors {
                io.err("    " + error.description(.error))
            }
            return .fail
        }

        for d in result.diagnostics {
            io.out(d.description)
        }
        io.out("\(result.translatedCount) of \(result.directiveCount) directives translated, \(result.skippedCount) skipped")

        if args.dryRun {
            io.out("")
            io.out(result.toml)
            return .succ
        }

        let outputUrl: URL
        if let output = args.output {
            outputUrl = URL(filePath: (output as NSString).expandingTildeInPath)
        } else {
            switch findCustomConfigUrl() {
                case .noCustomConfigExists:
                    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
                        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/")
                    outputUrl = xdgConfigHome.appending(path: "aerospace").appending(path: "aerospace.toml")
                case .file(let existing):
                    return .fail(io.err("A config already exists at '\(existing.path)'. Pass --output <path> to write elsewhere (the existing config is never overwritten)"))
                case .ambiguousConfigError(let candidates):
                    return .fail(io.err("Multiple configs already exist: \(candidates.map(\.path).joined(separator: ", ")). Pass --output <path>"))
            }
        }
        if FileManager.default.fileExists(atPath: outputUrl.path) {
            return .fail(io.err("'\(outputUrl.path)' already exists. The importer never overwrites files"))
        }

        do {
            try FileManager.default.createDirectory(at: outputUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.toml.write(to: outputUrl, atomically: true, encoding: .utf8)
        } catch {
            return .fail(io.err("Can't write '\(outputUrl.path)': \(error.localizedDescription)"))
        }
        io.out("Written to \(outputUrl.path). Run 'aerospace reload-config' to apply")
        return .succ
    }
}
