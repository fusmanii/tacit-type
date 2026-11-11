import Foundation
import Network
import Security

/// `NWParameters` for the Mac ↔ iPhone link: TLS-PSK over TCP, the Tacit framer, and AWDL allowed.
///
/// Network.framework only negotiates PSK with the TLS 1.2 suite `TLS_PSK_WITH_AES_128_GCM_SHA256`.
/// TLS 1.3 PSK handshakes fail outright, and the ECDHE-PSK suites are silently ignored. Forward
/// secrecy for pairing comes from the X25519 exchange in `Pairing` instead.
public enum LinkParameters {
    /// Mac side. One key, one identity.
    public static func client(key: Data, identity: PSKIdentity) -> NWParameters {
        let tls = tlsOptions()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(sec, key.dispatchData, identity.data.dispatchData)
        // A cached session would let a Mac reconnect after the iPhone dropped its key.
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        return parameters(tls: tls)
    }

    /// iPhone side. Every key the listener accepts, keyed by the identity the Mac presents.
    ///
    /// The server can't look a key up per connection (`sec_protocol_options_set_pre_shared_key_selection_block`
    /// sees the identity but can't supply the key), so the listener is rebuilt whenever keys change.
    public static func server(keys: [PSKIdentity: Data]) -> NWParameters {
        let tls = tlsOptions()
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key.dispatchData, identity.data.dispatchData)
        }
        return parameters(tls: tls)
    }

    /// For `NWBrowser`. Includes AWDL so the iPhone is found with no shared network.
    public static func browser() -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func tlsOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return tls
    }

    private static func parameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Notice a vanished peer in about 10 s even when nothing is being sent.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: TacitFramer.definition), at: 0)
        return parameters
    }
}

extension Data {
    var dispatchData: __DispatchData {
        withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
