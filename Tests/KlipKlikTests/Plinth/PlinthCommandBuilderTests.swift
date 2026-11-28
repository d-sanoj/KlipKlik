import Foundation
import Testing
@testable import KlipKlik

/// The builders decide every program and argument that runs, so they are
/// tested argument by argument, against a disk that exists only in memory.
@Suite struct PlinthCommandBuilderTests {
    private let builder = PlinthFakeDisk.builder()

    // MARK: Video

    @Test func videoToMP4AtAHeightCallsFFmpegWithLiteralPathsAndNoOverwrite() throws {
        let items = PlinthFakeDisk.items(["clip.mov"])
        let plan = try builder.plan(PlinthCommand(.convertVideo(to: .mp4, maxHeight: 1080)), for: items)

        let process = try #require(plan.processes.first)
        #expect(process.executable.path == "/opt/homebrew/bin/ffmpeg")
        #expect(Array(process.arguments.prefix(5)) == ["-hide_banner", "-nostdin", "-n", "-i",
                                                         "file:/Users/test/Desktop/clip.mov"])
        #expect(process.arguments.last == "file:/Users/test/Desktop/clip (1080p).mp4")
        #expect(process.arguments.contains("scale=-2:'trunc(min(1080,ih)/2)*2'"))
        #expect(process.arguments.contains("libx264"))
        #expect(process.arguments.contains("+faststart"))
        #expect(process.progressInput == items[0].url)
        #expect(plan.createdNames == ["clip (1080p).mp4"])
        #expect(!plan.isDestructive)
        #expect(plan.missingTools.isEmpty)
        #expect(plan.title == "Convert to MP4 (1080p) · 1 file")
    }

    @Test func sameExtensionGetsASuffixSoItNeverTargetsTheOriginal() throws {
        let plan = try builder.plan(PlinthCommand(.convertVideo(to: .mp4, maxHeight: nil)),
                                    for: PlinthFakeDisk.items(["talk.mp4"]))
        #expect(plan.createdNames == ["talk (converted).mp4"])
    }

    @Test func fourKIsLabelledAsSuch() throws {
        let plan = try builder.plan(PlinthCommand(.convertVideo(to: .mov, maxHeight: 2160)),
                                    for: PlinthFakeDisk.items(["a.mp4"]))
        #expect(plan.createdNames == ["a (4K).mov"])
    }

    @Test func evenDimensionsWithoutAHeight() {
        #expect(PlinthCommandBuilder.scaleFilter(maxHeight: nil) == "scale='trunc(iw/2)*2':'trunc(ih/2)*2'")
    }

    @Test func eachFormatHasItsEncoder() {
        let webm = PlinthCommandBuilder.videoArguments(for: .webm, maxHeight: nil)
        #expect(webm.contains("libvpx-vp9") && webm.contains("libopus"))
        let gif = PlinthCommandBuilder.videoArguments(for: .gif, maxHeight: 480)
        #expect(gif.contains("-an"))
        #expect(gif.joined(separator: " ").contains("palettegen"))
        #expect(gif.joined(separator: " ").contains("min(480,ih)"))
        #expect(PlinthCommandBuilder.videoArguments(for: .mp3, maxHeight: nil).contains("libmp3lame"))
        #expect(PlinthCommandBuilder.videoArguments(for: .m4a, maxHeight: nil).contains("-vn"))
        #expect(PlinthCommandBuilder.videoArguments(for: .wav, maxHeight: nil).contains("pcm_s16le"))
        #expect(!PlinthCommandBuilder.videoArguments(for: .mkv, maxHeight: nil).contains("+faststart"))
    }

    @Test func audioExtractionTakesAudioFilesTooAndIgnoresHeight() throws {
        let plan = try builder.plan(PlinthCommand(.convertVideo(to: .mp3, maxHeight: 720)),
                                    for: PlinthFakeDisk.items(["talk.mov", "memo.m4a", "notes.txt"]))
        #expect(plan.createdNames == ["talk.mp3", "memo.mp3"])
        #expect(plan.skipped.map(\.lastPathComponent) == ["notes.txt"])
        #expect(!plan.processes[0].arguments.contains { $0.hasPrefix("scale") })
    }

    @Test func compressionUsesHEVCWithAnAppleFriendlyTag() throws {
        let plan = try builder.plan(PlinthCommand(.compressVideo(quality: .low, maxHeight: nil)),
                                    for: PlinthFakeDisk.items(["drone.mov"]))
        let arguments = plan.processes[0].arguments
        #expect(arguments.contains("libx265"))
        #expect(arguments.contains("hvc1"))
        #expect(arguments.contains(String(PlinthQuality.low.videoCRF)))
        #expect(plan.createdNames == ["drone (compressed).mp4"])
    }

    @Test func missingFFmpegStillShowsTheCommandAndAsksForTheTool() throws {
        let plan = try PlinthFakeDisk.builder(ffmpeg: false)
            .plan(PlinthCommand(.convertVideo(to: .mp4, maxHeight: nil)), for: PlinthFakeDisk.items(["a.mov"]))
        #expect(plan.missingTools == [.ffmpeg])
        #expect(plan.processes[0].executable == PlinthToolPaths.expectedFFmpeg)
    }

    @Test func outOfRangeHeightIsRefused() {
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.convertVideo(to: .mp4, maxHeight: 99_999)),
                             for: PlinthFakeDisk.items(["a.mov"]))
        }
    }

    @Test func noVideosIsAClearError() {
        #expect(throws: PlinthError.noApplicableItems("None of the selected items are videos.")) {
            try builder.plan(PlinthCommand(.compressVideo(quality: .medium, maxHeight: nil)),
                             for: PlinthFakeDisk.items(["a.jpg"]))
        }
    }

    // MARK: Pictures

    @Test func pictureConversionUsesSipsAndSkipsWhatIsAlreadyThatFormat() throws {
        let plan = try builder.plan(PlinthCommand(.convertImage(to: .jpg)),
                                    for: PlinthFakeDisk.items(["a.heic", "b.jpeg", "c.png", "d.txt"]))
        #expect(plan.createdNames == ["a.jpg", "c.jpg"])
        #expect(Set(plan.skipped.map(\.lastPathComponent)) == ["b.jpeg", "d.txt"])
        let process = plan.processes[0]
        #expect(process.executable.path == "/usr/bin/sips")
        #expect(process.arguments == ["-s", "format", "jpeg", "-s", "formatOptions", "85",
                                      "/Users/test/Desktop/a.heic", "--out", "/Users/test/Desktop/a.jpg"])
    }

    @Test func allAlreadyInTheFormatSaysSo() {
        #expect(throws: PlinthError.noApplicableItems("Those are already PNG.")) {
            try builder.plan(PlinthCommand(.convertImage(to: .png)), for: PlinthFakeDisk.items(["a.png", "b.PNG"]))
        }
    }

    @Test func percentResizeIsWorkedOutFromThePixelSize() throws {
        let plan = try builder.plan(PlinthCommand(.resizeImage(.percent(50))), for: PlinthFakeDisk.items(["a.jpg"]))
        #expect(Array(plan.processes[0].arguments.prefix(3)) == ["-z", "1500", "2000"])
        #expect(plan.createdNames == ["a (50%).jpg"])
    }

    @Test func otherResizesMapToSipsFlags() throws {
        let items = PlinthFakeDisk.items(["a.png"])
        let longest = try builder.plan(PlinthCommand(.resizeImage(.longestSide(1024))), for: items)
        #expect(Array(longest.processes[0].arguments.prefix(2)) == ["-Z", "1024"])
        #expect(longest.createdNames == ["a (1024px).png"])
        let width = try builder.plan(PlinthCommand(.resizeImage(.width(800))), for: items)
        #expect(Array(width.processes[0].arguments.prefix(2)) == ["--resampleWidth", "800"])
        let height = try builder.plan(PlinthCommand(.resizeImage(.height(500))), for: items)
        #expect(Array(height.processes[0].arguments.prefix(2)) == ["--resampleHeight", "500"])
    }

    @Test func aFormatSipsCannotWriteIsResizedToPNG() throws {
        let plan = try builder.plan(PlinthCommand(.resizeImage(.width(400))), for: PlinthFakeDisk.items(["raw.webp"]))
        #expect(plan.createdNames == ["raw (400w).png"])
        #expect(plan.processes[0].arguments.contains("png"))
    }

    @Test func resizeLimitsAndTheNoOpAreRefused() {
        let items = PlinthFakeDisk.items(["a.jpg"])
        #expect(throws: PlinthError.nothingToChange) {
            try builder.plan(PlinthCommand(.resizeImage(.percent(100))), for: items)
        }
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.resizeImage(.percent(0))), for: items)
        }
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.resizeImage(.longestSide(100_000))), for: items)
        }
    }

    @Test func unreadableSizeSkipsThePicture() {
        #expect(throws: PlinthError.self) {
            try PlinthFakeDisk.builder(size: nil).plan(PlinthCommand(.resizeImage(.percent(50))),
                                                       for: PlinthFakeDisk.items(["a.jpg"]))
        }
    }

    @Test func pictureCompressionKeepsHEICAsHEIC() throws {
        let plan = try builder.plan(PlinthCommand(.compressImage(quality: .high)),
                                    for: PlinthFakeDisk.items(["a.HEIC", "b.png"]))
        #expect(plan.createdNames == ["a (compressed).heic", "b (compressed).jpg"])
        #expect(plan.processes[1].arguments.contains(String(PlinthQuality.high.imageQuality)))
    }

    // MARK: Names on disk

    @Test func existingNamesAreNeverOverwritten() throws {
        let plan = try PlinthFakeDisk.builder(existing: ["a.jpg", "a 2.jpg"])
            .plan(PlinthCommand(.convertImage(to: .jpg)), for: PlinthFakeDisk.items(["a.png"]))
        #expect(plan.createdNames == ["a 3.jpg"])
    }

    @Test func twoOutputsInOnePlanNeverCollide() throws {
        let plan = try builder.plan(PlinthCommand(.convertImage(to: .jpg)),
                                    for: PlinthFakeDisk.items(["a.png", "a.heic"]))
        #expect(plan.createdNames == ["a.jpg", "a 2.jpg"])
    }

    @Test func aReadOnlyFolderSendsResultsToTheFallback() throws {
        let plan = try PlinthFakeDisk.builder(writable: false)
            .plan(PlinthCommand(.convertImage(to: .jpg)), for: PlinthFakeDisk.items(["a.png"]))
        #expect(plan.created.first?.deletingLastPathComponent().path == PlinthFakeDisk.fallback.path)
    }

    // MARK: Trash

    @Test func trashingOriginalsIsAddedLastAndMarksThePlanDestructive() throws {
        let items = PlinthFakeDisk.items(["a.png", "b.png"])
        let plan = try builder.plan(PlinthCommand(.convertImage(to: .jpg), trashOriginals: true), for: items)
        #expect(plan.steps.last == .trash(items.map(\.url)))
        #expect(plan.isDestructive)
        #expect(plan.effects.filter { $0.kind == .trash }.count == 2)
    }

    @Test func trashIsIgnoredForActionsThatKeepTheirInputs() {
        #expect(!PlinthCommand(.zip(name: nil), trashOriginals: true).trashOriginals)
        #expect(!PlinthCommand(.mergePDFs(name: nil), trashOriginals: true).trashOriginals)
        #expect(!PlinthCommand(.rename(PlinthRenameRule(prefix: "x")), trashOriginals: true).trashOriginals)
    }

    // MARK: Archives

    @Test func zipUsesRelativeNamesFromTheFolder() throws {
        let plan = try builder.plan(PlinthCommand(.zip(name: "Holiday")),
                                    for: PlinthFakeDisk.items(["-odd name.txt", "Photos/"]))
        let process = try #require(plan.processes.first)
        #expect(process.executable.path == "/usr/bin/zip")
        #expect(process.workingDirectory?.path == PlinthFakeDisk.folder.path)
        #expect(process.arguments == ["-r", "-y", "-q", "-X", "/Users/test/Desktop/Holiday.zip",
                                      "./-odd name.txt", "./Photos", "-x", "*.DS_Store", "__MACOSX/*"])
    }

    @Test func zipNamesDefaultFromTheSelection() throws {
        let one = try builder.plan(PlinthCommand(.zip(name: nil)), for: PlinthFakeDisk.items(["Photos/"]))
        #expect(one.createdNames == ["Photos.zip"])
        let many = try builder.plan(PlinthCommand(.zip(name: nil)), for: PlinthFakeDisk.items(["a", "b"]))
        #expect(many.createdNames == ["Archive.zip"])
    }

    @Test func zipAcrossFoldersIsRefused() {
        let items = PlinthFakeDisk.items(["a.txt"])
            + PlinthFakeDisk.items(["b.txt"], in: URL(fileURLWithPath: "/Users/test/Documents"))
        #expect(throws: PlinthError.self) { try builder.plan(PlinthCommand(.zip(name: nil)), for: items) }
    }

    @Test func zipNameMustBeAFileName() {
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.zip(name: "../../etc")), for: PlinthFakeDisk.items(["a.txt"]))
        }
    }

    @Test func unzipUsesDittoIntoAFreshFolder() throws {
        let plan = try PlinthFakeDisk.builder(existing: ["Photos"])
            .plan(PlinthCommand(.unzip), for: PlinthFakeDisk.items(["Photos.zip"]))
        let process = try #require(plan.processes.first)
        #expect(process.executable.path == "/usr/bin/ditto")
        #expect(process.arguments == ["-x", "-k", "/Users/test/Desktop/Photos.zip", "/Users/test/Desktop/Photos 2"])
    }

    // MARK: PDFs

    @Test func mergeOrdersLikeFinder() throws {
        let plan = try builder.plan(PlinthCommand(.mergePDFs(name: nil)),
                                    for: PlinthFakeDisk.items(["chapter 10.pdf", "chapter 2.pdf", "chapter 1.pdf"]))
        guard case .mergePDFs(let inputs, let output) = try #require(plan.steps.first) else {
            Issue.record("Expected a merge step")
            return
        }
        #expect(inputs.map(\.lastPathComponent) == ["chapter 1.pdf", "chapter 2.pdf", "chapter 10.pdf"])
        #expect(output.lastPathComponent == "Merged.pdf")
    }

    @Test func mergeNeedsTwoPDFs() {
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.mergePDFs(name: nil)), for: PlinthFakeDisk.items(["a.pdf", "b.jpg"]))
        }
    }

    // MARK: Renaming

    @Test func templateNumbersInFinderOrderAndKeepsExtensions() throws {
        let plan = try builder.plan(PlinthCommand(.rename(PlinthRenameRule(template: "Trip {n}"))),
                                    for: PlinthFakeDisk.items(["IMG_10.jpg", "IMG_2.jpg", "IMG_1.HEIC"]))
        #expect(plan.isDestructive)
        #expect(plan.effects.map(\.url.lastPathComponent) == ["Trip 01.HEIC", "Trip 02.jpg", "Trip 03.jpg"])
    }

    @Test func renameIsOneStepSoItCanRollBack() throws {
        let plan = try builder.plan(PlinthCommand(.rename(PlinthRenameRule(prefix: "x "))),
                                    for: PlinthFakeDisk.items(["a.txt", "b.txt"]))
        #expect(plan.steps.count == 1)
        guard case .rename(let pairs) = plan.steps[0] else { Issue.record("Expected one rename step"); return }
        #expect(pairs.map(\.to.lastPathComponent) == ["x a.txt", "x b.txt"])
    }

    @Test func changingOnlyTheCaseOfSelectedNamesIsAllowed() throws {
        // On a case-insensitive volume "A.txt" exists already: it is "a.txt",
        // one of the items being renamed, so it is no clash.
        let plan = try PlinthFakeDisk.builder(existing: ["A.txt", "B.txt"])
            .plan(PlinthCommand(.rename(PlinthRenameRule(letterCase: .upper))),
                  for: PlinthFakeDisk.items(["a.txt", "b.txt"]))
        #expect(plan.effects.map(\.url.lastPathComponent) == ["A.txt", "B.txt"])
    }

    @Test func twoItemsWithOneNameAreRefused() {
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.rename(PlinthRenameRule(template: "Same"))),
                             for: PlinthFakeDisk.items(["a.jpg", "b.jpg"]))
        }
    }

    @Test func caseOnlyClashesCountOnMacVolumes() {
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.rename(PlinthRenameRule(letterCase: .lower))),
                             for: PlinthFakeDisk.items(["Photo.jpg", "PHOTO.jpg"]))
        }
    }

    @Test func renamingOntoAnUnselectedFileIsRefused() {
        #expect(throws: PlinthError.self) {
            try PlinthFakeDisk.builder(existing: ["b.txt"])
                .plan(PlinthCommand(.rename(PlinthRenameRule(find: "a", replace: "b"))),
                      for: PlinthFakeDisk.items(["a.txt"]))
        }
    }

    @Test func aRenameThatChangesNothingSaysSo() {
        #expect(throws: PlinthError.nothingToChange) {
            try builder.plan(PlinthCommand(.rename(PlinthRenameRule(find: "zzz", replace: "y"))),
                             for: PlinthFakeDisk.items(["a.txt"]))
        }
    }

    @Test func namesThatHideOrBreakFilesAreRefused() {
        let items = PlinthFakeDisk.items(["a.txt"])
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.rename(PlinthRenameRule(prefix: "."))), for: items)
        }
        #expect(throws: PlinthError.self) {
            try builder.plan(PlinthCommand(.rename(PlinthRenameRule(template: "a:b"))), for: items)
        }
    }

    // MARK: Selection limits

    @Test func emptyAndHugeSelectionsAreRefused() {
        #expect(throws: PlinthError.emptySelection) { try builder.plan(PlinthCommand(.unzip), for: []) }
        let many = PlinthFakeDisk.items((0...PlinthCommandBuilder.itemLimit).map { "f\($0).zip" })
        #expect(throws: PlinthError.tooManyItems(limit: PlinthCommandBuilder.itemLimit)) {
            try builder.plan(PlinthCommand(.unzip), for: many)
        }
    }
}

