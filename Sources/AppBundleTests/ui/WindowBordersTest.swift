@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WindowBordersTest: XCTestCase {
    func testTopLeftRectToAppKitFrame() {
        // Test monitor is 1920x1080 (mainMonitor in unit tests)
        // A window at top-left (100, 200), 300x400: AppKit y = 1080 - (200 + 400) = 480
        let rect = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400)
        let frame = rect.toAppKitFrame()
        assertEquals(frame.origin.x, 100)
        assertEquals(frame.origin.y, 480)
        assertEquals(frame.width, 300)
        assertEquals(frame.height, 400)
    }

    func testTopEdgeWindowSitsAtScreenTop() {
        // A window flush against the top of the screen (topLeftY 0) should map to the
        // top of the AppKit space: y = screenHeight - height
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 100)
        let frame = rect.toAppKitFrame()
        assertEquals(frame.origin.y, 980) // 1080 - 100
    }

    func testCornerRadiusOverrideResolution() {
        var borders = WindowBorders()
        borders.cornerRadius = 10
        borders.cornerRadiusOverrides = ["com.apple.Terminal": 6]
        // App with an override gets it
        assertEquals(borders.cornerRadius(forAppId: "com.apple.Terminal"), 6)
        assertTrue(borders.hasCornerRadiusOverride(forAppId: "com.apple.Terminal"))
        // App without an override falls back to the default
        assertEquals(borders.cornerRadius(forAppId: "com.google.Chrome"), 10)
        assertFalse(borders.hasCornerRadiusOverride(forAppId: "com.google.Chrome"))
        // Unknown / nil app id falls back to the default
        assertEquals(borders.cornerRadius(forAppId: nil), 10)
        assertFalse(borders.hasCornerRadiusOverride(forAppId: nil))
    }

    // MARK: Corner radius (heuristic + pure alpha math)

    func testBuiltinRadiusByOsVersionAndChrome() {
        XCTAssertEqual(WindowCornerRadius.builtinRadius(osMajorVersion: 12), 5)
        XCTAssertEqual(WindowCornerRadius.builtinRadius(osMajorVersion: 14), 10)
        XCTAssertEqual(WindowCornerRadius.builtinRadius(osMajorVersion: 15), 10)
        XCTAssertEqual(WindowCornerRadius.builtinRadius(osMajorVersion: 26, chrome: .plain), 16)
        XCTAssertEqual(WindowCornerRadius.builtinRadius(osMajorVersion: 26, chrome: .toolbar), 26)
        XCTAssertEqual(WindowCornerRadius.builtinRadius(osMajorVersion: 26, chrome: .utility), 15)
    }

    func testHeuristicPrefersSystemOverride() {
        XCTAssertEqual(
            WindowCornerRadius.heuristicRadius(osMajorVersion: 26, systemOverride: 10),
            10,
        )
        XCTAssertEqual(
            WindowCornerRadius.heuristicRadius(osMajorVersion: 26, systemOverride: nil, chrome: .toolbar),
            26,
        )
        XCTAssertEqual(
            WindowCornerRadius.heuristicRadius(osMajorVersion: 15, systemOverride: 8.4),
            8,
        )
    }

    func testDetectCornerRadiusUsesProbeNotFixed() {
        var borders = WindowBorders()
        borders.cornerRadius = 99
        borders.detectCornerRadius = true
        // No app override → system probe / builtin, not the fixed 99
        let plain = borders.cornerRadius(forAppId: "com.example.App", chrome: .plain)
        let toolbar = borders.cornerRadius(forAppId: "com.example.App", chrome: .toolbar)
        XCTAssertNotEqual(plain, 99)
        XCTAssertNotEqual(toolbar, 99)
        // On Tahoe, toolbar should be larger (or equal if probes fail and table used)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 26 {
            XCTAssertGreaterThanOrEqual(toolbar, plain)
        }
        // Per-app config override still wins
        borders.cornerRadiusOverrides = ["com.example.App": 7]
        XCTAssertEqual(borders.cornerRadius(forAppId: "com.example.App", chrome: .toolbar), 7)
    }

    func testSystemCornerRadiusProbesReturnPositive() {
        // Own-process NSThemeFrame read; should work in test host on real macOS UI
        if let plain = SystemCornerRadiusProbes.shared.radius(for: .plain) {
            XCTAssertGreaterThan(plain, 0)
            XCTAssertLessThan(plain, 64)
        }
        if let toolbar = SystemCornerRadiusProbes.shared.radius(for: .toolbar) {
            XCTAssertGreaterThan(toolbar, 0)
            XCTAssertLessThan(toolbar, 64)
        }
    }

    func testEstimateRadiusMatchesSyntheticCircularCorner() {
        for r in [6, 10, 12, 20, 32] {
            let size = 64
            let estimated = WindowCornerRadius.estimateFromAlpha(size: size, maxRadius: 48) { x, y in
                WindowCornerRadius.circularCornerAlpha(radius: r, size: size, x: x, y: y)
            }
            XCTAssertEqual(estimated, r, "expected r=\(r), got \(String(describing: estimated))")
        }
    }

    func testEstimateRadiusSquareCornerIsZero() {
        let size = 32
        let estimated = WindowCornerRadius.estimateFromAlpha(size: size) { _, _ in 255 }
        XCTAssertEqual(estimated, 0)
    }

    func testEstimateRadiusFullyTransparentIsNil() {
        let size = 32
        let estimated = WindowCornerRadius.estimateFromAlpha(size: size) { _, _ in 0 }
        XCTAssertNil(estimated)
    }

    func testExpectedEdgeXQuarterCircle() {
        XCTAssertGreaterThan(WindowCornerRadius.expectedEdgeX(radius: 10, y: 0), 5)
        XCTAssertEqual(WindowCornerRadius.expectedEdgeX(radius: 10, y: 10), 0)
        XCTAssertEqual(WindowCornerRadius.expectedEdgeX(radius: 10, y: 20), 0)
    }

    func testBorderStylePrimaryColor() {
        let solid = BorderStyle.solid(RgbaColor(r: 1, g: 2, b: 3))
        assertEquals(solid.primaryColor, RgbaColor(r: 1, g: 2, b: 3))
        let grad = BorderStyle.gradient(angleDegrees: 45, stops: [
            RgbaColor(r: 10, g: 0, b: 0),
            RgbaColor(r: 0, g: 10, b: 0),
        ])
        assertEquals(grad.primaryColor, RgbaColor(r: 10, g: 0, b: 0))
        let glow = BorderStyle.glow(RgbaColor(r: 5, g: 5, b: 5), blurRadius: 8)
        assertEquals(glow.primaryColor, RgbaColor(r: 5, g: 5, b: 5))
    }

    // MARK: Dirty / occlusion math (performance-critical correctness)

    func testRegionOutsetsByWidth() {
        let r = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400)
        let region = WindowBordersMath.region(rect: r, width: 4)
        assertEquals(region.topLeftX, 96)
        assertEquals(region.topLeftY, 196)
        assertEquals(region.width, 308)
        assertEquals(region.height, 408)
    }

    func testRectsIntersectSymmetric() {
        let a = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        let b = Rect(topLeftX: 50, topLeftY: 50, width: 100, height: 100)
        let c = Rect(topLeftX: 200, topLeftY: 200, width: 10, height: 10)
        XCTAssertTrue(WindowBordersMath.rectsIntersect(a, b))
        XCTAssertTrue(WindowBordersMath.rectsIntersect(b, a))
        XCTAssertFalse(WindowBordersMath.rectsIntersect(a, c))
    }

    func testUnrelatedMoveAffectsNoBorders() {
        // 20 tiled-ish borders, mover far away (typical "other app animating" case)
        let borders = (0 ..< 20).map { i -> (id: UInt32, region: Rect) in
            (UInt32(i), Rect(topLeftX: CGFloat(i) * 100, topLeftY: 0, width: 90, height: 200))
        }
        let far = Rect(topLeftX: 5000, topLeftY: 5000, width: 50, height: 50)
        XCTAssertFalse(WindowBordersMath.overlapsAnyBorder(regions: borders, rect: far))
        let dirty = WindowBordersMath.affectedBorderIds(
            mover: 999,
            moverIsBordered: false,
            borderRegions: borders,
            oldRect: far,
            newRect: Rect(topLeftX: 5100, topLeftY: 5100, width: 50, height: 50),
        )
        XCTAssertTrue(dirty.isEmpty)
    }

    func testDraggingBorderedWindowDirtiesSelfAndOverlappingNeighbours() {
        // Window 0 (front) and 1 (behind, overlapping) are bordered; 2 is isolated
        let borders: [(id: UInt32, region: Rect)] = [
            (0, Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 200)),
            (1, Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 200)),
            (2, Rect(topLeftX: 800, topLeftY: 800, width: 100, height: 100)),
        ]
        let old = Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 200)
        let new = Rect(topLeftX: 10, topLeftY: 10, width: 200, height: 200)
        let dirty = WindowBordersMath.affectedBorderIds(
            mover: 0,
            moverIsBordered: true,
            borderRegions: borders,
            oldRect: old,
            newRect: new,
        )
        XCTAssertTrue(dirty.contains(0)) // self
        XCTAssertTrue(dirty.contains(1)) // neighbour still overlapping
        XCTAssertFalse(dirty.contains(2)) // isolated
    }

    func testActiveBorderNotMaskedByManagedNeighbour() {
        // Stack front-to-back: neighbour (1) above active (0), both managed
        let stack: [(id: UInt32, rect: Rect)] = [
            (1, Rect(topLeftX: 50, topLeftY: 50, width: 100, height: 100)),
            (0, Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 200)),
        ]
        let managed: Set<UInt32> = [0, 1]
        let region = WindowBordersMath.region(rect: stack[1].rect, width: 4)
        let occ = WindowBordersMath.occluders(
            id: 0,
            region: region,
            isActive: true,
            activeId: 0,
            activeRect: stack[1].rect,
            stack: stack,
            stackIndex: 1,
            managedIds: managed,
        )
        // Active must not be masked by managed neighbour even if stack puts neighbour above
        XCTAssertTrue(occ.isEmpty)
    }

    func testInactiveBorderAlwaysClippedByActive() {
        // Stack does not include active above inactive (tiling restack lag), but active still clips
        let inactive = Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 200)
        let active = Rect(topLeftX: 50, topLeftY: 50, width: 100, height: 100)
        let stack: [(id: UInt32, rect: Rect)] = [
            (1, inactive), // inactive is "front" in raw stack
            (0, active),
        ]
        let managed: Set<UInt32> = [0, 1]
        let region = WindowBordersMath.region(rect: inactive, width: 4)
        let occ = WindowBordersMath.occluders(
            id: 1,
            region: region,
            isActive: false,
            activeId: 0,
            activeRect: active,
            stack: stack,
            stackIndex: 0, // nothing above inactive in stack
            managedIds: managed,
        )
        XCTAssertEqual(occ.count, 1)
        XCTAssertEqual(occ[0], active)
    }
}
