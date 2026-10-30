import Foundation
import SyncCore

/// The owner's choices, kept in `UserDefaults`. Nothing in here is secret.
///
/// The destination chat is written by `TelegramService.setDestination`; this type reads and writes the same keys.
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    static let includeScreenshotsKey = "includeScreenshots"
    static let resendEditsKey = "resendEdits"
    static let setupCompletedKey = "setupCompleted"
    static let intentBudgetSecondsKey = "intentBudgetSeconds"
    static let defaultIntentBudgetSeconds: TimeInterval = 25
    static let authLostNotifiedAtKey = "authLostNotifiedAt"
    static let lastChannelCheckAtKey = "lastChannelCheckAt"

    private let defaults: UserDefaults

    /// - Parameter defaults: Where the values live. Tests pass their own suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether screenshots and screen recordings are uploaded. On by default.
    var includeScreenshots: Bool {
        get { defaults.object(forKey: Self.includeScreenshotsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.includeScreenshotsKey) }
    }

    /// Whether an edited photo is uploaded again. Off by default.
    var resendEdits: Bool {
        get { defaults.bool(forKey: Self.resendEditsKey) }
        set { defaults.set(newValue, forKey: Self.resendEditsKey) }
    }

    /// Whether the owner finished the setup flow.
    var setupCompleted: Bool {
        get { defaults.bool(forKey: Self.setupCompletedKey) }
        set { defaults.set(newValue, forKey: Self.setupCompletedKey) }
    }

    /// How long a Shortcuts-triggered sync may run, in seconds. 25 unless a positive value was stored.
    var intentBudgetSeconds: TimeInterval {
        let value = defaults.double(forKey: Self.intentBudgetSecondsKey)
        return value > 0 ? value : Self.defaultIntentBudgetSeconds
    }

    /// When the "Telegram logged out" notification last showed.
    var authLostNotifiedAt: Date? {
        get { defaults.object(forKey: Self.authLostNotifiedAtKey) as? Date }
        set { defaults.set(newValue, forKey: Self.authLostNotifiedAtKey) }
    }

    /// When the app last compared its records with the backup chat.
    var lastChannelCheckAt: Date? {
        get { defaults.object(forKey: Self.lastChannelCheckAtKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastChannelCheckAtKey) }
    }

    /// The chat the backup goes to, if one was chosen.
    var destinationChatId: Int64? {
        get {
            let value = defaults.integer(forKey: TelegramService.destinationChatIdKey)
            return value == 0 ? nil : Int64(value)
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: TelegramService.destinationChatIdKey)
            } else {
                defaults.removeObject(forKey: TelegramService.destinationChatIdKey)
            }
        }
    }

    /// The name of the destination chat, for display.
    var destinationTitle: String? {
        get { defaults.string(forKey: TelegramService.destinationTitleKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: TelegramService.destinationTitleKey)
            } else {
                defaults.removeObject(forKey: TelegramService.destinationTitleKey)
            }
        }
    }

    /// The options the sync engine reads on every run.
    var syncSettings: SyncSettings {
        SyncSettings(includeScreenshots: includeScreenshots, resendEdits: resendEdits)
    }
}