@Suite struct PlinthRenamerTests {
    private func name(_ file: String, _ rule: PlinthRenameRule, index: Int = 1, total: Int = 1,
                      isFolder: Bool = false) -> String {
        PlinthRenamer.newName(for: URL(fileURLWithPath: "/x/" + file), isFolder: isFolder, index: index,
                              total: total, rule: rule, date: PlinthFakeDisk.date,
                              timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test func tokens() {
        #expect(name("IMG_1.jpg", PlinthRenameRule(template: "{date} {name}")) == "2026-11-28 IMG_1.jpg")
        #expect(name("a.jpg", PlinthRenameRule(template: "Trip {n}"), index: 7, total: 120) == "Trip 007.jpg")
        #expect(name("a.jpg", PlinthRenameRule(template: "Trip {n}"), index: 3, total: 5) == "Trip 03.jpg")
    }

    @Test func findIsCaseInsensitiveAndCanRemove() {
        #expect(name("img_0001.jpg", PlinthRenameRule(find: "IMG_", replace: "")) == "0001.jpg")
        #expect(name("IMG_0001.jpg", PlinthRenameRule(find: "IMG_", replace: "Rome ")) == "Rome 0001.jpg")
    }

    @Test func caseChangesTheNameNotTheExtension() {
        #expect(name("Summer Trip.JPG", PlinthRenameRule(letterCase: .lower)) == "summer trip.JPG")
        #expect(name("meeting notes.txt", PlinthRenameRule(letterCase: .title)) == "Meeting Notes.txt")
    }

    @Test func foldersKeepDotsInTheirNames() {
        #expect(name("Report v1.2", PlinthRenameRule(suffix: " final"), isFolder: true) == "Report v1.2 final")
    }

    @Test func fileNameRules() throws {
        #expect(PlinthNames.isValidFileName("Holiday 2026.zip"))
        #expect(!PlinthNames.isValidFileName(".hidden"))
        #expect(!PlinthNames.isValidFileName("a/b"))
        #expect(!PlinthNames.isValidFileName("a:b"))
        #expect(!PlinthNames.isValidFileName(" padded"))
        #expect(!PlinthNames.isValidFileName("tab\there"))
        #expect(!PlinthNames.isValidFileName(String(repeating: "a", count: 256)))
        #expect(try PlinthNames.checkedBaseName("Photos.zip", extension: "zip") == "Photos")
    }
}
