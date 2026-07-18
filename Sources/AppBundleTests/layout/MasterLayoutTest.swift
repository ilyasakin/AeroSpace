@testable import AppBundle
import Common
import XCTest

@MainActor
final class MasterLayoutTest: XCTestCase {
    func testMasterLayoutChildRects_equalWeightsStayHalf() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 500)
        // Three equal-weight children: master must stay ~50%, not 1/3
        let three = masterLayoutChildRects(
            orientation: .h,
            childWeights: [1, 1, 1],
            rect: rect,
            innerGap: 0,
        )
        assertEquals(three.count, 3)
        assertEquals(three[0].width, 500, additionalMsg: "master ~half with 2 stack windows")
        assertEquals(three[0].topLeftX, 0)
        assertEquals(three[1].topLeftX, 500)
        assertEquals(three[1].width + three[0].width, 1000)
        assertEquals(three[1].height + three[2].height, 500, additionalMsg: "stack heights fill")

        // Five equal-weight children: still half, not 1/5
        let five = masterLayoutChildRects(
            orientation: .h,
            childWeights: [1, 1, 1, 1, 1],
            rect: rect,
            innerGap: 0,
        )
        assertEquals(five[0].width, 500, additionalMsg: "master still half with 4 stack windows")
        assertEquals(five[1].width, 500)
    }

    func testMasterLayoutChildRects_weightDrivenRatio() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 400)
        // Master twice as heavy as average stack pane → 2/3 of primary
        let rects = masterLayoutChildRects(
            orientation: .h,
            childWeights: [2, 1, 1],
            rect: rect,
            innerGap: 0,
        )
        // stack pane weight = avg(1,1)=1; master fraction = 2/(2+1) = 2/3
        assertEquals(rects[0].width, 1000 * 2 / 3, additionalMsg: "master 2/3 when weight 2 vs avg stack 1")
        assertEquals(rects[1].width + rects[0].width, 1000)
    }

    func testMasterLayoutChildRects_physicalGapsShrinkUsablePrimary() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 500)
        let gap: CGFloat = 20
        let rects = masterLayoutChildRects(
            orientation: .h,
            childWeights: [1, 1, 1],
            rect: rect,
            innerGap: gap,
        )
        // usable primary = 980; master half → 490; stack starts after master + gap
        assertEquals(rects[0].width, 490)
        assertEquals(rects[1].topLeftX, 490 + gap)
        assertEquals(rects[1].width, 490)
    }

    func testMasterLayoutChildRects_virtualIgnoresGaps() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 500)
        let withGap = masterLayoutChildRects(
            orientation: .h,
            childWeights: [1, 1, 1],
            rect: rect,
            innerGap: 40,
        )
        let virtual = masterLayoutChildRects(
            orientation: .h,
            childWeights: [1, 1, 1],
            rect: rect,
            innerGap: 0,
        )
        // Virtual must be gap-free (full spans abut); physical leaves gap between master and stack
        assertEquals(virtual[0].width, 500)
        assertEquals(virtual[1].topLeftX, 500)
        assertTrue(withGap[1].topLeftX > withGap[0].width)
        assertEquals(virtual[1].topLeftX, virtual[0].width)
    }

    func testMasterLayoutChildRects_singleChild() {
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 800, height: 600)
        let rects = masterLayoutChildRects(orientation: .h, childWeights: [2], rect: rect, innerGap: 10)
        assertEquals(rects, [rect])
    }

    func testLayoutCommandMasterParses() {
        testParseSingleCommandSucc(
            "layout master",
            LayoutCmdArgs(rawArgs: [], toggleBetween: [.master]),
        )
        testParseSingleCommandSucc(
            "layout h_master",
            LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_master]),
        )
    }

    func testLayoutMasterOnWorkspace_masterStaysHalf() async {
        setUpWorkspacesForTests()
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.layout = .master
        workspace.rootTilingContainer.changeOrientation(.h)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        _ = w1.focusWindow()
        try? await workspace.layoutWorkspace()
        assertEquals(workspace.rootTilingContainer.layout, .master)
        guard let r1 = w1.lastAppliedLayoutPhysicalRect,
              let r2 = w2.lastAppliedLayoutPhysicalRect,
              let r3 = w3.lastAppliedLayoutPhysicalRect
        else {
            return failExpectedActual("physical rects", "nil")
        }
        // Master left of stack
        assertTrue(r1.topLeftX <= r2.topLeftX)
        // Master ~ half the workspace padded width (monitor is 1920 in tests)
        let totalW = r1.width + r2.width // stack pane width == each stack child width when side-by-side? stack is vertical
        // In h master: stack is v, so r2.width == r3.width == stack pane width
        assertEquals(r2.width, r3.width)
        let masterPlusStack = r1.width + r2.width
        // Allow for inner gaps: master should still be roughly half of master+stack usable
        let masterFraction = r1.width / masterPlusStack
        assertTrue(masterFraction > 0.4 && masterFraction < 0.6)
    }
}
