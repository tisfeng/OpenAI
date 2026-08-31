//
//  StreamingSession.swift
//
//
//  Created by Sergii Kryvoblotskyi on 18/04/2023.
//

import Combine
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class StreamingSession<ResultType: Codable>: NSObject, Identifiable, URLSessionDelegate,
    URLSessionDataDelegate, Cancellable
{

    enum StreamingError: Error {
        case unknownContent
        case emptyContent
    }

    var onReceiveContent: ((StreamingSession, ResultType) -> Void)?
    var onProcessingError: ((StreamingSession, Error) -> Void)?
    var onComplete: ((StreamingSession, Error?) -> Void)?

    private let streamingCompletionMarker = "[DONE]"
    private let urlRequest: URLRequest
    private lazy var urlSession: URLSession = {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return session
    }()

    private var previousChunkBuffer = ""
    private var previousByteBuffer = Data()

    // Property to keep track of the URLSessionTask
    private var dataTask: URLSessionDataTask?

    init(urlRequest: URLRequest) {
        self.urlRequest = urlRequest
    }

    func perform() {
        dataTask = self.urlSession.dataTask(with: self.urlRequest)
        dataTask?.resume()
    }

    // Method to cancel the URLSessionTask
    func cancel() {
        dataTask?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        /**
         Usually, the Content-Type of OpenAI Stream Request Response should be "text/event-stream",

         For example, if user set the endpoint as https://api.openai.com instead of https://api.openai.com/v1/chat/completions ,
         at this time, the Content-Type will be "application/json", which is wrong, and we should return an error.
         */
        if error == nil, let response = task.response, let mimeType = response.mimeType,
            mimeType != "text/event-stream"
        {
            onComplete?(
                self, HTTPError.incorrectContentType(mimeType, url: response.url?.absoluteString))
        } else {
            onComplete?(self, error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        /**
         A chunk boundary can fall inside a multi-byte character, so the tail of a chunk may hold the
         first bytes of a character whose continuation bytes have not arrived yet. Decoding that tail
         on its own fails, which used to abort the whole stream — reliably hit by CJK responses, where
         most characters are 3 bytes wide.
         */
        previousByteBuffer.append(data)
        let (wholeCharacters, partialCharacter) = previousByteBuffer
            .splittingTrailingIncompleteUTF8Character()
        previousByteBuffer = partialCharacter

        guard !wholeCharacters.isEmpty else {
            return  // The whole chunk is the start of a character; wait for the rest.
        }
        guard let stringContent = String(data: wholeCharacters, encoding: .utf8) else {
            onProcessingError?(self, StreamingError.unknownContent)
            return
        }
        processJSON(from: stringContent)
    }

}

extension StreamingSession {

    private func processJSON(from stringContent: String) {
        if stringContent.isEmpty {
            return
        }

        // Join the previous chunk buffer with the new chunk, and filter out comments.
        // FIX OpenRouter: https://github.com/tisfeng/Easydict/issues/743
        let filteredContent = "\(previousChunkBuffer)\(stringContent)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix(":") }  // Filter out comments, like ": OPENROUTER PROCESSING"
            .joined(separator: "\n")

        // Split the filtered content into separate JSON objects.
        let jsonObjects =
            filteredContent
            .components(separatedBy: "data:")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        previousChunkBuffer = ""

        guard jsonObjects.isEmpty == false, jsonObjects.first != streamingCompletionMarker else {
            return
        }

        jsonObjects.enumerated().forEach { (index, jsonContent) in
            guard jsonContent != streamingCompletionMarker && !jsonContent.isEmpty else {
                return
            }
            guard let jsonData = jsonContent.data(using: .utf8) else {
                onProcessingError?(self, StreamingError.unknownContent)
                return
            }
            let decoder = JSONDecoder()
            do {
                let object = try decoder.decode(ResultType.self, from: jsonData)
                onReceiveContent?(self, object)
            } catch {
                if let decoded = try? decoder.decode(APIErrorResponse.self, from: jsonData) {
                    onProcessingError?(self, decoded)
                } else if index == jsonObjects.count - 1 {
                    previousChunkBuffer = "data: \(jsonContent)"  // Chunk ends in a partial JSON
                } else {
                    onProcessingError?(self, error)
                }
            }
        }
    }
}

extension Data {

    /// Splits off a trailing byte sequence that begins a UTF-8 character but does not complete it.
    ///
    /// Returns the leading bytes that form whole characters, and the trailing bytes of a character
    /// still missing its continuation bytes. The partial part is empty when the data already ends on
    /// a character boundary, and also when the trailing bytes cannot start a valid character at all —
    /// a genuine encoding error is surfaced to the caller rather than buffered forever.
    func splittingTrailingIncompleteUTF8Character() -> (whole: Data, partial: Data) {
        var index = endIndex - 1
        var trailingByteCount = 1

        // A UTF-8 character spans at most 4 bytes, so its lead byte is at most 3 bytes from the end.
        while index >= startIndex, trailingByteCount <= 4 {
            let byte = self[index]
            let isContinuationByte = byte & 0b1100_0000 == 0b1000_0000
            if !isContinuationByte {
                let characterLength: Int
                switch byte {
                case 0x00...0x7F: characterLength = 1
                case 0xC2...0xDF: characterLength = 2
                case 0xE0...0xEF: characterLength = 3
                case 0xF0...0xF4: characterLength = 4
                default: return (self, Data())  // Not a lead byte, let decoding report it.
                }
                guard characterLength > trailingByteCount else {
                    return (self, Data())
                }
                return (Data(self[..<index]), Data(self[index...]))
            }
            index -= 1
            trailingByteCount += 1
        }

        return (self, Data())
    }
}

enum HTTPError: Error {
    case incorrectContentType(String, url: String?)
}

extension HTTPError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .incorrectContentType(let message, let url):
            var errorMessage =
                "Incorrect Content-Type: \(message), acceptable type is text/event-stream."
            if let url {
                errorMessage += " This may be caused by a wrong endpoint: \(url)"
            }
            return errorMessage
        }
    }
}
