// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightDataFormat
import Foundation

/// What became of one attempt to send a report.
enum DeliveryOutcome: Equatable, Sendable {
    /// The server has the report: it answered with a success and `"received": true`. `verified` says whether it
    /// believed the proof, when it said; `unknownKey` that it didn't know the key the proof was made with.
    case delivered(verified: Bool?, unknownKey: Bool = false)
    /// Try again later: the server was busy or down, or can't take reports now. `after` is how long it asked to wait.
    case retry(after: TimeInterval?)
    /// The server couldn't be reached: no network, or the request failed on the way. A trigger that finds the
    /// network back may try again sooner than the backoff.
    case unreachable
    /// The server refused the report as it is (malformed, too large, or its ID taken by other bytes), so sending it
    /// again can't help.
    case drop(status: Int)
    /// The app takes reports only from copies that prove themselves, and this one came with no proof.
    case proofRequired
    /// The app takes reports only from copies that prove themselves, and the server didn't believe the proof:
    /// because it doesn't know the key, or for a reason another challenge and signature may put right.
    case proofRefused(unknownKey: Bool)
}

/// One `POST <endpoint>/v1/reports`, as multipart: the `report` JSON and, when there are attachments,
/// `payload.bin`, with the copy's proof in three headers when it has one.
struct ReportSender: Sendable {
    let endpoint: URL
    let appToken: String
    let session: URLSession

    private struct Receipt: Decodable {
        let received: Bool
        let verified: Bool?
        let proof: String?
    }

    func send(_ report: PreparedReport, installID: String, proof: ReportProof? = nil) async -> DeliveryOutcome {
        let boundary = "FlightData-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.appending(path: "v1/reports"))
        request.httpMethod = "POST"
        request.setValue("Ingest \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "X-Install-ID")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FlightDataKit/\(FlightDataKit.version)", forHTTPHeaderField: "User-Agent")
        if let proof {
            request.setValue(proof.keyID, forHTTPHeaderField: "X-Attest-Key-ID")
            request.setValue(proof.challenge, forHTTPHeaderField: "X-Attest-Challenge")
            request.setValue(proof.assertion.base64EncodedString(), forHTTPHeaderField: "X-Attest-Assertion")
        }
        do {
            let (data, response) = try await session.upload(for: request, from: Self.body(report, boundary: boundary))
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Self.outcome(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                body: data)
        } catch {
            return .unreachable
        }
    }

    /// What the server's answer means. Only a success whose body says `"received": true` delivers the report: a
    /// success without it, such as a captive portal's page, leaves the report to be sent again.
    static func outcome(status: Int, retryAfter: String?, body: Data = Data()) -> DeliveryOutcome {
        let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if (200..<300).contains(status) {
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: body), receipt.received else {
                return .retry(after: Self.retryDelay(header: retryAfter, answer: answer))
            }
            return .delivered(verified: receipt.verified, unknownKey: receipt.proof == "unknown_key")
        }
        // A refusal over the proof says so among its errors: `{"field": "proof", "code": "required"}`. A report
        // taken without believing its proof says why beside it: `"proof": "unknown_key"`.
        let errors = answer?["errors"] as? [[String: Any]]
        let proof = errors?.first { $0["field"] as? String == "proof" }?["code"] as? String
        switch status {
        case 400, 409, 413, 415, 422: return .drop(status: status)
        case 403 where proof == "required": return .proofRequired
        case 401 where proof != nil: return .proofRefused(unknownKey: proof == "unknown_key")
        default: return .retry(after: Self.retryDelay(header: retryAfter, answer: answer))
        }
    }

    /// How long the server asked to wait: `Retry-After` in seconds, or else the problem's `retry_after_seconds`.
    static func retryDelay(header: String?, answer: [String: Any]?) -> TimeInterval? {
        if let seconds = header.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) { return seconds }
        return (answer?["retry_after_seconds"] as? NSNumber)?.doubleValue
    }

    static func body(_ report: PreparedReport, boundary: String) -> Data {
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"report\"\r\n"
            + "Content-Type: application/json\r\n\r\n")
        body.append(report.json)
        add("\r\n")
        if let payload = report.payload {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload\"; filename=\"payload.bin\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n")
            body.append(payload)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        return body
    }
}
