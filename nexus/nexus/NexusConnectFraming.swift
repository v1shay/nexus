import CryptoKit
import Foundation

enum NexusFrameCodec {
    static func frame(_ payload: Data, maximumBytes: Int = NexusConnectProtocol.maximumDataFrameBytes) throws -> Data {
        guard payload.count <= maximumBytes, payload.count <= Int(UInt32.max) else {
            throw NexusConnectError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }
}

struct NexusFrameDecoder {
    private(set) var bufferedBytes = 0
    private var buffer = Data()
    let maximumBytes: Int

    init(maximumBytes: Int = NexusConnectProtocol.maximumDataFrameBytes) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        bufferedBytes = buffer.count

        var frames: [Data] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= UInt32(maximumBytes) else {
                throw NexusConnectError.frameTooLarge(Int(length))
            }
            let frameEnd = 4 + Int(length)
            guard buffer.count >= frameEnd else { break }
            frames.append(buffer.subdata(in: 4..<frameEnd))
            buffer.removeSubrange(0..<frameEnd)
        }
        guard buffer.count <= maximumBytes + MemoryLayout<UInt32>.size else {
            throw NexusConnectError.frameTooLarge(buffer.count)
        }
        bufferedBytes = buffer.count
        return frames
    }
}

enum NexusWireDirection: String, Sendable {
    case clientToHost
    case hostToClient
}

struct NexusSecureChannel {
    let sessionID: UUID
    let protocolVersion: Int
    private let key: SymmetricKey
    private let outgoingDirection: NexusWireDirection
    private let incomingDirection: NexusWireDirection
    private var nextOutgoingSequence: UInt64 = 0
    private var nextIncomingSequence: UInt64 = 0

    init(
        sessionID: UUID,
        key: SymmetricKey,
        outgoingDirection: NexusWireDirection,
        incomingDirection: NexusWireDirection,
        protocolVersion: Int = NexusConnectProtocol.currentVersion
    ) {
        self.sessionID = sessionID
        self.protocolVersion = protocolVersion
        self.key = key
        self.outgoingDirection = outgoingDirection
        self.incomingDirection = incomingDirection
    }

    mutating func seal(_ message: NexusConnectMessage) throws -> Data {
        guard message.sessionID == sessionID,
              message.protocolVersion == protocolVersion else {
            throw NexusConnectError.malformedFrame
        }
        let sequence = nextOutgoingSequence
        let plaintext = try NexusPayloadCoder.encoder.encode(message)
        guard plaintext.count <= NexusConnectProtocol.maximumDataFrameBytes - 64 else {
            throw NexusConnectError.frameTooLarge(plaintext.count)
        }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData(direction: outgoingDirection, sequence: sequence)
        )
        let combined = box.combined
        var packet = sequence.bigEndianData
        packet.append(combined)
        nextOutgoingSequence += 1
        return try NexusFrameCodec.frame(packet)
    }

    mutating func open(_ packet: Data) throws -> NexusConnectMessage {
        guard packet.count > MemoryLayout<UInt64>.size else { throw NexusConnectError.malformedFrame }
        let sequence = UInt64(bigEndianBytes: packet.prefix(8))
        guard sequence == nextIncomingSequence else { throw NexusConnectError.replayDetected }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: packet.dropFirst(8))
        } catch {
            throw NexusConnectError.malformedFrame
        }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                box,
                using: key,
                authenticating: authenticatedData(direction: incomingDirection, sequence: sequence)
            )
        } catch {
            throw NexusConnectError.authenticationFailed
        }
        let message = try NexusPayloadCoder.decoder.decode(NexusConnectMessage.self, from: plaintext)
        guard message.sessionID == sessionID,
              message.protocolVersion == protocolVersion else {
            throw NexusConnectError.malformedFrame
        }
        nextIncomingSequence += 1
        return message
    }

    private func authenticatedData(direction: NexusWireDirection, sequence: UInt64) -> Data {
        Data(
            "nexus-connect|\(protocolVersion)|\(sessionID.uuidString.lowercased())|\(direction.rawValue)|\(sequence)"
                .utf8
        )
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt64>.size)
    }

    init(bigEndianBytes bytes: Data.SubSequence) {
        self = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
