import Foundation
import Network

/// The Bonjour TXT record the iPhone publishes on `_tacittype._tcp`.
///
/// The iPhone runs two listeners. The main one accepts paired Macs only. The pairing one exists
/// only while the iPhone shows a pairing code, and it accepts nothing but a pairing exchange.
/// Keeping them apart means a code can never be used to open a normal session.
public struct ServiceAdvert: Sendable, Equatable {
    public var deviceId: UUID
    public var name: String
    public var protocolVersion: UInt8
    public var isPairing: Bool

    public init(deviceId: UUID, name: String, protocolVersion: UInt8 = Constants.protocolVersion, isPairing: Bool) {
        self.deviceId = deviceId
        self.name = name
        self.protocolVersion = protocolVersion
        self.isPairing = isPairing
    }

    /// Bonjour instance names must be unique per host, so the pairing listener gets a suffix.
    public var serviceName: String { isPairing ? "\(name) (Pairing)" : name }

    public var txtRecord: NWTXTRecord {
        var record = NWTXTRecord()
        record["id"] = deviceId.uuidString
        record["name"] = name
        record["v"] = String(protocolVersion)
        if isPairing { record["pair"] = "1" }
        return record
    }

    public init?(txtRecord record: NWTXTRecord) {
        guard let id = record["id"].flatMap(UUID.init(uuidString:)),
              let version = record["v"].flatMap(UInt8.init)
        else { return nil }
        self.init(deviceId: id, name: record["name"] ?? "iPhone", protocolVersion: version,
                  isPairing: record["pair"] == "1")
    }

    public var service: NWListener.Service {
        NWListener.Service(name: serviceName, type: Constants.bonjourServiceType, domain: nil, txtRecord: txtRecord)
    }
}
