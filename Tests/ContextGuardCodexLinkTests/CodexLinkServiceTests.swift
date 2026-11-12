import XCTest
import ContextGuardCodexLink

/// The background link's `--env NAME=value` arguments (`context-guard-link.exe` on Windows).
final class CodexLinkServiceTests: XCTestCase {
    let base = ["PATH": "C:\\Windows", "CODEX_HOME": "C:\\Users\\me\\.codex"]

    func environment(_ arguments: [String]) throws -> [String: String] {
        try CodexLinkService.environment(arguments, base: base)
    }

    func refusal(_ arguments: [String]) -> CodexLinkService.ArgumentError? {
        do {
            _ = try environment(arguments)
            return nil
        } catch {
            return error as? CodexLinkService.ArgumentError
        }
    }

    func testNoArgumentsKeepTheEnvironment() throws {
        XCTAssertEqual(try environment([]), base)
    }

    func testSetsEachAllowedName() throws {
        let env = try environment([
            "--env", "CODEX_HOME=D:\\codex",
            "--env", "CLAUDE_CONFIG_DIR=D:\\claude config",
            "--env", "CONTEXT_GUARD_HOME=D:\\guard",
        ])
        XCTAssertEqual(env, [
            "PATH": "C:\\Windows",
            "CODEX_HOME": "D:\\codex",
            "CLAUDE_CONFIG_DIR": "D:\\claude config",
            "CONTEXT_GUARD_HOME": "D:\\guard",
        ])
    }

    func testTheLastOneForANameWins() throws {
        let env = try environment(["--env", "CONTEXT_GUARD_HOME=D:\\one", "--env", "CONTEXT_GUARD_HOME=D:\\two"])
        XCTAssertEqual(env["CONTEXT_GUARD_HOME"], "D:\\two")
    }

    func testTheValueIsEverythingAfterTheFirstEquals() throws {
        XCTAssertEqual(try environment(["--env", "CODEX_HOME=D:\\a=b"])["CODEX_HOME"], "D:\\a=b")
        XCTAssertEqual(try environment(["--env", "CODEX_HOME="])["CODEX_HOME"], "")
    }

    func testRefusesAnythingElse() {
        XCTAssertEqual(refusal(["--only-cwd", "D:\\x"]), .unknown("--only-cwd"))
        XCTAssertEqual(refusal(["CODEX_HOME=D:\\x"]), .unknown("CODEX_HOME=D:\\x"))
        XCTAssertEqual(refusal(["--env"]), .missingValue)
        XCTAssertEqual(refusal(["--env", "CODEX_HOME=D:\\x", "--env"]), .missingValue)
        XCTAssertEqual(refusal(["--env", "CODEX_HOME"]), .notAssignment("CODEX_HOME"))
        XCTAssertEqual(refusal(["--env", "=D:\\x"]), .notAssignment("=D:\\x"))
        XCTAssertEqual(refusal(["--env", "PATH=D:\\x"]), .notAllowed("PATH"))
        XCTAssertEqual(refusal(["--env", "codex_home=D:\\x"]), .notAllowed("codex_home"))
    }

    func testRefusalsSayWhatIsAllowed() {
        XCTAssertEqual(CodexLinkService.ArgumentError.notAllowed("PATH").description,
                       "--env PATH: only CLAUDE_CONFIG_DIR, CODEX_HOME, CONTEXT_GUARD_HOME")
        XCTAssertEqual(CodexLinkService.ArgumentError.missingValue.description, "--env needs NAME=value")
        XCTAssertEqual(CodexLinkService.ArgumentError.notAssignment("x").description, "--env x: not NAME=value")
        XCTAssertEqual(CodexLinkService.ArgumentError.unknown("-v").description, "unknown argument -v")
    }
}
