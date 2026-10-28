import SyncCore
import XCTest

@testable import TelegramPhotos

final class SetupStageTests: XCTestCase {
    func testDestinationComesFirst() {
        for photos in [LibraryAuthorization.full, .limited, .denied, .notDetermined] {
            XCTAssertEqual(
                SetupStage.next(hasDestination: false, photos: photos, notificationsPending: true), .destination)
        }
    }

    func testPhotosUntilFullAccess() {
        for photos in [LibraryAuthorization.limited, .denied, .notDetermined] {
            XCTAssertEqual(
                SetupStage.next(hasDestination: true, photos: photos, notificationsPending: false), .photos(photos))
        }
    }

    func testNotificationsOnlyWhileUndecided() {
        XCTAssertEqual(
            SetupStage.next(hasDestination: true, photos: .full, notificationsPending: true), .notifications)
        XCTAssertEqual(
            SetupStage.next(hasDestination: true, photos: .full, notificationsPending: false), .finishing)
    }

    func testPickerOrderPutsSavedMessagesFirst() {
        let chats = [
            ChatSummary(id: 1, title: "Family", kind: .group),
            ChatSummary(id: 2, title: "Backups", kind: .channel),
            ChatSummary(id: 3, title: "Saved Messages", kind: .savedMessages),
            ChatSummary(id: 4, title: "Work", kind: .group),
        ]
        XCTAssertEqual(DestinationView.pickerOrder(chats).map(\.id), [3, 1, 2, 4])
    }

    func testPickerOrderDropsRepeatedChats() {
        let chats = [
            ChatSummary(id: 1, title: "Family", kind: .group),
            ChatSummary(id: 1, title: "Family", kind: .group),
            ChatSummary(id: 3, title: "Saved Messages", kind: .savedMessages),
        ]
        XCTAssertEqual(DestinationView.pickerOrder(chats).map(\.id), [3, 1])
    }
}
