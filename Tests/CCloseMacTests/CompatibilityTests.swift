import XCTest
@testable import CCloseMac

final class CompatibilityTests: XCTestCase {
    struct Node {
        var id: String
        var children: [Node] = []
    }
    func testMissionControlOldDockAndNewWindowManagerLayouts() {
        let display = Node(id: "mc.display", children: [Node(id: "mc.spaces")])
        let dock = Node(id: "app", children: [Node(id: "mc", children: [display])])
        let manager = Node(id: "app", children: [display])
        for root in [dock, manager] {
            XCTAssertEqual(MissionControlTree.displays(root, identifier: { $0.id }, children: { $0.children }).map(\.id), ["mc.display"])
        }
        let emptyStub = Node(id: "app", children: [Node(id: "mc")])
        XCTAssertTrue(MissionControlTree.displays(emptyStub, identifier: { $0.id }, children: { $0.children }).isEmpty)
        let unrelated = Node(id: "app", children: [Node(id: "unrelated", children: [display])])
        XCTAssertTrue(MissionControlTree.displays(unrelated, identifier: { $0.id }, children: { $0.children }).isEmpty)
    }
    func testPreflightCannotProduceVerifiedCheckWithoutUsableAccess() {
        XCTAssertEqual(PermissionStatus.resolve(preflight: false, usable: true), .denied)
        XCTAssertEqual(PermissionStatus.resolve(preflight: true, usable: nil), .checking)
        XCTAssertEqual(PermissionStatus.resolve(preflight: true, usable: false), .unavailable)
        XCTAssertEqual(PermissionStatus.resolve(preflight: true, usable: true), .ready)
        XCTAssertNotEqual(PermissionStatus.checking.menuState, .on)
        XCTAssertNotEqual(PermissionStatus.unavailable.menuState, .on)
    }
}
