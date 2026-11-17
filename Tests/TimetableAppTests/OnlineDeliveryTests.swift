import XCTest
@testable import TimetableApp

final class OnlineDeliveryTests: XCTestCase {
    func testExplicitOnlineLocations() {
        for location in ["线上授课", "线上", "在线", "网络授课", "在线教学", "网课", "线上（腾讯会议）", "线上：https://example.org/meeting", "腾讯会议", "ZOOM会议"] {
            XCTAssertTrue(OnlineDelivery.isOnline(location: location), location)
        }
    }

    func testPhysicalOrAmbiguousLocationDoesNotGetMarkedOnline() {
        for location in ["", "教西B2-301", "网络实验室", "在线性代数实验室", "线上路101号", "https://example.org/map"] {
            XCTAssertFalse(OnlineDelivery.isOnline(location: location), location)
        }
    }

    func testOnlyThisScheduleLocationDeterminesStatus() {
        let sharedSource = "课程甲 01(1周) (1节)\u{00a0}楼101\u{00a0}教师(2周) (1节)\u{00a0}线上授课\u{00a0}教师"
        let physical = Course(name: "课程甲", location: "楼101", weeks: [1], rawText: sharedSource)
        let online = Course(name: "课程甲", location: "线上授课", weeks: [2], rawText: sharedSource)
        XCTAssertFalse(physical.isOnline)
        XCTAssertTrue(online.isOnline)
        XCTAssertEqual(online.location, "线上授课")
    }
}
