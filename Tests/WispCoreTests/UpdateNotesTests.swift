import Testing
@testable import WispCore

private let notes = ["0.4.0", "0.5.0", "0.6.0"]

@Test func firstInstallShowsNothing() {
    #expect(UpdateNotes.decide(stored: nil, earlierTraces: false, running: "0.5.0", notes: notes) == .firstInstall)
    #expect(UpdateNotes.remembered(stored: nil, running: "0.5.0") == "0.5.0")
}

@Test func sameVersionShowsNothing() {
    #expect(UpdateNotes.decide(stored: "0.5.0", earlierTraces: true, running: "0.5.0", notes: notes) == .nothingNew)
}

@Test func upgradeShowsTheNewVersion() {
    #expect(UpdateNotes.decide(stored: "0.4.0", earlierTraces: true, running: "0.5.0", notes: notes)
        == .show(from: "0.4.0", versions: ["0.5.0"]))
}

@Test func settingsFromBeforeTheRecordCountAsAnUpgrade() {
    // 0.4 kept no version, so its settings alone mean someone is updating from it.
    #expect(UpdateNotes.decide(stored: nil, earlierTraces: true, running: "0.5.0", notes: notes)
        == .show(from: UpdateNotes.lastUnrecorded, versions: ["0.5.0"]))
}

@Test func skippedVersionsShowEveryNewerVersionNewestFirst() {
    #expect(UpdateNotes.decide(stored: "0.3.0", earlierTraces: true, running: "0.6.0", notes: notes)
        == .show(from: "0.3.0", versions: ["0.6.0", "0.5.0", "0.4.0"]))
    // Notes for a version newer than the one running stay out.
    #expect(UpdateNotes.decide(stored: "0.3.0", earlierTraces: true, running: "0.5.0", notes: notes)
        == .show(from: "0.3.0", versions: ["0.5.0", "0.4.0"]))
}

@Test func downgradeShowsNothingAndKeepsTheNewerVersion() {
    #expect(UpdateNotes.decide(stored: "0.6.0", earlierTraces: true, running: "0.5.0", notes: notes) == .nothingNew)
    #expect(UpdateNotes.remembered(stored: "0.6.0", running: "0.5.0") == "0.6.0")
    // Back on 0.6 after the downgrade: its notes were already seen.
    #expect(UpdateNotes.decide(stored: UpdateNotes.remembered(stored: "0.6.0", running: "0.5.0"), earlierTraces: true,
                               running: "0.6.0", notes: notes) == .nothingNew)
}

@Test func updateWithoutNotesShowsNothing() {
    #expect(UpdateNotes.decide(stored: "0.5.0", earlierTraces: true, running: "0.5.1", notes: notes) == .nothingNew)
    #expect(UpdateNotes.remembered(stored: "0.5.0", running: "0.5.1") == "0.5.1")
}

@Test func shownOnceThenRemembered() {
    let stored = UpdateNotes.remembered(stored: "0.4.0", running: "0.5.0")
    #expect(UpdateNotes.decide(stored: stored, earlierTraces: true, running: "0.5.0", notes: notes) == .nothingNew)
}

@Test func shortNamesDropTrailingZeros() {
    #expect(UpdateNotes.shortName("0.5.0") == "0.5")
    #expect(UpdateNotes.shortName("0.5.1") == "0.5.1")
    #expect(UpdateNotes.shortName("1.0.0") == "1.0")
}
