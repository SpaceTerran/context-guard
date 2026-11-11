import ContextGuardTestSupport
import XCTest
@testable import ContextGuardCore

/// What the core asks of the operating system, the same on the Mac and Windows.
final class PlatformTests: XCTestCase {
    let dir = TempDir()

    // MARK: - Paths

    func testMacPathsCompareAsTheyAre() {
        XCTAssertEqual(PathRules.key("/Users/x/Code", windows: false), "/Users/x/Code")
        XCTAssertTrue(PathRules.isSameOrInside("/Users/x/code", "/Users/x/code", windows: false))
        XCTAssertTrue(PathRules.isSameOrInside("/Users/x/code/a", "/Users/x/code", windows: false))
        XCTAssertTrue(PathRules.isSameOrInside("/Users/x/code/a", "/Users/x/code/", windows: false))
        XCTAssertFalse(PathRules.isSameOrInside("/Users/x/codex", "/Users/x/code", windows: false), "a sibling with a longer name")
        XCTAssertFalse(PathRules.isSameOrInside("/Users/x/Code", "/Users/x/code", windows: false), "case counts")
    }

    func testWindowsPathsIgnoreCaseAndSeparator() {
        XCTAssertEqual(PathRules.native("C:/Users/x/code/", windows: true), "C:\\Users\\x\\code")
        XCTAssertEqual(PathRules.native("C:\\", windows: true), "C:\\", "a drive's root keeps its separator")
        XCTAssertEqual(PathRules.native("C:/", windows: true), "C:\\")
        XCTAssertEqual(PathRules.native("\\\\server\\share\\", windows: true), "\\\\server\\share")
        XCTAssertEqual(PathRules.key("C:/Users/X/Code\\", windows: true), "c:\\users\\x\\code")
        XCTAssertTrue(PathRules.isSameOrInside("c:\\users\\x\\code", "C:/Users/X/Code", windows: true))
        XCTAssertTrue(PathRules.isSameOrInside("C:\\Users\\x\\code\\a", "c:\\users\\x\\code\\", windows: true))
        XCTAssertTrue(PathRules.isSameOrInside("C:\\a", "C:\\", windows: true), "inside a drive's root")
        XCTAssertFalse(PathRules.isSameOrInside("C:\\Users\\x\\codex", "C:\\Users\\x\\code", windows: true))
    }

    func testHomeShowsAsATilde() {
        XCTAssertEqual(PathRules.abbreviating("C:\\Users\\x\\code\\app", home: "C:/Users/X", windows: true), "~\\code\\app")
        XCTAssertEqual(PathRules.abbreviating("c:\\users\\x", home: "C:\\Users\\x", windows: true), "~")
        XCTAssertEqual(PathRules.abbreviating("C:\\Users\\xy\\code", home: "C:\\Users\\x", windows: true), "C:\\Users\\xy\\code")
        XCTAssertEqual(PathRules.abbreviating("D:\\work", home: "C:\\Users\\x", windows: true), "D:\\work")
        // This platform's own rule, on its own home folder.
        let home = NSHomeDirectory()
        let separator = PathRules.isWindows ? "\\" : "/"
        XCTAssertEqual(PathRules.abbreviatingHome(home), "~")
        XCTAssertEqual(PathRules.abbreviatingHome(home + separator + "code"), "~" + separator + "code")
    }

    // MARK: - Processes

    func testAWindowsStartTimeIsOnTheUnixClock() {
        XCTAssertEqual(ProcessStart(windowsFileTime: 116_444_736_000_000_000), ProcessStart(seconds: 0, microseconds: 0))
        XCTAssertEqual(ProcessStart(windowsFileTime: 116_444_736_015_000_007), ProcessStart(seconds: 1, microseconds: 500_000))
        // 2026-11-11 00:00:00 UTC.
        XCTAssertEqual(ProcessStart(windowsFileTime: 134_388_288_000_000_000).seconds, 1_794_355_200)
    }

