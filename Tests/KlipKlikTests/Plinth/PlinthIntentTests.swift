import CoreGraphics
import Foundation
import Testing
@testable import KlipKlik

/// Everything the model says passes through `PlinthIntentValidator`. These
/// cases are the model getting it wrong in the ways small models do.
@Suite struct PlinthIntentValidatorTests {
    private let videos = PlinthSelectionSummary(PlinthFakeDisk.items(["a.mov", "b.mp4"]))
    private let photos = PlinthSelectionSummary(PlinthFakeDisk.items(["a.heic", "b.png"]))
    private let pdfs = PlinthSelectionSummary(PlinthFakeDisk.items(["a.pdf", "b.pdf"]))

    private func command(_ raw: PlinthRawIntent, _ selection: PlinthSelectionSummary) throws -> PlinthCommand {
        try PlinthIntentValidator.command(from: raw, selection: selection)
    }

    @Test func aWellFormedAnswerPassesThrough() throws {
        let raw = PlinthRawIntent(kind: .convertVideo, format: "MP4", videoHeight: 720)
        #expect(try command(raw, videos) == PlinthCommand(.convertVideo(to: .mp4, maxHeight: 720)))
    }

    @Test func formatSpellingsAreNormalised() {
        #expect(PlinthIntentValidator.videoFormat("H.264") == .mp4)
        #expect(PlinthIntentValidator.videoFormat(" WebM ") == .webm)
        #expect(PlinthIntentValidator.videoFormat("aac") == .m4a)
        #expect(PlinthIntentValidator.imageFormat("JPEG") == .jpg)
        #expect(PlinthIntentValidator.imageFormat("heif") == .heic)
        #expect(PlinthIntentValidator.imageFormat("tif") == .tiff)
        #expect(PlinthIntentValidator.imageFormat("exe") == nil)
    }

    @Test func imageVersusVideoIsDecidedByWhatIsSelected() throws {
        let gif = PlinthRawIntent(kind: .convertImage, format: "gif")
        #expect(try command(gif, videos) == PlinthCommand(.convertVideo(to: .gif, maxHeight: nil)))
        let shrink = PlinthRawIntent(kind: .compressVideo)
        #expect(try command(shrink, photos) == PlinthCommand(.compressImage(quality: .medium)))
        let jpeg = PlinthRawIntent(kind: .convertVideo, format: "jpeg")
        #expect(try command(jpeg, photos) == PlinthCommand(.convertImage(to: .jpg)))
    }

    @Test func onePDFOutOfSeveralPDFsIsAMerge() throws {
        let raw = PlinthRawIntent(kind: .convertImage, format: "pdf", outputName: "Thesis")
        #expect(try command(raw, pdfs) == PlinthCommand(.mergePDFs(name: "Thesis")))
    }

