import Foundation
import Network
import XCTest
@testable import RouteKit

/// Proves the identity reaches the server, rather than proving only that the app
/// put a value in a dictionary.
///
/// The gap this closes was invisible from the inside: a user-agent-restricted key
/// answers a request with `403` and no body worth reading, and every layer between
/// "we set the header" and "the server saw it" is exactly the kind of code that
/// looks right. So this stands up a real listener, points the real client at it,
/// and reads back what actually arrived.
final class HTTPIdentityOnTheWireTests: XCTestCase {

    private static let token = "GPXNav (iOS; com.example.GPXNav)"

    func testTheUserAgentArrivesOnTheWire() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let box = ResumeBox()

        let arrived: String? = try await withCheckedThrowingContinuation { continuation in
            box.set { continuation.resume(with: $0) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    box.finish(.failure(error))
                case .ready:
                    // Only once ready does `port` name a port the listener is
                    // actually accepting on; asking sooner connects to nothing
                    // and the request times out for no visible reason.
                    guard let port = listener.port else {
                        box.finish(.failure(URLError(.badServerResponse)))
                        return
                    }
                    Task {
                        let client = DefaultHTTPClient(userAgent: Self.token)
                        _ = try? await client.data(from: "http://127.0.0.1:\(port.rawValue)/geocoding/x.json")
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                Self.serveOnce(connection, box: box)
            }
            do {
                try listener.start(queue: .global(qos: .userInitiated))
            } catch {
                box.finish(.failure(error))
                return
            }

            // Nothing connected, or the reply never came: fail loudly rather
            // than hang the suite.
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                box.finish(.failure(URLError(.timedOut)))
            }
        }

        listener.cancel()
        // The default would have been `GPXNav/1 CFNetwork/… Darwin/…`, which is
        // not the allowlisted string and would not match a key restricted to it.
        XCTAssertEqual(arrived, Self.token)
    }

    // MARK: - Helpers

    /// Read one request, answer it, and report the user-agent it carried.
    private static func serveOnce(_ connection: NWConnection, box: ResumeBox) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if let error {
                connection.cancel()
                box.finish(.failure(error))
                return
            }
            guard let data, !isComplete, !data.isEmpty else {
                connection.cancel()
                box.finish(.failure(URLError(.badServerResponse)))
                return
            }
            // A complete 200, so the client's own request finishes instead of
            // waiting on a connection that is never closed.
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                let request = String(data: data, encoding: .utf8) ?? ""
                let agent = request
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("user-agent:") }
                    .map { $0.dropFirst("user-agent:".count).trimmingCharacters(in: .whitespaces) }
                box.finish(.success(agent))
            })
        }
    }

    /// Holds the resume closure so the failure handler, the connection handler
    /// and the timeout can all race to finish the continuation exactly once --
    /// they are not on the test's executor, so there is no other safe option.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resume: ((Result<String?, Error>) -> Void)?

        func set(_ resume: @escaping (Result<String?, Error>) -> Void) {
            lock.lock(); defer { lock.unlock() }
            self.resume = resume
        }

        func finish(_ result: Result<String?, Error>) {
            lock.lock()
            let resume = self.resume
            self.resume = nil
            lock.unlock()
            resume?(result)
        }
    }
}