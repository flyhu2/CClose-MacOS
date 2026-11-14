import XCTest
@testable import CCloseMac

final class DesktopModeTests: XCTestCase {
    let desktops = [ManagedDesktop(id: 1, display: "Main", type: 0, active: true),
                    ManagedDesktop(id: 2, display: "Main", type: 0, active: false),
                    ManagedDesktop(id: 3, display: "Main", type: 4, active: false)]

    func testWholeApplicationRequiresOneRestorableDesktop() throws {
        XCTAssertEqual(try DesktopBridge.sourceDesktop(memberships: [[1], [1]], desktops: desktops).id, 1)
        XCTAssertThrowsError(try DesktopBridge.sourceDesktop(memberships: [[1], [2]], desktops: desktops))
        XCTAssertThrowsError(try DesktopBridge.sourceDesktop(memberships: [[1, 2]], desktops: desktops))
        XCTAssertThrowsError(try DesktopBridge.sourceDesktop(memberships: [[3]], desktops: desktops))
        XCTAssertThrowsError(try DesktopBridge.sourceDesktop(memberships: [], desktops: desktops))
    }

    func testCleanupNeverRemovesExistingOrOccupiedDesktop() {
        XCTAssertTrue(DesktopLease.mayRemove(owned: 9, origin: 1, before: [1, 2], occupied: false))
        for id: UInt64 in [0, 1, 2] {
            XCTAssertFalse(DesktopLease.mayRemove(owned: id, origin: 1, before: [1, 2], occupied: false))
        }
        XCTAssertFalse(DesktopLease.mayRemove(owned: 9, origin: 1, before: [1, 2], occupied: true))
    }

    func testRecoveryJournalPreservesOwnershipAndRejectsReusedPID() throws {
        let record = DesktopLease(bootID: "boot", pid: 10, bundleID: "qa", launched: 100, origin: 1, owned: 9,
                                  display: "Main", sourceWindow: 20, phase: "moving", existingIDs: [1, 2])
        let restored = try JSONDecoder().decode(DesktopLease.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.existingIDs, [1, 2])
        XCTAssertEqual(restored.owned, 9)
        XCTAssertTrue(restored.matches(pid: 10, bundleID: "qa", launched: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(restored.matches(pid: 10, bundleID: "qa", launched: Date(timeIntervalSince1970: 101)))
        XCTAssertFalse(restored.matches(pid: 10, bundleID: "different", launched: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(restored.matches(pid: 11, bundleID: "qa", launched: Date(timeIntervalSince1970: 100)))
    }
}