    @Test func unknownFormatsAndQualitiesAreRefused() {
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .convertVideo, format: "avi"), videos) }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .convertVideo), videos) }
        #expect(throws: PlinthError.self) {
            try command(PlinthRawIntent(kind: .compressVideo, quality: "ultra"), videos)
        }
    }

    @Test func absurdNumbersAreRefused() {
        #expect(throws: PlinthError.self) {
            try command(PlinthRawIntent(kind: .convertVideo, format: "mp4", videoHeight: -5), videos)
        }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .resizeImage, percent: 5_000), photos) }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .resizeImage, maxPixels: 2), photos) }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .resizeImage), photos) }
    }

    @Test func resizeTakesTheFirstSizeGiven() throws {
        let raw = PlinthRawIntent(kind: .resizeImage, percent: 50, maxPixels: 1024, width: 800)
        #expect(try command(raw, photos) == PlinthCommand(.resizeImage(.percent(50))))
        #expect(try command(PlinthRawIntent(kind: .resizeImage, height: 300), photos)
            == PlinthCommand(.resizeImage(.height(300))))
    }

    @Test func audioOnlyDropsAStrayHeight() throws {
        let raw = PlinthRawIntent(kind: .convertVideo, format: "mp3", videoHeight: 1080)
        #expect(try command(raw, videos) == PlinthCommand(.convertVideo(to: .mp3, maxHeight: nil)))
    }

    @Test func fieldsThatDoNotBelongAreDropped() throws {
        let raw = PlinthRawIntent(kind: .zip, format: "png", percent: 50, trashOriginals: true)
        #expect(try command(raw, photos) == PlinthCommand(.zip(name: nil)))
    }

    @Test func trashIsCarriedOnlyWhenAsked() throws {
        let raw = PlinthRawIntent(kind: .convertImage, format: "jpg", trashOriginals: true)
        #expect(try command(raw, photos).trashOriginals)
        #expect(try !command(PlinthRawIntent(kind: .convertImage, format: "jpg"), photos).trashOriginals)
    }

    @Test func renamePartsCannotEscapeTheFolder() {
        #expect(throws: PlinthError.self) {
            try command(PlinthRawIntent(kind: .rename, renameTemplate: "../../{name}"), photos)
        }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .rename, prefix: "a:b"), photos) }
        #expect(throws: PlinthError.self) {
            try command(PlinthRawIntent(kind: .rename, suffix: String(repeating: "x", count: 200)), photos)
        }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .rename, prefix: "a\u{7}"), photos) }
    }

    @Test func anEmptyRenameIsRefusedButAnEmptyReplacementIsNot() throws {
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .rename), photos) }
        let remove = try command(PlinthRawIntent(kind: .rename, find: "IMG_", replace: ""), photos)
        #expect(remove == PlinthCommand(.rename(PlinthRenameRule(find: "IMG_", replace: ""))))
    }

    @Test func letterCaseIsReadLoosely() throws {
        let raw = PlinthRawIntent(kind: .rename, letterCase: "Upper")
        #expect(try command(raw, photos) == PlinthCommand(.rename(PlinthRenameRule(letterCase: .upper))))
    }

    @Test func archiveNamesMustBeFileNames() throws {
        #expect(try command(PlinthRawIntent(kind: .zip, outputName: "Photos.zip"), photos)
            == PlinthCommand(.zip(name: "Photos")))
        #expect(throws: PlinthError.self) {
            try command(PlinthRawIntent(kind: .zip, outputName: "/etc/passwd"), photos)
        }
        #expect(throws: PlinthError.self) { try command(PlinthRawIntent(kind: .mergePDFs, outputName: ".x"), pdfs) }
    }

    @Test func unsupportedIsAlwaysRefused() {
        #expect(throws: PlinthError.unsupportedRequest) {
            try command(PlinthRawIntent(kind: .unsupported, format: "mp4"), videos)
        }
    }
}

@Suite struct PlinthInstantActionTests {
    private let photos = PlinthSelectionSummary(PlinthFakeDisk.items(["a.heic", "b.png"]))
    private let pdfs = PlinthSelectionSummary(PlinthFakeDisk.items(["a.pdf", "b.pdf"]))

    @Test func everyChipIsAnInstantAction() {
        for chip in PlinthInstantActions.chips {
            #expect(PlinthInstantActions.command(for: chip, selection: photos) != nil, "\(chip)")
        }
    }

    @Test func wordsMapToCommandsWithoutTheModel() {
        #expect(PlinthInstantActions.command(for: " ZIP ", selection: photos) == PlinthCommand(.zip(name: nil)))
        #expect(PlinthInstantActions.command(for: "jpeg.", selection: photos) == PlinthCommand(.convertImage(to: .jpg)))
        #expect(PlinthInstantActions.command(for: "unzip", selection: photos) == PlinthCommand(.unzip))
        #expect(PlinthInstantActions.command(for: "mp4", selection: photos)
            == PlinthCommand(.convertVideo(to: .mp4, maxHeight: nil)))
    }

    @Test func pdfMeansMergeOnlyWhenEverythingIsAPDF() {
        #expect(PlinthInstantActions.command(for: "pdf", selection: pdfs) == PlinthCommand(.mergePDFs(name: nil)))
        #expect(PlinthInstantActions.command(for: "pdf", selection: photos) == PlinthCommand(.convertImage(to: .pdf)))
    }

    @Test func anythingLongerGoesToTheModel() {
        #expect(PlinthInstantActions.command(for: "zip these as Photos", selection: photos) == nil)
        #expect(PlinthInstantActions.command(for: "png at half size", selection: photos) == nil)
    }
}

