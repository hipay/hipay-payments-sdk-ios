import Foundation
import HiPayFullservice

/// The single error type surfaced by the SDK's Swift API (mirrors the KMP
/// `HiPayErrorCode` taxonomy, D3). Messages are SDK-synthesized and safe to
/// log; backend-provided text is in `apiMessage` only.
public enum HiPayError: Error, Sendable {
    case network
    case client(httpStatus: Int)
    case server(httpStatus: Int)
    case api(code: Int, message: String?)
    case validation(reason: String)
    case unknown(message: String)
}

extension HiPayError {
    /// Maps a Kotlin exception (crossing the ObjC boundary as NSError) to the
    /// Swift error surface. Internal to the facade (D4).
    package static func from(_ error: Error) -> HiPayError {
        let nsError = error as NSError
        guard let kotlin = nsError.userInfo["KotlinException"] as? HiPayException else {
            return .unknown(message: nsError.localizedDescription)
        }
        let status = kotlin.httpStatus?.intValue ?? 0
        switch kotlin.code {
        case .network:
            return .network
        case .client:
            return .client(httpStatus: status)
        case .server:
            return .server(httpStatus: status)
        case .api:
            return .api(code: kotlin.apiCode?.intValue ?? 0, message: kotlin.apiMessage)
        case .validation:
            return .validation(reason: kotlin.message ?? "invalid input")
        default:
            return .unknown(message: kotlin.message ?? "unexpected error")
        }
    }
}
