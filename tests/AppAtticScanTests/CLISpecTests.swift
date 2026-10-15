import Foundation
import XCTest
@testable import AppAtticScan

/// clispec v0.3: the document, the output flag, and the real `appattic` binary.
final class CLISpecTests: XCTestCase {
    func testOutputFlagFollowsTheTerminalUnlessSet() {
        XCTAssertTrue(cliOutputIsJSON(flag: "json", stdoutIsTTY: true))
        XCTAssertFalse(cliOutputIsJSON(flag: "text", stdoutIsTTY: false))
        XCTAssertFalse(cliOutputIsJSON(flag: "auto", stdoutIsTTY: true))
        XCTAssertTrue(cliOutputIsJSON(flag: "auto", stdoutIsTTY: false))
        XCTAssertTrue(cliOutputIsJSON(flag: "nope", stdoutIsTTY: false))
    }

    func testOutputFlagIsAcceptedBeforeTheCommand() {
        let opts = parseCLIArguments(["-o", "json", "config"])
        XCTAssertEqual(opts.command, "config")
        XCTAssertEqual(opts.output, "json")
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["--output=text", "erase"]).output, "text")
        XCTAssertEqual(parseCLIArguments(["config", "--output", "json"]).output, "json")
        XCTAssertEqual(parseCLIArguments(["--output", "yaml"]).parseError, .outputRequiresMode)
        XCTAssertEqual(parseCLIArguments(["--output"]).parseError, .outputRequiresMode)
    }

    func testSchemaPathKeepsLaterWords() {
        let opts = parseCLIArguments(["schema", "config"])
        XCTAssertEqual(opts.command, "schema")
        XCTAssertEqual(opts.schemaPath, ["config"])
        XCTAssertNil(opts.error)
        XCTAssertEqual(parseCLIArguments(["schema"]).schemaPath, [])
    }

    func testHelpMentionsSchemaAndOutput() {
        XCTAssertTrue(cliHelpText.contains("schema [CMD]"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("-o, --output MODE"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("schema always prints JSON"), cliHelpText)
        XCTAssertTrue(cliHelpText.contains("appattic schema"), cliHelpText)
    }

    func testSpecDocumentAndFilter() throws {
        let doc = try jsonObject(cliSpecJSON())
        XCTAssertEqual(doc["clispec"] as? String, "0.3")
        XCTAssertEqual(doc["name"] as? String, "appattic")
        XCTAssertEqual(doc["version"] as? String, appAtticVersion)
        let output = doc["output"] as? [String: Any]
        XCTAssertEqual(output?["tty"] as? String, "text")
        XCTAssertEqual(output?["piped"] as? String, "json")
        let commands = doc["commands"] as? [[String: Any]] ?? []
        XCTAssertFalse(commands.isEmpty)
        let names = Set(commands.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("schema"))
        XCTAssertTrue(names.contains("config"))
        XCTAssertTrue(names.contains("erase"))
        XCTAssertTrue(names.contains("update"))
        let erase = commands.first { $0["name"] as? String == "erase" }
        XCTAssertEqual(erase?["effects"] as? String, "idempotent")
        let update = commands.first { $0["name"] as? String == "update" }
        XCTAssertEqual(update?["effects"] as? String, "non_idempotent")
        XCTAssertEqual(update?["confirmation_bypass_arg"] as? String, "--yes")
        let schema = commands.first { $0["name"] as? String == "schema" }
        XCTAssertEqual(schema?["output_kind"] as? String, "opaque")
        XCTAssertEqual(schema?["media_type"] as? String, "application/json")
        let errors = doc["errors"] as? [[String: Any]] ?? []
        let usage = errors.first { $0["kind"] as? String == "usage" }
        XCTAssertEqual(usage?["exit_code"] as? Int, 2)
        let failure = errors.first { $0["kind"] as? String == "failure" }
        XCTAssertEqual(failure?["exit_code"] as? Int, 1)

        let filtered = try jsonObject(cliSpecJSON(path: ["config"]))
        let kept = filtered["commands"] as? [[String: Any]] ?? []
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["name"] as? String, "config")
        XCTAssertThrowsError(try cliSpecJSON(path: ["nope"])) { error in
            XCTAssertEqual(error as? CLISpecError, .noMatch("nope"))
        }
    }

    func testErrorEnvelopeIsOneJSONLine() throws {
        let line = cliErrorEnvelope(kind: "usage", message: "unknown option: --nope", hint: "try --help")
        XCTAssertTrue(line.hasSuffix("\n"))
        let trimmed = line.trimmingCharacters(in: .newlines)
        let obj = try jsonObject(Data(trimmed.utf8))
        let err = obj["error"] as? [String: Any]
        XCTAssertEqual(err?["kind"] as? String, "usage")
        XCTAssertEqual(err?["message"] as? String, "unknown option: --nope")
        XCTAssertEqual(err?["hint"] as? String, "try --help")
        XCTAssertFalse(trimmed.contains("\n"))
    }

    func testSchemaExitsZeroWithoutConfig() throws {
        let root = try makeRoot()
        let (status, stdout, stderr) = try runCLI(["schema"], root: root)
        XCTAssertEqual(status, 0, stderr)
        let doc = try jsonObject(Data(stdout.utf8))
        XCTAssertEqual(doc["clispec"] as? String, "0.3")
        XCTAssertEqual(doc["name"] as? String, "appattic")
        XCTAssertEqual(doc["version"] as? String, appAtticVersion)
        XCTAssertNotNil(doc["commands"])
        XCTAssertNotNil(doc["errors"])
        let settings = root.appendingPathComponent("xdg-data/appattic/settings.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testConfigJSONShapeAndTextMode() throws {
        let root = try makeRoot()
        let (status, stdout, stderr) = try runCLI(["-o", "json", "config"], root: root)
        XCTAssertEqual(status, 0, stderr)
        let doc = try jsonObject(Data(stdout.utf8))
        XCTAssertNotNil(doc["settingsPath"] as? String)
        XCTAssertNotNil(doc["settingsFileExists"] as? Bool)
        XCTAssertNotNil(doc["includeSystem"] as? Bool)
        XCTAssertNotNil(doc["ignoredLeftoverPaths"] as? [Any])
        let text = try runCLI(["-o", "text", "config"], root: root)
        XCTAssertEqual(text.0, 0, text.2)
        let body = text.1.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(body.contains("settings file:"), body)
        XCTAssertFalse(body.hasPrefix("{"), body)
    }

    func testJSONUsageFailureEnvelopeIsTheLastStderrLine() throws {
        let root = try makeRoot()
        let (status, stdout, stderr) = try runCLI(["--output", "json", "--nope"], root: root)
        XCTAssertEqual(status, 2)
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "")
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true)
        let last = String(lines.last ?? "")
        let obj = try jsonObject(Data(last.utf8))
        let err = obj["error"] as? [String: Any]
        XCTAssertEqual(err?["kind"] as? String, "usage")
        XCTAssertEqual(err?["message"] as? String, "unknown option: --nope")
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appattic-clispec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func cliBinary() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var candidates = [
            root.appendingPathComponent(".build/debug/appattic"),
            root.appendingPathComponent(".build/release/appattic"),
        ]
        let build = root.appendingPathComponent(".build")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: build, includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                candidates.append(entry.appendingPathComponent("debug/appattic"))
                candidates.append(entry.appendingPathComponent("release/appattic"))
            }
        }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        XCTFail("no built appattic under \(build.path)")
        throw CLISpecError.noMatch("binary")
    }

    private func runCLI(_ args: [String], root: URL) throws -> (Int32, String, String) {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = root.appendingPathComponent("home").path
        env["XDG_DATA_HOME"] = root.appendingPathComponent("xdg-data").path
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("xdg-config").path
        env["XDG_CACHE_HOME"] = root.appendingPathComponent("xdg-cache").path
        env["XDG_STATE_HOME"] = root.appendingPathComponent("xdg-state").path
        env["XDG_RUNTIME_DIR"] = root.appendingPathComponent("xdg-runtime").path
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        env["TZ"] = "UTC"
        env["TERM"] = "dumb"
        env.removeValue(forKey: "NO_COLOR")

        let process = Process()
        process.executableURL = try cliBinary()
        process.arguments = args
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.close()

        let stdoutBox = Box()
        let stderrBox = Box()
        let drained = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutBox.text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrBox.text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            group.leave()
        }
        group.notify(queue: .global()) { drained.signal() }
        if drained.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            XCTFail("appattic \(args) did not exit")
            _ = drained.wait(timeout: .now() + 5)
        } else {
            process.waitUntilExit()
        }
        return (process.terminationStatus, stdoutBox.text, stderrBox.text)
    }

    private final class Box {
        var text = ""
    }
}