@Suite struct PlinthPromptTests {
    /// The context is 4,096 tokens for instructions, schema, prompt and
    /// answer. The schema of the generated type is about 600 tokens and the
    /// answer under 100, so what we write ourselves stays under 900 even at
    /// the longest request the bar accepts.
    @Test func theLongestPromptStaysWellInsideTheContext() {
        let selection = PlinthSelectionSummary(PlinthFakeDisk.items(
            ["a.mov", "b.mp4", "c.heic", "d.png", "e.pdf", "f.zip", "g.txt", "h.m4a", "Folder/"]))
        let request = String(repeating: "x", count: PlinthLimits.requestLength)
        #expect(PlinthPrompt.estimatedTokens(request: request, selection: selection) < 900)
    }

    @Test func thePromptCarriesCountsNotPaths() {
        let selection = PlinthSelectionSummary(PlinthFakeDisk.items(["secret plans.mov", "b.mov", "c.mp4"]))
        let prompt = PlinthPrompt.prompt(request: "make gifs", selection: selection)
        #expect(prompt == "Selected: 3 videos (.mov, .mp4)\nRequest: make gifs")
        #expect(!prompt.contains("secret"))
    }

    @Test func nothingSelectedReadsAsNothing() {
        #expect(PlinthSelectionSummary([]).promptLine == "nothing")
    }
}

@Suite struct PlinthPlacementTests {
    /// One 1440×900 display with a 25-point menu bar.
    private let screen = [CGRect(x: 0, y: 0, width: 1440, height: 875)]

    @Test func sitsCentredJustBelowTheWindow() {
        // Quartz: 100 from the top, 500 tall, so its bottom edge is 600 down.
        let window = CGRect(x: 200, y: 100, width: 600, height: 500)
        let frame = PlinthPlacement.frame(below: window, height: 40, mainDisplayHeight: 900, visibleFrames: screen)
        #expect(frame.width == 600 - 2 * PlinthPlacement.inset)
        #expect(frame.midX == window.midX)
        #expect(frame.maxY == 900 - 600 - PlinthPlacement.gap)
    }

    @Test func widthIsClamped() {
        let narrow = PlinthPlacement.frame(below: CGRect(x: 500, y: 100, width: 300, height: 300), height: 40,
                                           mainDisplayHeight: 900, visibleFrames: screen)
        #expect(narrow.width == PlinthPlacement.minWidth)
        let wide = PlinthPlacement.frame(below: CGRect(x: 0, y: 100, width: 1400, height: 300), height: 40,
                                         mainDisplayHeight: 900, visibleFrames: screen)
        #expect(wide.width == PlinthPlacement.maxWidth)
    }

    @Test func aFullHeightWindowGetsTheBarInsideItsBottomEdge() {
        let window = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = PlinthPlacement.frame(below: window, height: 40, mainDisplayHeight: 900, visibleFrames: screen)
        #expect(frame.minY >= screen[0].minY)
        #expect(frame.minY == PlinthPlacement.inset)
    }

    @Test func neverOffTheSideOfTheScreen() {
        let window = CGRect(x: -350, y: 100, width: 500, height: 400)
        let frame = PlinthPlacement.frame(below: window, height: 40, mainDisplayHeight: 900, visibleFrames: screen)
        #expect(frame.minX >= PlinthPlacement.inset)
        #expect(frame.maxX <= 1440 - PlinthPlacement.inset)
    }
}
