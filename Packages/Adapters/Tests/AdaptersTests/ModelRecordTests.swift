import Core
import Foundation
import Ports
import Testing
@testable import Adapters

@Suite(.serialized) struct ModelRecordTests {
    private let fx = Fixtures()

    private func spec(_ id: String) -> ModelSpec {
        ModelSpec(id: id, version: "1", role: .generator, url: URL(string: "https://example.com/\(id)")!, bytes: 5,
                  sha256: String(repeating: "a", count: 64), fileName: "\(id).litertlm", licence: "Apache-2.0",
                  repository: URL(string: "https://huggingface.co/litert-community/\(id)"))
    }

    @Test func installingWritesARecordNextToTheFileAndItReadsBackOnANewInstance() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        let model = spec("gemma-alt")
        try files.install(fx.write(Data("hello".utf8), as: "download.tmp"), for: model)
        let record = ModelRecord(spec: model, source: .search, chosenByUser: true)
        try files.writeRecord(record)

        let sidecar = files.installedURL(for: model).deletingLastPathComponent().appendingPathComponent("model.json")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(FileModelFiles(root: fx.url("Models")).records() == [record])
    }

    @Test func uninstallingRemovesTheModelAndItsRecordFromDisk() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        let model = spec("gemma-alt")
        try files.install(fx.write(Data("hello".utf8), as: "download.tmp"), for: model)
        try files.writeRecord(ModelRecord(spec: model, source: .search, chosenByUser: true))
        files.uninstall(model)
        #expect(!files.isInstalled(model))
        #expect(files.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.installedURL(for: model).deletingLastPathComponent().path))
    }

    @Test func aModelWithoutARecordIsInstalledButHasNoRecord() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        let model = spec("old-llm")
        try files.install(fx.write(Data("hello".utf8), as: "download.tmp"), for: model)
        #expect(files.isInstalled(model))
        #expect(files.records().isEmpty)
    }

    @Test func theActiveSelectionIsSavedAndSurvivesARestart() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        #expect(files.loadActive() == ActiveModels(), "nothing is activated before the user chooses")
        try files.saveActive(ActiveModels(generator: "gemma-alt"))
        #expect(FileModelFiles(root: fx.url("Models")).loadActive().generator == "gemma-alt")
    }

    @Test func cleanUpNeverTakesTheActiveSelectionForAModel() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        try files.saveActive(ActiveModels(generator: "gemma-alt"))
        #expect(files.removeAbandoned(keeping: []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fx.url("Models").appendingPathComponent(".active.json").path))
    }
}
