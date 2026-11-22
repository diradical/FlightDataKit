// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import FlightDataFormat
import Foundation

/// What a report is sent with to prove it comes from a genuine copy of the app.
struct ReportProof: Equatable, Sendable {
    /// The enrolled key's identifier, as App Attest gave it.
    let keyID: String
    /// What the server gave for this one sending.
    let challenge: String
    /// App Attest's signature over the challenge and the report.
    let assertion: Data
}

/// Whether a report can go now, and with what.
enum Proving: Equatable, Sendable {
    /// With this proof.
    case proven(ReportProof)
    /// Without one: this copy can't prove itself, hasn't enrolled, or the server gave no challenge to sign.
    case unproven
    /// Later: the server asked for a challenge was busy or limited (408, 429 or 503). `after` is how long it
    /// asked to wait, when it did.
    case wait(after: TimeInterval?)
    /// Later: the server couldn't be reached for a challenge.
    case unreachable
}

/// Proves that reports come from a genuine copy of the app, where the device can: enrolls a key with the server
/// once, with Apple's attestation of it and the App ID prefix the copy is signed with, then asks the server for a
/// challenge before each report and signs the two together with that key.
///
/// Its state is one file beside the queue. Calls are not synchronized; `FlightDataContainer` serializes them.
struct ReportProver: Sendable {
    struct State: Codable, Equatable, Sendable {
        /// The server the key was enrolled with. A container pointed at another server enrolls again.
        var endpoint: String
        var keyID: String?
        var enrolled = false
        /// Enrolling isn't tried again before this.
        var notBefore: Date?
        /// When a key the server no longer knew was last given up.
        var forgotten: Date?
    }

    /// How long to wait after something that will pass, and after something that won't soon.
    static let soon: TimeInterval = 15 * 60
    static let later: TimeInterval = 24 * 60 * 60

    let endpoint: URL
    let appToken: String
    let session: URLSession
    let attestor: any AppAttestor
    let file: URL

    /// Whether this copy can prove itself at all. One that can't sends its reports unproven, for good.
    var isSupported: Bool { attestor.isSupported }

    /// How to send `report`: with a proof, enrolling first if this copy hasn't; without; or not yet.
    func proof(for report: PreparedReport, now: Date) async -> Proving {
        guard attestor.isSupported else { return .unproven }
        var state = load()
        if !state.enrolled || state.keyID == nil {
            guard await enroll(&state, now: now) else { return .unproven }
        }
        guard let keyID = state.keyID else { return .unproven }
        guard let asked = await post("v1/attest/challenges", json: nil) else { return .unreachable }
        // Busy or limited is worth waiting for. Any other refusal goes without a proof: if the app requires one,
        // the report is refused for want of it, and that is handled there.
        if [408, 429, 503].contains(asked.status) { return .wait(after: asked.retryAfter) }
        guard asked.status == 201, let challenge = Self.challenge(in: asked.body) else { return .unproven }
        do {
            let signed = Self.clientDataHash(report, challenge: challenge)
            return .proven(ReportProof(keyID: keyID, challenge: challenge,
                                       assertion: try await attestor.generateAssertion(keyID, clientDataHash: signed)))
        } catch AttestorError.invalidKey {
            // The key didn't survive a reinstall or a restore. Another is enrolled on the next pass.
            state.keyID = nil
            state.enrolled = false
            save(state)
            return .unproven
        } catch {
            return .unproven
        }
    }

    /// The server doesn't know the enrolled key, so the key is given up and another enrolled: at once the first
    /// time, and no more than once a day after that.
    func forget(now: Date) {
        var state = load()
        guard state.keyID != nil else { return }
        if let last = state.forgotten, now.timeIntervalSince(last) < Self.later {
            state.notBefore = max(state.notBefore ?? .distantPast, last.addingTimeInterval(Self.later))
        }
        state.keyID = nil
        state.enrolled = false
        state.forgotten = now
        save(state)
    }

