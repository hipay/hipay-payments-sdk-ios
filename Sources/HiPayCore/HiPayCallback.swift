import Foundation
import HiPayPayments

/// Redirect outcome carried by the return deep link — informational only:
/// confirm the final state via `HiPayPayment.getTransaction` (FR9).
public enum HiPayCallbackStatus: Sendable {
    case accept
    case decline
    case pending
    case exception
    case cancel
}

/// Typed result of a parsed return deep link (FR8).
public struct HiPayCallbackResult: Sendable {
    public let orderId: String
    public let status: HiPayCallbackStatus
    public let queryParams: [String: String]
}

extension HiPay {

    /// Parses a HiPay return deep link
    /// (`{scheme}://hipay-payments/gateway/orders/{orderId}/{status}?…`).
    public static func parseCallback(_ url: URL) throws -> HiPayCallbackResult {
        do {
            let kmp = try CallbackUrlParser.shared.parse(url: url.absoluteString)
            let status: HiPayCallbackStatus
            switch kmp.status {
            case .accept: status = .accept
            case .decline: status = .decline
            case .pending: status = .pending
            case .exception: status = .exception
            default: status = .cancel
            }
            var params: [String: String] = [:]
            for (key, value) in kmp.queryParams {
                if let k = key as? String, let v = value as? String { params[k] = v }
            }
            return HiPayCallbackResult(orderId: kmp.orderId, status: status, queryParams: params)
        } catch {
            throw HiPayError.from(error)
        }
    }
}
