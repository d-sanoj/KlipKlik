import Foundation
import Testing
@testable import KlipKlik

/// Checks on the eval suite itself, which run everywhere: the cases are
/// enough, cover every action, and expect only answers Plinth can carry out.
@Suite struct PlinthEvalSuiteTests {
    @Test func thereAreAtLeastFiftyCases() {
        #expect(PlinthEvalCases.all.count >= 50)
    }

    @Test func everyActionAndARefusalIsCovered() {
        var kinds = Set<PlinthIntentKind>()
        for evalCase in PlinthEvalCases.all {
            if evalCase.accepts.isEmpty { kinds.insert(.unsupported) }
            for command in evalCase.accepts { kinds.insert(Self.kind(of: command.action)) }
        }
        #expect(kinds == Set(PlinthIntentKind.allCases))
    }

    @Test func requestsAreUniqueAndWithinTheLengthLimit() {
        let requests = PlinthEvalCases.all.map(\.request)
        #expect(Set(requests).count == requests.count)
        #expect(requests.allSatisfy { $0.count <= PlinthLimits.requestLength })
    }

    /// An expected answer the builder would refuse would make the eval
    /// reward a model for something the bar can't do.
    @Test(arguments: PlinthEvalCases.all.filter { !$0.accepts.isEmpty })
    func everyExpectedAnswerBuilds(_ evalCase: PlinthEvalCase) throws {
        for command in evalCase.accepts {
            let plan = try PlinthFakeDisk.builder().plan(command, for: evalCase.items)
            #expect(!plan.steps.isEmpty)
        }
    }

    /// Refusals have to reach the model: no instant word may catch them.
    @Test func refusalsAreNotInstantActions() {
        for evalCase in PlinthEvalCases.all where evalCase.accepts.isEmpty {
            #expect(PlinthInstantActions.command(for: evalCase.request, selection: evalCase.selection) == nil)
        }
    }

    static func kind(of action: PlinthAction) -> PlinthIntentKind {
        switch action {
        case .convertVideo: return .convertVideo
        case .compressVideo: return .compressVideo
        case .convertImage: return .convertImage
        case .resizeImage: return .resizeImage
        case .compressImage: return .compressImage
        case .zip: return .zip
        case .unzip: return .unzip
        case .rename: return .rename
        case .mergePDFs: return .mergePDFs
        }
    }
}

/// Whether to run the live eval: opt in, because it needs Apple
/// Intelligence and takes a second or two a case.
enum PlinthEvalGate {
    static var isOn: Bool { ProcessInfo.processInfo.environment["PLINTH_EVAL"] == "1" }
}

#if canImport(FoundationModels)
/// The eval against the real on-device model:
///
///     PLINTH_EVAL=1 swift test --filter PlinthLiveEval
///
/// One test per case, run one at a time so the model is never asked twice at
/// once, each through the same road as the bar: instant action, else the
/// model, then the validator.
@Suite(.serialized, .enabled(if: PlinthEvalGate.isOn, "Set PLINTH_EVAL=1 to run the live model eval"))
struct PlinthLiveEval {
    @MainActor
    @Test(arguments: PlinthEvalCases.all)
    func modelUnderstands(_ evalCase: PlinthEvalCase) async throws {
        guard #available(macOS 26.0, *) else {
            Issue.record("The live eval needs macOS 26.")
            return
        }
        guard AppleIntelligenceInterpreter.availability == .available else {
            Issue.record("Apple Intelligence isn't available on this Mac.")
            return
        }

        let selection = evalCase.selection
        let command: PlinthCommand?
        if let instant = PlinthInstantActions.command(for: evalCase.request, selection: selection) {
            command = instant
        } else {
            let interpreter = AppleIntelligenceInterpreter()
            do {
                let raw = try await interpreter.interpret(evalCase.request, selection: selection)
                command = try? PlinthIntentValidator.command(from: raw, selection: selection)
                if command == nil { print("Plinth eval: \(evalCase) → refused \(raw)") }
            } catch {
                // A guardrail or a decoding failure is a refusal too.
                command = nil
            }
        }

        if evalCase.accepts.isEmpty {
            #expect(command == nil, "Should be refused, got \(String(describing: command))")
        } else {
            let got = try #require(command, "Refused a request that should work")
            #expect(evalCase.accepts.contains(got), "Got \(got)")
        }
    }
}
#endif