    /// The SHA-256 the key signs for a report: of four lines, one naming this format, the challenge, the report
    /// JSON's SHA-256 in hex, and the payload's, or `-` for no payload. The server works out the same from what
    /// arrives.
    static func clientDataHash(_ report: PreparedReport, challenge: String) -> Data {
        let text = "FlightData report proof 1\n\(challenge)\n\(hex(SHA256.hash(data: report.json)))\n"
            + (report.payload.map { hex(SHA256.hash(data: $0)) } ?? "-")
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Asks the server for a challenge, has Apple attest a key with it, and enrolls the key.
    private func enroll(_ state: inout State, now: Date) async -> Bool {
        if let notBefore = state.notBefore, notBefore > now { return false }
        defer { save(state) }
        state.enrolled = false
        guard let asked = await post("v1/attest/challenges", json: nil) else {
            state.notBefore = now.addingTimeInterval(Self.soon)
            return false
        }
        guard asked.status == 201, let challenge = Self.challenge(in: asked.body) else {
            // 403: the app isn't one whose copies can be verified. Otherwise the server is busy, and says when to
            // come back if it knows.
            let wait = asked.retryAfter.map { min(max($0, 1), Self.later) } ?? Self.soon
            state.notBefore = now.addingTimeInterval(asked.status == 403 ? Self.later : wait)
            return false
        }
        do {
            // A key made earlier, which Apple couldn't be reached to attest, is tried again before another is made.
            let keyID = try await state.keyID.orElse { try await attestor.generateKey() }
            state.keyID = keyID
            let challengeHash = Data(SHA256.hash(data: Data(challenge.utf8)))
            let attestation = try await attestor.attestKey(keyID, clientDataHash: challengeHash)
            // Attested, the key can't be attested a second time: enrolled now, or given up.
            state.keyID = nil
            // Include the signed app's App ID prefix when it is available.
            var fields = ["key_id": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge]
            if let prefix = attestor.appIDPrefix { fields["app_id_prefix"] = prefix }
            let enrolled = await post("v1/attest/keys", json: try JSONSerialization.data(withJSONObject: fields))
            let answer = enrolled?.status
            guard answer == 201 else {
                // Refused as it stands (the attestation wasn't believed, or what was sent was malformed): another key
                // would fare no better today. Busy, limited or unreachable is tried again soon.
                let refused = answer.map { (400..<500).contains($0) && $0 != 408 && $0 != 429 } ?? false
                state.notBefore = now.addingTimeInterval(refused ? Self.later
                    : enrolled?.retryAfter.map { min(max($0, 1), Self.later) } ?? Self.soon)
                return false
            }
            state.keyID = keyID
            state.enrolled = true
            state.notBefore = nil
            return true
        } catch AttestorError.unavailable {
            state.notBefore = now.addingTimeInterval(Self.soon)
        } catch {
            state.keyID = nil
            state.notBefore = now.addingTimeInterval(Self.later)
        }
        return false
    }

    private static func challenge(in body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["challenge"] as? String
    }

    /// One POST: its status, body and the wait the server asked for. Nil when there was no answer.
    private func post(_ path: String, json: Data?) async -> (status: Int, body: Data, retryAfter: TimeInterval?)? {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Ingest \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FlightDataKit/\(FlightDataKit.version)", forHTTPHeaderField: "User-Agent")
        if json != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, response) = try? await session.upload(for: request, from: json ?? Data()),
              let http = response as? HTTPURLResponse else { return nil }
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let retryAfter = ReportSender.retryDelay(header: http.value(forHTTPHeaderField: "Retry-After"), answer: answer)
        return (http.statusCode, data, retryAfter)
    }

    /// What is on disk, or a fresh start: when there is nothing, or what there is was for another server.
    func load() -> State {
        let fresh = State(endpoint: endpoint.absoluteString)
        guard let data = try? Data(contentsOf: file), let state = try? Self.decoder.decode(State.self, from: data),
              state.endpoint == fresh.endpoint else { return fresh }
        return state
    }

    private func save(_ state: State) {
        do {
            try Storage.makeDirectory(file.deletingLastPathComponent())
            try Storage.write(try Self.encoder.encode(state), to: file)
        } catch {
            Log.delivery.log(.error, "The App Attest state couldn’t be saved: \(error.localizedDescription)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Optional {
    func orElse(_ make: () async throws -> Wrapped) async rethrows -> Wrapped {
        if let self { return self }
        return try await make()
    }
}
