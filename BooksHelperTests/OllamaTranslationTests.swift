import Foundation
import Testing
@testable import BooksHelper

struct OllamaTranslationTests {
    @Test func recognizesTruncationEvenWhenTheTranslationJSONIsComplete() {
        let response = Data(#"{"done":true,"done_reason":"length","message":{"content":"{\"translations\":[{\"id\":0,\"translation\":\"译文\"}]}"}}"#.utf8)
        #expect(OllamaTransport.isTruncated(response, statusCode: 200))
        #expect(!OllamaTransport.isTruncated(response, statusCode: 501))
        #expect(!OllamaTransport.isTruncated(Data(#"{"done":true,"done_reason":"stop"}"#.utf8), statusCode: 200))
    }

    @Test func discoveryKeepsLocalTextModelsAndOmitsRemoteAndEmbeddingOnlyModels() throws {
        let response = Data("""
            {"models":[
              {"name":"qwen3.5:4b","capabilities":["completion","vision"]},
              {"name":"legacy-model:latest"},
              {"name":"remote-alias","remote_host":"https://ollama.com"},
              {"name":"remote-only","remote_model":"example"},
              {"name":"model:8b-cloud"},
              {"name":"embedding-only","capabilities":["embedding"]}
            ]}
            """.utf8)
        let filtered = try JSONDecoder().decode(Names.self, from: OllamaTransport.filterLocalTextModels(response))
        #expect(filtered.models.map(\.name) == ["qwen3.5:4b", "legacy-model:latest"])
    }

    private struct Names: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    @Test func restoresInputOrderWhenOllamaReturnsNonconsecutiveIDsOutOfOrder() throws {
        let content = """
            ```json
            {"translations":{"2":"第三段","0":"第一段"}}
            ```
            """
        let result = try OllamaTranslation.decodeTranslations(content, expectedIDs: [0, 2])
        #expect(result == ["第一段", "第三段"])
    }

    @Test func publishesWholeParagraphsBeforeThePageFinishes() throws {
        var stream = OllamaTranslation.ParagraphStream(expectedIDs: [0, 2])
        #expect(try stream.append(##"{"translations":{"2":"括号 } 和\"##).isEmpty)
        #expect(try stream.append(##""引号\"""##) == [.init(index: 2, text: #"括号 } 和"引号""#)])
        #expect(throws: OllamaTranslation.Failure.incompleteResponse) { try stream.finish() }
        #expect(try stream.append(#","0":"第一段"}}"#) == [.init(index: 0, text: "第一段")])
        #expect(try stream.finish() == ["第一段", #"括号 } 和"引号""#])
    }

    @Test func streamsPartialTextWithoutShowingJSONEscapes() throws {
        var stream = OllamaTranslation.ParagraphStream(expectedIDs: [0])
        #expect(try stream.append(##"{"translations":{"0":"前半\uD83D"##).isEmpty)
        #expect(stream.partialUpdate() == .init(index: 0, text: "前半"))
        #expect(try stream.append(##"\uDE00后半"##).isEmpty)
        #expect(stream.partialUpdate() == .init(index: 0, text: "前半😀后半"))
        #expect(try stream.append(#""}}"#) == [.init(index: 0, text: "前半😀后半")])
        #expect(stream.partialUpdate() == nil)
    }

    @Test func rejectsDuplicateParagraphsWhileStreaming() throws {
        var stream = OllamaTranslation.ParagraphStream(expectedIDs: [0, 2])
        #expect(try stream.append(#"{"translations":{"2":"译文""#) == [
            .init(index: 2, text: "译文")
        ])
        #expect(throws: OllamaTranslation.Failure.incompleteResponse) {
            try stream.append(#","2":"重复"}}"#)
        }
    }

    @Test(arguments: [
        #"{"translations":{"0":"第一段"}}"#,
        #"{"translations":{"0":"第一段","0":"重复"}}"#,
        #"{"translations":{"0":"第一段","1":"意外"}}"#,
        #"{"translations":{"0":"第一段","2":"   "}}"#,
    ])
    func rejectsIncompleteOrMisalignedTranslations(_ content: String) {
        #expect(throws: OllamaTranslation.Failure.incompleteResponse) {
            try OllamaTranslation.decodeTranslations(content, expectedIDs: [0, 2])
        }
    }
}
