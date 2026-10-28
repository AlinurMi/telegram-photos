/// How Telegram delivered the login code, and whether another code can be requested.
import Foundation

struct CodeDelivery: Equatable, Sendable {
    enum Method: Equatable, Sendable {
        /// A message in the "Telegram" chat of an app where the owner is already logged in.
        case telegramApp
        case sms
        case call
        /// A way this app can't receive (Firebase, Fragment, a missed call).
        case unreachable

        /// Maps a TDLib `authenticationCodeType...` name.
        init(typeName: String) {
            switch typeName {
            case "authenticationCodeTypeTelegramMessage":
                self = .telegramApp
            case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase":
                self = .sms
            case "authenticationCodeTypeCall":
                self = .call
            default:
                self = .unreachable
            }
        }

        var explanation: String {
            switch self {
            case .telegramApp:
                return
                    "Telegram sent the code as a message in your Telegram app, in the chat named \"Telegram\". Open Telegram on a device where you're already logged in."
            case .sms:
                return "Telegram sent the code by text message."
            case .call:
                return "Telegram will call you and read out the code."
            case .unreachable:
                return
                    "Telegram chose a delivery method this app can't receive. Log in to Telegram on another device so the code can arrive there, then tap Resend code."
            }
        }
    }

    let method: Method
    /// Whether Telegram offers another delivery method.
    let canResend: Bool
    /// The earliest moment a new code can be requested.
    let resendAfter: Date
}
