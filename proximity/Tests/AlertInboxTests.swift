import XCTest
@testable import FluniProx

final class AlertInboxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testPostUsesTheNotificationsOwnWordsNewestFirst() {
        var box = AlertInbox()
        box.post(.nearby, at: at(0))
        box.post(.closeContact, at: at(10))
        box.post(.building, buildingID: "green", buildingName: "Green Library", at: at(20))
        XCTAssertEqual(box.alerts.map(\.kind), [.building, .closeContact, .nearby], "newest first")
        for a in box.alerts {
            let t = NotificationRoute.text(kind: a.kind, detailed: true, buildingName: a.kind == .building ? "Green Library" : nil)
            XCTAssertEqual(a.title, t.title, "\(a.kind)")
            XCTAssertEqual(a.body, t.body, "\(a.kind)")
            XCTAssertFalse(a.read)
        }
        XCTAssertEqual(box.alerts[0].buildingID, "green")
        XCTAssertNil(box.alerts[1].buildingID, "only walk-in alerts carry a building")
        XCTAssertTrue(box.alerts[0].body.contains("Green Library"), box.alerts[0].body)
        XCTAssertEqual(box.unreadCount, 3)
    }

    func testBuildingIDIsDroppedForOtherKinds() {
        var box = AlertInbox()
        box.post(.closeContact, buildingID: "green", at: at(0))
        XCTAssertNil(box.alerts[0].buildingID)
    }

    func testOutOfOrderTimeStillLandsInTimeOrder() {
        var box = AlertInbox()
        box.post(.nearby, at: at(10))
        box.post(.closeContact, at: at(5))
        box.post(.nearby, at: at(7))
        XCTAssertEqual(box.alerts.map(\.at), [at(10), at(7), at(5)])
    }

    func testMarkReadOneAllAndByKind() {
        var box = AlertInbox()
        let a = box.post(.nearby, at: at(0))
        box.post(.closeContact, at: at(1))
        box.post(.closeContact, at: at(2))
        box.markRead(a)
        XCTAssertEqual(box.unreadCount, 2)
        XCTAssertEqual(box.unread.map(\.kind), [.closeContact, .closeContact])
        box.markRead(UUID())  // unknown id: nothing happens
        XCTAssertEqual(box.unreadCount, 2)
        box.post(.nearby, at: at(3))
        box.markAllRead(.closeContact)
        XCTAssertEqual(box.unread.map(\.kind), [.nearby])
        box.markAllRead()
        XCTAssertEqual(box.unreadCount, 0)
        XCTAssertEqual(box.alerts.count, 4, "reading never deletes")
    }

    func testObserveMatchesTheNotifierExactly() {
        // A day of levels: every time AlertNotifier says "notify", the inbox gets exactly one alert of that kind.
        let levels: [AlertLevel] = [.none, .nearby, .nearby, .none, .nearby, .closeContact, .closeContact, .nearby,
                                    .none, .closeContact, .none, .none, .nearby]
        var box = AlertInbox()
        var notifiedByInbox = AlertLevel.none, notifiedByModel = AlertLevel.none
        var posted: [AlertLevel] = []
        for (i, l) in levels.enumerated() {
            notifiedByInbox = box.observe(level: l, notified: notifiedByInbox, at: at(Double(i)))
            let n = AlertNotifier.next(level: l, notified: notifiedByModel)
            notifiedByModel = n.notified
            if let p = n.notify { posted.append(p) }
            XCTAssertEqual(notifiedByInbox, notifiedByModel)
        }
        XCTAssertEqual(posted, [.nearby, .nearby, .closeContact, .closeContact, .nearby])
        XCTAssertEqual(box.alerts.count, posted.count, "one in-app alert per notification")
        XCTAssertEqual(box.alerts.reversed().map(\.kind), posted.compactMap(AlertInbox.kind(for:)))
        XCTAssertNil(AlertInbox.kind(for: .none))
    }

    func testPruneKeepsExactly24Hours() {
        var box = AlertInbox()
        box.post(.nearby, at: at(0))
        box.post(.closeContact, at: at(60))
        box.prune(now: at(60 + 24 * 60))
        XCTAssertEqual(box.alerts.map(\.kind), [.closeContact], "the 25 h old one goes, exactly 24 h stays")
        box.prune(now: at(60 + 24 * 60 + 0.01))
        XCTAssertTrue(box.alerts.isEmpty)
        XCTAssertEqual(box.unreadCount, 0)
    }

    func testRoundTripsAndToleratesJunk() throws {
        var box = AlertInbox()
        let id = box.post(.closeContact, at: at(0))
        box.post(.building, buildingID: "gates", buildingName: "Gates", at: at(1))
        box.markRead(id)
        XCTAssertEqual(AlertInbox.decode(try AlertInbox.encode(box)), box)
        XCTAssertEqual(AlertInbox.decode(Data("{".utf8)), AlertInbox())
        XCTAssertEqual(AlertInbox.decode(Data(#"{"alerts":[{"kind":"nope"}]}"#.utf8)), AlertInbox(), "unknown kind: empty, not a crash")
    }
}
