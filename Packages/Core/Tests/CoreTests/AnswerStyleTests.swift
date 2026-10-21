import Testing
@testable import Core

@Suite struct AnswerStyleTests {
    @Test func everyStepBelongsToExactlyOneStop() {
        for step in -6...10 {
            let owners = AnswerStyle.Stop.allCases.filter { $0.steps.contains(step) }
            #expect(owners.count == 1, "step \(step) belongs to \(owners)")
        }
    }

    @Test(arguments: [
        (-0.06, AnswerStyle.Stop.strict), (-0.03, .strict), (-0.02, .balanced), (0, .balanced), (0.02, .balanced),
        (0.03, .conversational), (0.06, .conversational), (0.07, .open), (0.10, .open),
    ])
    func stopBoundaries(offset: Double, stop: AnswerStyle.Stop) {
        #expect(AnswerStyle(offset: offset).stop == stop)
    }

    @Test func offsetsAreClampedAndRounded() {
        #expect(AnswerStyle(offset: -1).offset == -0.06)
        #expect(AnswerStyle(offset: 1).offset == 0.10)
        #expect(AnswerStyle(offset: 0.0249).offset == 0.02)
        #expect(AnswerStyle(offset: 0.0251).stop == .conversational)
    }

    @Test func distanceIsTheTunedOnePlusTheOffset() {
        #expect(AnswerStyle(offset: 0.02).maxDistance(tuned: 0.28) == 0.30)
        #expect(AnswerStyle.balanced.maxDistance(tuned: 0.28) == 0.28)
        #expect(AnswerStyle(offset: -0.06).maxDistance(tuned: 0.28) == 0.22)
        #expect(AnswerStyle(offset: 0.10).maxDistance(tuned: 0.28) == 0.38)
    }

    @Test func onlyTheTalkativeStopsReplyWithoutDocuments() {
        #expect(AnswerStyle.Stop.allCases.filter(\.repliesWithoutDocuments) == [.conversational, .open])
    }
}
