import CoreGraphics
import Testing
@testable import LiquidMouse

/// Every kind of cursor the reader can report.
nonisolated let allContexts: [CursorContext] = [
    .pointer, .link, .text(halfHeight: 9), .verticalText, .grab, .grabbing,
    .resize(direction: CGVector(dx: 1, dy: 0), bothWays: true, divider: true),
    .resize(direction: CGVector(dx: 0, dy: 1), bothWays: false, divider: true),
    .resize(direction: CGVector(dx: -0.5.squareRoot(), dy: 0.5.squareRoot()), bothWays: true, divider: false),
    .crosshair, .notAllowed, .copy, .alias, .menu, .zoom(magnifies: true), .zoom(magnifies: false), .other, .hidden,
]

/// Steps the body as the engine does at 120 frames a second.
private func step(_ body: inout LiquidBody, to point: SIMD2<Double>, frames: Int = 1, context: CursorContext = .pointer,
                  present: Bool = true) {
    for _ in 0..<frames {
        body.step(to: point, dt: 1.0 / 120, context: context, pressed: false, present: present)
    }
}

/// A body that has had two seconds to settle under a still pointer.
private func settled(_ form: CursorForm = .dot, context: CursorContext = .pointer) -> LiquidBody {
    var body = LiquidBody(at: .zero)
    body.tuning.form = form
    body.step(to: .zero, dt: 0, context: context, pressed: false, present: true)
    step(&body, to: .zero, frames: 240, context: context)
    return body
}

@Suite struct LiquidBodyTests {
    @Test func theTailStretchesWhileMovingAndGathersBackAfterAStop() {
        var body = settled()
        var point = SIMD2<Double>.zero
        for _ in 0..<30 {
            point.x += 900.0 / 120
            step(&body, to: point)
        }
        #expect(body.shape.strokes.count > 1)
        step(&body, to: point, frames: 60)
        #expect(body.shape.strokes.count == 1)
        #expect(body.isSettled)
    }

    @Test func slowFramesStillBringTheCursorIn() {
        var body = LiquidBody(at: .zero)
        body.step(to: .zero, dt: 0, context: .pointer, pressed: false, present: true)
        for _ in 0..<20 {
            body.step(to: .zero, dt: 0.25, context: .pointer, pressed: false, present: true)
        }
        #expect(!body.shape.isEmpty)
    }

    /// Slow movement must not make the arrow twitch: from one frame to the next its outline moves by a hair, and
    /// its tail does not flicker in and out.
    @Test(arguments: [15.0, 30.0, 60.0, 120.0])
    func theArrowMovesSmoothlyWhenThePointerIsSlow(speed: Double) {
        var body = settled(.arrow)
        var point = SIMD2<Double>.zero
        var previous = body.shape
        var tailChanges = 0
        for _ in 0..<480 {
            point += SIMD2(-0.6, 0.8) * speed / 120
            step(&body, to: point)
            let shape = body.shape
            let jump = zip(shape.outline, previous.outline).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            #expect(jump < 0.1)
            if shape.strokes.count != previous.strokes.count {
                tailChanges += 1
            }
            previous = shape
        }
        #expect(tailChanges <= 1)
    }

    /// At no bounce a change of shape settles without overshooting; at full bounce it wobbles past its target.
    @Test func noBounceMeansNoOvershoot() {
        func smallestDot(bounce: Double) -> CGFloat {
            var body = settled()
            body.tuning.bounce = bounce
            var smallest = CGFloat.infinity
            for _ in 0..<240 {
                body.step(to: .zero, dt: 1.0 / 120, context: .link, pressed: false, present: true)
                smallest = min(smallest, body.shape.strokes.first?.first?.radius ?? 0)
            }
            return smallest
        }
        let target = CGFloat(0.42 * Glyph.designRadius)
        #expect(smallestDot(bounce: 0) >= target - 0.01)
        #expect(smallestDot(bounce: 1) < target - 0.1)
    }

    @Test func aJumpAcrossTheScreenLeavesNoTail() {
        var body = settled()
        step(&body, to: SIMD2(2000, 900))
        #expect(body.shape.strokes.count == 1)
    }

    @Test func itDrainsAwayAndComesBack() {
        var body = settled()
        step(&body, to: .zero, frames: 240, present: false)
        #expect(body.shape.isEmpty)
        step(&body, to: .zero, frames: 240)
        #expect(!body.shape.isEmpty)
    }

    @Test(arguments: allContexts, [CursorForm.dot, .arrow])
    func everyShapeCanBeDrawn(context: CursorContext, form: CursorForm) {
        let shape = settled(form, context: context).shape
        #expect(!shape.isEmpty)
        let points = shape.strokes.joined().map(\.center) + shape.outline + shape.rings.map(\.center)
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(shape.strokes.joined().allSatisfy { $0.radius >= 0 })
        #expect(!shape.path(grownBy: 1.25).isEmpty)
    }

    /// The text cursor, the grab ring, the resize spindles and the crosshair are the same in both forms: the arrow's
    /// own versions of them were tried and rejected.
    @Test(arguments: [
        CursorContext.text(halfHeight: 9), .verticalText, .grab, .grabbing,
        .resize(direction: CGVector(dx: 1, dy: 0), bothWays: true, divider: true), .crosshair,
    ])
    func preciseToolsAreTheSameInBothForms(context: CursorContext) {
        let dot = Glyph(for: context, form: .dot, dotRadius: 6.5)
        let arrow = Glyph(for: context, form: .arrow, dotRadius: 6.5)
        #expect(dot.values == arrow.values)
        #expect(!arrow.isArrow)
    }

    @Test(arguments: allContexts)
    func glyphsSurviveTheirListOfNumbers(context: CursorContext) {
        let values = Glyph(for: context, form: .arrow, dotRadius: 6.5).values
        var glyph = Glyph()
        glyph.values = values
        #expect(glyph.values == values)
    }
}
