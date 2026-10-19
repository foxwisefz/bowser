import Foundation
import Darwin
import HistoryCore
import CLiteRTLM

/// Only this disposable process loads the model. Browser code never links LiteRT.
final class Embedder {
    private let engine: OpaquePointer
    private let options: OpaquePointer
    init(path: String) throws {
        guard let settings = litert_lm_embedding_engine_settings_create(path, "cpu", "cpu", nil) else { throw Failure.model }
        defer { litert_lm_embedding_engine_settings_delete(settings) }
        litert_lm_embedding_engine_settings_set_num_threads(settings, 1)
        litert_lm_embedding_engine_settings_set_max_input_length(settings, 512)
        litert_lm_embedding_engine_settings_set_vision_tokens_per_image(settings, 70)
        guard let engine = litert_lm_embedding_engine_create(settings), let options = litert_lm_embedding_options_create() else { throw Failure.model }
        self.engine = engine; self.options = options
        litert_lm_embedding_options_set_output_size(options, Int32(HistoryModel.dimensions))
        litert_lm_embedding_options_set_normalize(options, true)
        litert_lm_embedding_options_set_input_overflow_strategy(options, kLiteRtLmInputOverflowStrategyTruncate)
    }
    deinit { litert_lm_embedding_options_delete(options); litert_lm_embedding_engine_delete(engine) }
    enum Failure: Error { case model, input, embedding }
    func embed(text: String) throws -> [Float] { try embed(Data(text.utf8), type: kLiteRtLmInputDataTypeText) }
    func embed(image: Data) throws -> [Float] { try embed(image, type: kLiteRtLmInputDataTypeImage) }
    private func embed(_ data: Data, type: LiteRtLmInputDataType) throws -> [Float] {
        guard let input = data.withUnsafeBytes({ litert_lm_input_data_create(type, $0.baseAddress, $0.count) }) else { throw Failure.input }
        defer { litert_lm_input_data_delete(input) }
        var inputs: [OpaquePointer?] = [input]
        guard let response = litert_lm_embedding_engine_compute_embedding(engine, &inputs, 1, options) else { throw Failure.embedding }
        defer { litert_lm_embedding_response_delete(response) }
        guard litert_lm_embedding_response_get_size(response) == HistoryModel.dimensions,
              let values = litert_lm_embedding_response_get_values(response) else { throw Failure.embedding }
        return try HistoryStore.normalized(Array(UnsafeBufferPointer(start: values, count: HistoryModel.dimensions)))
    }
}

guard CommandLine.arguments.count == 3 else { exit(64) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let modelPath = CommandLine.arguments[2]
setpriority(PRIO_PROCESS, 0, 15)
var embedder: Embedder?
var store: HistoryStore?
var profile: String?
@MainActor func model() throws -> Embedder {
    if let embedder { return embedder }
    let value = try Embedder(path: modelPath); embedder = value; return value
}
while let line = readLine() {
    var response = HistoryResponse()
    do {
        guard line.utf8.count <= 512_000 else { throw HistoryStore.Failure.invalidRecord }
        let request = try JSONDecoder().decode(HistoryRequest.self, from: Data(line.utf8))
        guard !request.profile.isEmpty, request.profile.utf8.count <= 256 else { throw HistoryStore.Failure.invalidRecord }
        if profile != request.profile { store = try HistoryStore(directory: directory, profile: request.profile); profile = request.profile }
        guard let store else { throw HistoryStore.Failure.database }
        try store.prune(days: request.days)
        switch request.operation {
        case "capture":
            guard let record = request.record else { throw HistoryStore.Failure.invalidRecord }
            try store.ingest(record)
            try store.prune(days: request.days)
        case "index":
            if let record = try store.nextUnindexed() {
                let model = try model()
                let text = try model.embed(text: HistoryModel.document(title: record.title, text: record.content))
                let image = try record.image.map { try model.embed(image: $0) }
                try store.setEmbedding(for: record, text: text, image: image)
                response.indexed = true
            }
        case "search":
            let query = request.query ?? ""
            // Text/appearance search remains available before the model download.
            let embedding = !query.isEmpty && FileManager.default.fileExists(atPath: modelPath) ? try model().embed(text: HistoryModel.query(query)) : nil
            response.hits = try store.search(query, embedding: embedding)
        case "delete": try store.delete(key: request.key)
        case "exclude": if let host = request.key { try store.delete(host: host) }
        case "stats": break
        default: throw HistoryStore.Failure.invalidRecord
        }
        response.stats = try store.stats()
    } catch {
        // Do not echo private page content, URL tokens, or native model diagnostics.
        response.error = "History search could not finish this operation. Try again."
    }
    if let json = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data([10]))
    }
}
