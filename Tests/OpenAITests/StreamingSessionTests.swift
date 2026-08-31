//
//  StreamingSessionTests.swift
//
//

import XCTest
@testable import OpenAI

final class UTF8ChunkSplittingTests: XCTestCase {

    /// Reassembles `data` the way `StreamingSession` does, feeding it one chunk at a time.
    private func decode(chunks: [Data]) -> String? {
        var buffer = Data()
        var decoded = ""
        for chunk in chunks {
            buffer.append(chunk)
            let (whole, partial) = buffer.splittingTrailingIncompleteUTF8Character()
            buffer = partial
            guard !whole.isEmpty else { continue }
            guard let string = String(data: whole, encoding: .utf8) else { return nil }
            decoded += string
        }
        return decoded
    }

    func testDataEndingOnCharacterBoundaryIsNotHeldBack() {
        let data = Data("你好".utf8)
        let (whole, partial) = data.splittingTrailingIncompleteUTF8Character()
        XCTAssertEqual(whole, data)
        XCTAssertTrue(partial.isEmpty)
    }

    func testTrailingPartialCharacterIsHeldBack() {
        let full = Data("a好".utf8)  // 1 + 3 bytes
        for missingBytes in 1...2 {
            let truncated = full.dropLast(missingBytes)
            let (whole, partial) = Data(truncated).splittingTrailingIncompleteUTF8Character()
            XCTAssertEqual(whole, Data("a".utf8), "missing \(missingBytes) bytes")
            XCTAssertEqual(partial.count, 3 - missingBytes, "missing \(missingBytes) bytes")
        }
    }

    func testChunkThatIsOnlyTheStartOfACharacterYieldsNothingToDecode() {
        let leadByteOnly = Data(Data("好".utf8).prefix(1))
        let (whole, partial) = leadByteOnly.splittingTrailingIncompleteUTF8Character()
        XCTAssertTrue(whole.isEmpty)
        XCTAssertEqual(partial, leadByteOnly)
    }

    func testInvalidUTF8IsNotBufferedSoDecodingCanReportIt() {
        let invalid = Data([0x41, 0xFF])
        let (whole, partial) = invalid.splittingTrailingIncompleteUTF8Character()
        XCTAssertEqual(whole, invalid)
        XCTAssertTrue(partial.isEmpty)
        XCTAssertNil(String(data: whole, encoding: .utf8))
    }

    func testEmptyData() {
        let (whole, partial) = Data().splittingTrailingIncompleteUTF8Character()
        XCTAssertTrue(whole.isEmpty)
        XCTAssertTrue(partial.isEmpty)
    }

    /// The regression: an SSE payload split at any byte offset must still decode in full.
    func testStreamSplitAtEveryByteOffsetDecodesToTheOriginal() {
        let payload = #"data: {"choices":[{"delta":{"content":"取消的退款不再算作已退款 — 审计链保持只追加。🎉"}}]}"#
        let data = Data(payload.utf8)
        XCTAssertGreaterThan(data.count, 60)

        for splitIndex in 0...data.count {
            let chunks = [Data(data.prefix(splitIndex)), Data(data.dropFirst(splitIndex))]
            XCTAssertEqual(
                decode(chunks: chunks), payload, "split at byte \(splitIndex)"
            )
        }
    }

    func testStreamSplitIntoSingleBytesDecodesToTheOriginal() {
        let payload = "多字节字符逐字节到达 — 😀 也要还原"
        let chunks = Data(payload.utf8).map { Data([$0]) }
        XCTAssertEqual(decode(chunks: chunks), payload)
    }
}
