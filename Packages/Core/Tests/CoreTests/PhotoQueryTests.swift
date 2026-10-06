import Testing
@testable import Core

@Suite struct PhotoQueryTests {
    /// A pump nameplate with labels, a rating block, a protection class, a country and a date.
    private let labelledPlate = [
        "ACME PUMPS", "MODEL X200-B", "S/N 4471-22", "230V~ 50Hz", "IP54", "MADE IN GERMANY", "2024-03",
    ]
    /// An industrial motor plate: labels with colons, a multi-part article number, three-phase ratings.
    private let motorPlate = [
        "TYPE: KX-75/2", "Art.-Nr. 0087 1123", "3~ 400V 7.5kW 1450rpm", "IP55 Cl.F", "No user serviceable parts",
    ]
    /// A housing label with no labels at all: the model is just printed on it.
    private let bareLabel = ["DELTA FILTER CO", "Filter housing FH-220", "Max 8 bar / 116 psi", "Lot 20240315"]

    @Test func labelledValuesAreKeptAndRatingsDatesAndCountriesAreDropped() {
        let query = PhotoQuery(typed: "", recognizedLines: labelledPlate)
        #expect(query.identifiers == ["X200-B", "4471-22"])
        #expect(query.text == "X200-B 4471-22")
    }

    @Test func aLabelsValuesIncludeAMultiPartNumberButNotRatings() {
        let query = PhotoQuery(typed: "", recognizedLines: motorPlate)
        #expect(query.identifiers == ["KX-75/2", "0087", "1123"])
        #expect(!query.text.contains("400V") && !query.text.contains("7.5kW") && !query.text.contains("IP55"))
        #expect(!query.text.localizedCaseInsensitiveContains("serviceable"))
    }

    @Test func anUnlabelledModelIsRecognizedByItsShape() {
        let query = PhotoQuery(typed: "", recognizedLines: bareLabel)
        // "Lot 20240315" is labelled, so its value stays; "8 bar" and "116 psi" are not identifiers.
        #expect(query.identifiers == ["FH-220", "20240315"])
    }

    @Test func theTypedQuestionComesFirstAndTheIdentifiersFollow() {
        let query = PhotoQuery(typed: "  how do I descale it?  ", recognizedLines: labelledPlate)
        #expect(query.text == "how do I descale it? X200-B 4471-22")
        #expect(query.recognizedText == labelledPlate.joined(separator: "\n"))
    }

    @Test func aLabelAloneOnALineTakesTheNextLinesValue() {
        let query = PhotoQuery(typed: "", recognizedLines: ["Model:", "X200-B", "Made in Germany"])
        #expect(query.identifiers == ["X200-B"])
    }

    @Test func repeatedIdentifiersAppearOnce() {
        let query = PhotoQuery(typed: "", recognizedLines: ["MODEL X200-B", "x200-b", "Type X200-B"])
        #expect(query.identifiers == ["X200-B"])
    }

    @Test func nothingReadableAndNothingTypedIsEmpty() {
        #expect(PhotoQuery(typed: "", recognizedLines: []).isEmpty)
        #expect(PhotoQuery(typed: "  ", recognizedLines: ["230V~ 50Hz", "IP54", "MADE IN GERMANY"]).isEmpty)
    }

    @Test func aTypedQuestionAloneIsKeptAsIs() {
        let query = PhotoQuery(typed: "what is this part", recognizedLines: [])
        #expect(query.text == "what is this part" && query.identifiers.isEmpty && !query.isEmpty)
    }

    @Test func errorCodesOnAScreenAreIdentifiers() {
        let query = PhotoQuery(typed: "", recognizedLines: ["ERROR", "E-042", "Press OK to continue"])
        #expect(query.identifiers == ["E-042"])
    }
}