    func testThisProcessIsRunning() throws {
        let probe = SystemProcessProbe()
        let me = ProcessInfo.processInfo.processIdentifier
        let id = try XCTUnwrap(probe.identity(of: me))
        let now = Date().timeIntervalSince1970
        XCTAssertLessThanOrEqual(Double(id.start.seconds), now)
        XCTAssertGreaterThan(Double(id.start.seconds), now - 3600, "started within the hour")
        XCTAssertTrue((0..<1_000_000).contains(id.start.microseconds))
        XCTAssertEqual(probe.identity(of: me)?.start, id.start, "the same every time")
        XCTAssertTrue(probe.isRunning(me, startedAt: id.start))
        XCTAssertFalse(probe.isRunning(me, startedAt: ProcessStart(seconds: id.start.seconds - 1, microseconds: 0)), "another process with this pid")
        XCTAssertNil(probe.identity(of: 0))
        #if os(Windows)
        XCTAssertNil(id.hasTTY, "Windows has no controlling terminal")
        #else
        XCTAssertNotNil(id.hasTTY)
        #endif
    }

    func testAProcessThatEndedIsntRunning() throws {
        let child = Process()
        #if os(Windows)
        child.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe")
        child.arguments = ["/c", "exit", "0"]
        #else
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        #endif
        try child.run()
        child.waitUntilExit()
        // The Process object still holds the ended process (Windows keeps it while a handle is open).
        XCTAssertNil(SystemProcessProbe().identity(of: child.processIdentifier))
    }

    // MARK: - Files

    func testAFileOpenForReadingCanStillBeRenamedOrRemoved() throws {
        let file = dir.file("rollout.jsonl")
        try Data("one\n".utf8).write(to: file)
        let handle = try XCTUnwrap(SharedFile.openForReading(file.path))
        defer { try? handle.close() }
        let before = try XCTUnwrap(SharedFile.identity(handle))
        XCTAssertEqual(before.size, 4)
        // As `codex archive` moves a rollout, while it's being read.
        let moved = dir.file("archived.jsonl")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(try handle.read(upToCount: 3), Data("one".utf8), "the open file reads on")
        XCTAssertEqual(SharedFile.identity(handle)?.id, before.id, "still the same file")
        try FileManager.default.removeItem(at: moved)
    }

    func testAReplacedFileIsANewFile() throws {
        let file = dir.file("t.jsonl")
        try Data("one\n".utf8).write(to: file)
        let first = try XCTUnwrap(SharedFile.openForReading(file.path))
        let a = try XCTUnwrap(SharedFile.identity(first))
        try Data("two lines\n".utf8).write(to: file, options: .atomic)
        let second = try XCTUnwrap(SharedFile.openForReading(file.path))
        let b = try XCTUnwrap(SharedFile.identity(second))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(b.size, 10)
        try first.close()
        try second.close()
        XCTAssertNil(SharedFile.openForReading(dir.file("missing").path))
    }

    func testASaveWaitsOutAProgramBrieflyHoldingTheFile() throws {
        let file = dir.file("state.json")
        try FileIO.writeJSON(["n": 1], to: file)
        // An ordinary reader (as antivirus opens it): on Windows it blocks the rename while it's open.
        let holder = try XCTUnwrap(FileHandle(forReadingAtPath: file.path))
        let released = expectation(description: "released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            try? holder.close()
            released.fulfill()
        }
        XCTAssertNoThrow(try FileIO.writeJSON(["n": 2], to: file))
        wait(for: [released], timeout: 2)
        XCTAssertEqual(FileIO.readJSON([String: Int].self, from: file), ["n": 2])
    }

    func testOnlyOneHolderOfALock() throws {
        let url = dir.file("s.lock")
        let first = try XCTUnwrap(FileLock.acquire(url, timeout: 0))
        let started = Date()
        XCTAssertNil(FileLock.acquire(url, timeout: 0.1), "busy")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09, "it kept trying until the timeout")
        let waited = expectation(description: "the waiter got it")
        DispatchQueue.global().async {
            if let lock = FileLock.wait(url) {
                lock.release()
                waited.fulfill()
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        first.release()
        wait(for: [waited], timeout: 2)
        XCTAssertNotNil(FileLock.acquire(url, timeout: 0), "free again")
    }

    func testAFileRenamedIntoAFolderIsNoticed() throws {
        let folder = dir.file("answers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let noticed = expectation(description: "noticed")
        noticed.assertForOverFulfill = false
        let watcher = FolderWatcher(folder) { noticed.fulfill() }
        try FileIO.writeJSON(["action": "yes"], to: folder.appendingPathComponent("s1.json"))
        wait(for: [noticed], timeout: 2)
        withExtendedLifetime(watcher) {}
    }

    func testAWatcherStopsWhenLetGo() throws {
        let folder = dir.file("answers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date()
        for _ in 0..<20 { _ = FolderWatcher(folder) {} }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "each stops at once")
        _ = FolderWatcher(dir.file("missing")) {}
    }
}
