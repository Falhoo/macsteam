// Upload-folder names on online-fix.me: a title's trailing "?" is typed in the
// game's name, not in the folder, so "RV There Yet?" lives under "RV There Yet".
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixSourceTests {

    @Test
    func trailingQuestionMarkIsTriedWithoutIt() {
        let variants = FixSource.nameVariants("RV There Yet?")
        #expect(variants.contains("RV There Yet"))
        #expect(variants.contains("RV There Yet?"))
    }

    @Test
    func trailingPunctuationOtherThanQuestionMarkIsStripped() {
        #expect(FixSource.nameVariants("Who Wants to Be a Millionaire!").contains(
            "Who Wants to Be a Millionaire"))
        #expect(FixSource.nameVariants("Game: Deluxe?").contains("Game: Deluxe"))
    }

    @Test
    func separatorsAreAlsoTried() {
        let variants = FixSource.nameVariants("RV There Yet?")
        #expect(variants.contains("RV.There.Yet"))
        #expect(variants.contains("RV_There_Yet"))
    }

    @Test
    func trademarkAndCurlyApostropheAreDropped() {
        let variants = FixSource.nameVariants("Garry's Mod™")
        #expect(variants.contains("Garrys Mod"))
    }

    @Test
    func namesAreDeduplicatedAndBlankIsEmpty() {
        let variants = FixSource.nameVariants("Game")
        #expect(variants.filter { $0 == "Game" }.count == 1)
        #expect(FixSource.nameVariants("   ").isEmpty)
    }

    @Test
    func filesAreRecognisedAsFixArchives() {
        #expect(FixSource.isArchive("RVThereYet_Fix_Repair_Steam_V2_Generic.rar"))
        #expect(!FixSource.isArchive("dlllist.txt"))
    }

    @Test
    func exactNameIgnoresPunctuation() {
        #expect(FixSource.similarity("RV There Yet?", "RV There Yet") == 1)
        #expect(FixSource.similarity("Garry's Mod", "Garrys Mod") == 1)
    }

    @Test
    func editionAndSubtitleAreDroppedForSearch() {
        let edition = FixSource.similarNameCandidates("RV There Yet Deluxe Edition")
        #expect(edition.contains { $0.caseInsensitiveCompare("RV There Yet") == .orderedSame })
        #expect(FixSource.similarNameCandidates("Game: Subtitle").contains("Game"))
        #expect(FixSource.similarNameCandidates("Game - Subtitle").contains("Game"))
    }

    @Test
    func yearsLeadingTheAndSoundtrackAreDropped() {
        #expect(FixSource.similarNameCandidates("The Game").contains("Game"))
        #expect(FixSource.similarNameCandidates("Game 2024").contains("Game"))
        #expect(FixSource.similarNameCandidates("Game Soundtrack").contains("Game"))
    }

    @Test
    func relatedNamesScoreAboveUnrelatedOnes() {
        let related = FixSource.similarity("RV There Yet Soundtrack", "RV There Yet")
        let unrelated = FixSource.similarity("Elden Ring", "RV There Yet")
        #expect(related > unrelated)
        #expect(related > 0.5)
    }

    @Test
    func onlyTheGamesOwnNameCountsAsExact() {
        // "RV There Yet" for a game called "RV There Yet?" is a similar match, so
        // the app asks before installing it.
        let similar = FixSource.FolderMatch(
            name: "RV There Yet",
            url: URL(string: "https://uploads.online-fix.me:2053/uploads/RV%20There%20Yet/")!,
            score: FixSource.similarity("RV There Yet", "RV There Yet?"),
            isExact: false)
        #expect(!similar.isExact)
        #expect(similar.id == "RV There Yet")

        let same = FixSource.FolderMatch(
            name: "ELDEN RING",
            url: URL(string: "https://uploads.online-fix.me:2053/uploads/ELDEN%20RING/")!,
            score: 1,
            isExact: true)
        #expect(same.isExact)
    }
}
