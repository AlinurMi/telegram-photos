import SyncCore

/// Which screen comes after login. Worked out from what's already saved, so a relaunch resumes in the right place.
enum SetupStage: Equatable {
    /// Choose where backups go.
    case destination
    /// Photos access isn't Full Access yet. `access` decides between asking and sending the owner to Settings.
    case photos(LibraryAuthorization)
    case notifications
    /// Everything is in place; setup is being marked as done.
    case finishing

    /// The first step that still needs the owner.
    ///
    /// - Parameter notificationsPending: `true` while the owner hasn't answered the notifications step yet.
    static func next(hasDestination: Bool, photos: LibraryAuthorization, notificationsPending: Bool) -> SetupStage {
        guard hasDestination else { return .destination }
        guard photos == .full else { return .photos(photos) }
        return notificationsPending ? .notifications : .finishing
    }
}
