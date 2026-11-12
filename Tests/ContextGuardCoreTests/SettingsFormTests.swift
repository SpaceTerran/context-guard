import XCTest
@testable import ContextGuardCore

/// Settings as you edit it: what's saved and when, and what each card says about it.
final class SettingsFormTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_100)
    /// The settings on "disk": each save changes them, unless it fails.
    var disk = Config()
    var saves = 0
    var failure: String?

    func save(_ change: @escaping (inout Config) -> Void) -> String? {
        saves += 1
        if let failure { return failure }
        change(&disk)
        return nil
    }

    func form() -> SettingsForm { SettingsForm(disk) }

    func testItStartsFromTheSettings() {
        disk.askAt = 250_000
        disk.laterAt = 450_000
        disk.codexAskPercent = 50
        disk.codexLaterPercent = 70
        disk.autoYesSeconds = 30
        disk.message = "save"
        disk.continueMessage = "go on"
        let f = form()
        XCTAssertEqual(SettingsForm.Field.allCases.filter(\.isNumber).map(f.number), [250, 450, 50, 70, 30])
        XCTAssertEqual(SettingsForm.Field.allCases.map(f.text), ["250", "450", "50", "70", "30", "save", "go on"])
        XCTAssertEqual(f.number(.message), 0)
        XCTAssertEqual(SettingsForm.Field.allCases.map(f.status), Array(repeating: SaveStatus.unchanged, count: 7))
        XCTAssertEqual(f.whenToAskStatus, .unchanged)
    }

    func testANumberIsSavedAsTyped() {
        var f = form()
        f.set(.askK, typed: " 200 ", now: t0, save: save)
        XCTAssertEqual(f.askK, 200)
        XCTAssertEqual(disk.askAt, 200_000)
        XCTAssertEqual(disk.laterAt, 500_000)
        XCTAssertEqual(f.claudeStatus, .saved(t0))
        XCTAssertEqual(f.status(.laterK), .saved(t0), "one card for both")
        XCTAssertEqual(f.claudeNote, SettingsNote(text: SettingsText.claudeThresholdsNote(askK: 200, laterK: 500), tone: .muted))
        XCTAssertEqual(saves, 1)
    }

    func testTheSameValueIsntSavedAgain() {
        var f = form()
        f.set(.askK, typed: "300", now: t0, save: save)
        f.set(.askK, number: 300, now: t0, save: save)
        f.set(.message, typed: Config.defaultMessage, now: t0, save: save)
        f.restore(.continueMessage, now: t0, save: save)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(f.claudeStatus, .unchanged)
        XCTAssertEqual(f.messageSaved, .unchanged)
    }

    func testThresholdsThatDontMakeSenseArentSaved() {
        var f = form()
        f.set(.laterK, typed: "250", now: t0, save: save)
        let problem = "“If you choose Wait, compact at” has to be more than “Ask at”."
        XCTAssertEqual(f.laterK, 250, "the field keeps what you typed")
        XCTAssertEqual(disk.laterAt, 500_000)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(f.thresholdProblem, problem)
        XCTAssertEqual(f.claudeStatus, .notSaved(problem))
        XCTAssertEqual(f.whenToAskStatus, .notSaved(problem))
        XCTAssertEqual(f.claudeNote, SettingsNote(text: problem, tone: .danger))
        XCTAssertEqual(f.whenToAskNote, SettingsNote(text: problem, tone: .danger))
        XCTAssertTrue(f.invalid(.askK))
        XCTAssertTrue(f.invalid(.laterK))

        f.set(.askK, typed: "200", now: t0, save: save)
        XCTAssertNil(f.thresholdProblem)
        XCTAssertEqual(disk.askAt, 200_000)
        XCTAssertEqual(disk.laterAt, 250_000, "both go together once they make sense")
        XCTAssertEqual(f.claudeStatus, .saved(t0))
        XCTAssertFalse(f.invalid(.askK))
        XCTAssertFalse(f.invalid(.laterK))
    }

    func testAnEmptyThresholdNeedsANumber() {
        var f = form()
        f.set(.askK, typed: "", now: t0, save: save)
        XCTAssertEqual(f.askK, 0)
        XCTAssertEqual(f.thresholdProblem, "“Ask at” needs a number, like 300.")
        XCTAssertTrue(f.invalid(.askK))
        XCTAssertFalse(f.invalid(.laterK), "only the empty one is marked")
        XCTAssertEqual(saves, 0)
    }

    func testCodexsPairIsSavedTogetherOnceItMakesSense() {
        var f = form()
        f.set(.codexAsk, typed: "78", now: t0, save: save)
        XCTAssertEqual(f.codexProblem, "Codex's “If you choose Wait, compact at” has to be at least 5% more than its “Ask at”.")
        XCTAssertEqual(f.codexStatus, .notSaved(f.codexProblem!))
        XCTAssertEqual(f.codexNote.tone, .danger)
        XCTAssertFalse(f.invalid(.codexAsk))
        XCTAssertTrue(f.invalid(.codexLater))
        XCTAssertEqual(saves, 0)

        f.set(.codexLater, typed: "84", now: t0, save: save)
        XCTAssertEqual(disk.codexAskPercent, 78)
        XCTAssertEqual(disk.codexLaterPercent, 84)
        XCTAssertEqual(f.codexStatus, .saved(t0))
        XCTAssertEqual(f.codexNote, SettingsNote(text: SettingsText.codexThresholdsNote(ask: 78, later: 84), tone: .muted))

        f.set(.codexAsk, typed: "5", now: t0, save: save)
        XCTAssertTrue(f.invalid(.codexAsk))
        XCTAssertFalse(f.invalid(.codexLater), "only Ask at is marked while it's out of range")
        XCTAssertEqual(disk.codexAskPercent, 78)
        XCTAssertEqual(f.claudeStatus, .unchanged, "Claude Code's card is its own")
    }

    func testTheCountdownSavesAsTyped() {
        var f = form()
        f.set(.autoYes, typed: "0", now: t0, save: save)
        XCTAssertEqual(disk.autoYesSeconds, 0)
        XCTAssertEqual(f.countdownStatus, .saved(t0))
        XCTAssertEqual(f.countdownNote, SettingsNote(text: SettingsText.countdownNote(0), tone: .muted))
        XCTAssertEqual(f.whenToAskNote, SettingsNote(text: SettingsText.whenToAskNote(askK: 300, laterK: 500, autoYes: 0), tone: .muted))
    }

    func testWhenToAskShowsTheLaterSave() {
        var f = form()
        let t1 = t0.addingTimeInterval(5), t2 = t0.addingTimeInterval(10)
        f.set(.autoYes, typed: "30", now: t0, save: save)
        f.set(.askK, typed: "200", now: t1, save: save)
        XCTAssertEqual(f.whenToAskStatus, .saved(t1))
        f.set(.autoYes, typed: "45", now: t2, save: save)
        XCTAssertEqual(f.whenToAskStatus, .saved(t2))
        f.set(.laterK, typed: "100", now: t2, save: save)
        XCTAssertEqual(f.whenToAskStatus, .notSaved(f.thresholdProblem!), "a problem shows over any save")
    }

    func testMessagesSaveAsTypedAndCanBeRestored() {
        var f = form()
        f.set(.message, typed: "", now: t0, save: save)
        XCTAssertEqual(disk.message, "")
        XCTAssertEqual(f.status(.message), .saved(t0))
        XCTAssertEqual(f.messageNote(.message), SettingsNote(text: Words.Settings.emptySendsDefault, tone: .warning))
        XCTAssertTrue(f.canRestore(.message))
        XCTAssertFalse(f.canRestore(.continueMessage))
        XCTAssertFalse(f.canRestore(.askK))

        f.restore(.message, now: t0, save: save)
        XCTAssertEqual(disk.message, Config.defaultMessage)
        XCTAssertFalse(f.canRestore(.message))
        XCTAssertEqual(f.messageNote(.message), SettingsNote(text: Words.Settings.beforeCompactingAbout, tone: .muted))

        f.set(.continueMessage, typed: "keep going", now: t0, save: save)
        XCTAssertEqual(disk.continueMessage, "keep going")
        XCTAssertEqual(f.status(.continueMessage), .saved(t0))
        XCTAssertEqual(f.messageNote(.continueMessage), SettingsNote(text: Words.Settings.afterCompactingAbout, tone: .muted))
        f.restore(.continueMessage, now: t0, save: save)
        XCTAssertEqual(disk.continueMessage, Config.defaultContinueMessage)
        f.restore(.askK, now: t0, save: save)
        XCTAssertEqual(saves, 4, "Restore Default is only for messages")
    }

    func testAFailedSaveSaysWhy() {
        failure = "the disk is full."
        var f = form()
        f.set(.autoYes, typed: "30", now: t0, save: save)
        XCTAssertEqual(f.countdownStatus, .notSaved("the disk is full."))
        XCTAssertEqual(f.autoYes, 30, "the field keeps what you typed")
        f.set(.message, typed: "save now", now: t0, save: save)
        XCTAssertEqual(f.messageNote(.message), SettingsNote(text: "Not saved: the disk is full.", tone: .danger))
        f.set(.askK, typed: "200", now: t0, save: save)
        XCTAssertEqual(f.claudeStatus, .notSaved("the disk is full."))
        XCTAssertEqual(disk, Config(), "nothing changed")

        failure = nil
        f.set(.autoYes, typed: "45", now: t0, save: save)
        XCTAssertEqual(f.countdownStatus, .saved(t0), "the next save that works clears it")
    }

    func testStepsMoveToTheNextStepWithinTheRange() {
        disk.askAt = 320_000
        disk.laterAt = 10_000_000
        disk.codexAskPercent = 10
        disk.codexLaterPercent = 84
        disk.autoYesSeconds = 7
        var f = form()
        f.step(.askK, up: true, showsCodex: false, now: t0, save: save)
        XCTAssertEqual(f.askK, 350, "to the step above")
        f.step(.askK, up: false, showsCodex: false, now: t0, save: save)
        XCTAssertEqual(f.askK, 300, "to the step below")
        f.step(.laterK, up: true, showsCodex: false, now: t0, save: save)
        XCTAssertEqual(f.laterK, 10_000, "the top of its range")
        f.step(.codexAsk, up: false, showsCodex: true, now: t0, save: save)
        XCTAssertEqual(f.codexAsk, 10, "the bottom of its range")
        f.step(.codexLater, up: true, showsCodex: true, now: t0, save: save)
        XCTAssertEqual(f.codexLater, 84)
        f.step(.autoYes, up: false, showsCodex: false, now: t0, save: save)
        XCTAssertEqual(f.autoYes, 0)
        f.step(.autoYes, up: true, showsCodex: true, now: t0, save: save)
        XCTAssertEqual(f.autoYes, 15)
        f.step(.message, up: true, showsCodex: false, now: t0, save: save)
        XCTAssertEqual(disk.askAt, 300_000)
        XCTAssertEqual(disk.autoYesSeconds, 15)
        XCTAssertEqual(saves, 4, "a step that changes nothing saves nothing")
    }

    func testTheCountdownsLabelDependsOnCodex() {
        let f = form()
        XCTAssertEqual(f.field(.autoYes, showsCodex: false).label, "If you don't answer, compact after")
        XCTAssertEqual(f.field(.autoYes, showsCodex: true).label, "Compact after")
        XCTAssertEqual(f.field(.askK, showsCodex: true), SettingsText.askField)
        XCTAssertEqual(f.field(.codexLater, showsCodex: true), SettingsText.codexLaterField)
    }

    func testWhatAFieldHoldsAsTyped() {
        let parse = SettingsText.Field.parse
        XCTAssertEqual(parse("300"), 300)
        XCTAssertEqual(parse(" 300 "), 300)
        XCTAssertEqual(parse(""), 0)
        XCTAssertEqual(parse("3.5"), 0)
        XCTAssertEqual(parse("abc"), 0)
        XCTAssertEqual(parse("-5"), 0)
    }

    func testStepping() {
        let ask = SettingsText.askField
        XCTAssertEqual(ask.stepped(300, up: true), 350)
        XCTAssertEqual(ask.stepped(320, up: true), 350)
        XCTAssertEqual(ask.stepped(320, up: false), 300)
        XCTAssertEqual(ask.stepped(300, up: false), 250)
        XCTAssertEqual(ask.stepped(50, up: false), 50)
        XCTAssertEqual(ask.stepped(0, up: true), 50, "an empty field steps to the first value")
        XCTAssertEqual(ask.stepped(10_000, up: true), 10_000)
        XCTAssertEqual(SettingsText.countdownField(showsCodex: false).stepped(0, up: false), 0)
    }
}
