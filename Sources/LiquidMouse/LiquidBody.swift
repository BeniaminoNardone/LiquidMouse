import CoreGraphics
import Foundation
import simd

/// A value that chases its target like a mass on a damped spring.
struct Spring {
    var value: Double
    var target: Double
    private var velocity = 0.0

    init(_ value: Double) {
        self.value = value
        target = value
    }

    var isSettled: Bool { value == target && velocity == 0 }

    /// `damping` is the damping ratio: below 1 the value overshoots and bounces before settling.
    mutating func step(dt: Double, frequency: Double, damping: Double) {
        let omega = 2 * Double.pi * frequency
        // Stiff springs go unstable when a slow frame is integrated in one go.
        let steps = max(1, Int((dt * 480).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * h
            value += velocity * h
        }
        if abs(target - value) < 0.01, abs(velocity) < 0.5 {
            value = target
            velocity = 0
        }
    }

    /// A sudden push, in units per second.
    mutating func kick(_ impulse: Double) {
        velocity += impulse
    }
}

/// The cursor as a drop of liquid: a dot at rest that stretches into a long tail while it moves, squeezes while the
/// mouse is pressed and drains away when left alone. It takes a different shape for each thing the mouse can do.
struct LiquidBody {
    struct Tuning: Equatable, Codable {
        var appearance = BodyLook.automatic
        /// Radius of the resting dot, in points.
        var dotRadius = Glyph.designRadius
        /// Longest the tail can get, in points. Zero turns it off.
        var trailLength = 160.0
        /// How quickly each piece of the tail catches up with the one ahead of it, per second. Lower is lazier.
        var trailResponse = 80.0
        /// From 0, every movement settles without overshooting, to 1, everything wobbles and bounces.
        var bounce = 0.5
        /// Shrinks the dot to about half its size while the pointer moves slowly, as it does when aiming.
        var shrinksWhenAiming = false
        /// Throws a few drops out of the dot when the mouse is pressed.
        var splashes = true
        var form = CursorForm.arrow

        /// How far from the pointer the body can extend, in points. The widest glyphs reach about 3 dot radii.
        var reach: Double { trailLength + 3 * dotRadius }

        /// The damping ratio of one of the body's springs, from how firm it is (`stiff`, below 1). Below 1 a spring
        /// overshoots. From the middle of `bounce` up, every spring loosens alike; from the middle down they all firm
        /// up, to 1 at no bounce, where nothing overshoots.
        fileprivate func damping(_ stiff: Double) -> Double {
            let loose = max(0.15, stiff - 0.45 * bounce)
            guard bounce < 0.5 else { return loose }
            let middle = stiff - 0.45 * 0.5
            return middle + (1 - middle) * (1 - bounce / 0.5)
        }
    }

    struct Blob: Equatable {
        var center: CGPoint
        var radius: CGFloat
    }

    struct Ring: Equatable {
        var center: CGPoint
        var radius: CGFloat
        var width: CGFloat
    }

    /// What to draw, in points relative to the pointer, y up.
    struct Shape: Equatable {
        /// Solid pieces, each a run of circles joined into one stroke. A single circle is a dot.
        var strokes: [[Blob]] = []
        var rings: [Ring] = []
        /// The drops of a press, which fly on from where the press happened while the pointer moves on.
        var splash: [[Blob]] = []
        /// A closed outline, wound counter-clockwise like every other piece: the arrow.
        var outline: [CGPoint] = []

        var isEmpty: Bool { strokes.isEmpty && rings.isEmpty && splash.isEmpty && outline.isEmpty }
    }

    private static let nodeCount = 10
    /// The splash: how many drops, how long they live, how fast the air slows them (per second).
    private static let dropletCount = 7
    private static let dropletLife = 0.32
    private static let dropletDrag = 7.0
    /// Below this speed, in points per second, the pointer is aiming; above the other, travelling.
    private static let aimingSpeed = 200.0
    private static let travellingSpeed = 450.0
    /// How much smaller the dot gets while aiming: to 45% of its size.
    private static let aimingShrink = 0.55
    /// Seconds over which the pointer's speed is averaged.
    private static let speedSmoothing = 0.06
    /// Pieces thinner than this are dropped: they would be all rim and no body.
    private static let thinnestPiece = 0.6

    var tuning = Tuning()
    private var head: SIMD2<Double>
    /// The tail: each node follows the one before it, the first follows the head.
    private var nodes: [SIMD2<Double>]
    /// One spring per number of the glyph.
    private var glyph = Glyph().values.map { Spring($0) }
    /// 1 while the glyph trails and bounces, 0 while it is a precise tool.
    private var liveliness = Spring(0)
    private var press = Spring(1)
    /// 0 when the cursor has drained away, 1 when it is there.
    private var presence = Spring(0)
    /// 1 while the pointer is aiming (moving slowly), 0 while it travels.
    private var aiming = Spring(0)
    /// 1 while the pointer is in the arrow form, 0 in the dot form; in between while switching.
    private var arrowness = Spring(0)
    private var droplets: [Droplet] = []
    /// A drop thrown out of the dot by a press.
    private struct Droplet {
        var position: SIMD2<Double>
        var velocity: SIMD2<Double>
        var age = 0.0
    }

    /// Pointer speed in points per second, smoothed over a few frames.
    private var speed = 0.0
    private var wasPressed = false

    init(at point: SIMD2<Double>) {
        head = point
        nodes = Array(repeating: point, count: Self.nodeCount)
    }

    /// True when another step with the same input would change nothing.
    var isSettled: Bool {
        glyph.allSatisfy(\.isSettled) && liveliness.isSettled && press.isSettled && aiming.isSettled
            && arrowness.isSettled
            && droplets.isEmpty
            && presence.isSettled && nodes.allSatisfy { $0 == anchor }
    }

    /// `present` false lets the cursor drain away, true brings it back.
    mutating func step(to point: SIMD2<Double>, dt: Double, context: CursorContext, pressed: Bool, present: Bool) {
        // A long pause or a huge jump is a warp (wake from sleep, another screen), not a movement to trail behind.
        let warped = dt <= 0 || dt > 0.1 || simd_distance(point, head) > 600
        let moved = warped ? 0 : simd_distance(point, head)
        head = point
        if warped {
            nodes = Array(repeating: anchor, count: Self.nodeCount)
            droplets = []
        }
        // The first frame only places the body. Slow frames still move it on, as far as a tenth of a second would:
        // if they kept coming, a body skipping them would stay frozen, or invisible after fading away.
        guard dt > 0 else {
            wasPressed = pressed
            return
        }
        let dt = min(dt, 0.1)

        let target = Glyph(for: context, form: tuning.form, dotRadius: tuning.dotRadius)
        for (index, value) in target.values.enumerated() {
            glyph[index].target = value
            glyph[index].step(dt: dt, frequency: 8, damping: tuning.damping(0.85))
        }
        liveliness.target = target.isLively ? 1 : 0
        liveliness.step(dt: dt, frequency: 6, damping: 1)

        press.target = pressed ? target.pressedScale : 1
        if pressed != wasPressed, target.isLively {
            // The press knocks the dot in well past its held size; the release throws it back out past its own.
            press.kick(pressed ? -10 : 6)
            if pressed, tuning.splashes {
                splash()
            }
        }
        wasPressed = pressed
        press.step(dt: dt, frequency: 9, damping: tuning.damping(0.6))

        let slowdown = exp(-Self.dropletDrag * dt)
        for index in droplets.indices {
            droplets[index].velocity *= slowdown
            droplets[index].position += droplets[index].velocity * dt
            droplets[index].age += dt
        }
        droplets.removeAll { $0.age >= Self.dropletLife }

        // Coming back pops in with a bounce; leaving drains away smoothly.
        presence.target = present ? 1 : 0
        if present {
            presence.step(dt: dt, frequency: 5, damping: tuning.damping(0.8))
        } else {
            presence.step(dt: dt, frequency: 2.2, damping: 1)
        }

        // Slow movement means aiming: the dot shrinks. Fast movement means travelling: it grows back.
        // Between the two, and at rest, it keeps what it was, so it does not change size under a still pointer.
        speed += (moved / dt - speed) * (1 - exp(-dt / Self.speedSmoothing))
        if !tuning.shrinksWhenAiming || !target.shrinksWhenAiming {
            aiming.target = 0
        } else if moved > 0, speed < Self.aimingSpeed {
            aiming.target = 1
        } else if speed > Self.travellingSpeed {
            aiming.target = 0
        }
        aiming.step(dt: dt, frequency: 7, damping: tuning.damping(0.85))

        arrowness.target = target.isArrow ? 1 : 0
        arrowness.step(dt: dt, frequency: 7, damping: tuning.damping(0.85))

        // Each node closes a fixed fraction of the gap to the one ahead, which strings them out behind a moving
        // head and gathers them back into it when it stops. Capping the gap caps the tail's length.
        let follow = 1 - exp(-tuning.trailResponse * dt)
        let longestGap = tuning.trailLength / Double(Self.nodeCount)
        var ahead = anchor
        for index in nodes.indices {
            var node = nodes[index] + (ahead - nodes[index]) * follow
            let gap = simd_distance(node, ahead)
            if gap > longestGap {
                node = longestGap > 0 ? ahead + (node - ahead) * (longestGap / gap) : ahead
            } else if gap < 0.02 {
                node = ahead
            }
            nodes[index] = node
            ahead = node
        }
    }

    /// Where the tail hangs from: the hot spot for the dot, the middle of the body for the arrow, whose hot spot is
    /// its tip.
    private var anchor: SIMD2<Double> {
        head + Self.arrowMiddle * (tuning.dotRadius / Glyph.designRadius) * max(arrowness.value, 0)
    }

    var shape: Shape {
        let scale = max(press.value, 0) * max(presence.value, 0)
        var current = Glyph()
        current.values = glyph.map { $0.value * scale }
        // Only the lively glyphs give liquid to their tail.
        let lively = min(max(liveliness.value, 0), 1)
        let aimed = 1 - Self.aimingShrink * min(max(aiming.value, 0), 1)
        current.core *= aimed
        current.tail *= aimed
        current.ringRadius *= aimed
        current.ringWidth *= aimed
        var shape = Shape()

        let arrow = min(max(arrowness.value, 0), 1.1)
        let tail = tailLength
        // Only a body that trails melts into its tail; a precise tool keeps its shape.
        let melt = Self.smoothstep(tail / (6 * max(current.core, 1))) * lively
        if arrow > 0.001, current.core > Self.thinnestPiece {
            shape.outline = liquidArrow(size: current.core, arrow: arrow, softness: melt)
        } else if current.core > Self.thinnestPiece {
            shape.strokes.append([Blob(center: .zero, radius: current.core)])
        }
        // Springs overshoot: a radius on its way down can dip below zero for a moment.
        for limb in current.limbs where max(limb.startRadius, limb.endRadius) > Self.thinnestPiece {
            shape.strokes.append([
                Blob(center: CGPoint(x: limb.start.x, y: limb.start.y), radius: max(limb.startRadius, 0)),
                Blob(center: CGPoint(x: limb.end.x, y: limb.end.y), radius: max(limb.endRadius, 0)),
            ])
        }
        if current.ringWidth > Self.thinnestPiece {
            shape.rings.append(Ring(center: CGPoint(x: current.ringCenter.x, y: current.ringCenter.y),
                                    radius: max(current.ringRadius, 0), width: current.ringWidth))
        }

        // The arrow's body is narrow: its tail starts thin enough to stay inside it, and thickens as the arrow
        // melts rounder. A short tail would only poke out of its edges like a fin, so it grows in gradually over a
        // long stretch of lengths: a sharp threshold would make it flicker on and off at speeds around it.
        let emerging = Self.smoothstep((tail - 1.5 * current.tail) / (6 * max(current.tail, 1)))
        let arrowTail = (0.42 + 0.3 * melt) * emerging
        let thickest = current.tail * (0.9 + (arrowTail - 0.9) * min(arrow, 1)) * lively
        if thickest > Self.thinnestPiece, nodes.last != anchor {
            // A smooth curve through the anchor and the nodes, sampled finely enough to look continuous.
            let points = [anchor] + nodes
            let subdivisions = 3
            var trail: [Blob] = []
            for segment in 0..<(points.count - 1) {
                let p0 = points[max(segment - 1, 0)]
                let p1 = points[segment]
                let p2 = points[segment + 1]
                let p3 = points[min(segment + 2, points.count - 1)]
                for step in 0..<subdivisions {
                    let t = Double(step) / Double(subdivisions)
                    let along = (Double(segment) + t) / Double(points.count - 1)
                    let radius = thickest * pow(1 - along, 1.5)
                    guard radius > Self.thinnestPiece else { break }
                    trail.append(Blob(center: relative(catmullRom(p0, p1, p2, p3, t)), radius: radius))
                }
            }
            shape.strokes.append(trail)
        }
        // The drops shrink as they fly, and are gone by the end of their short life.
        for droplet in droplets {
            let life = droplet.age / Self.dropletLife
            let radius = tuning.dotRadius * 0.34 * (1 - life * life)
            if radius > Self.thinnestPiece {
                shape.splash.append([Blob(center: relative(droplet.position), radius: radius)])
            }
        }
        return shape
    }

    /// Throws drops out of the dot, spread around it with a little randomness.
    private mutating func splash() {
        let turn = 2 * Double.pi
        let phase = Double.random(in: 0..<turn)
        let size = tuning.dotRadius / Glyph.designRadius
        for index in 0..<Self.dropletCount {
            let angle = phase + turn * (Double(index) + Double.random(in: -0.25...0.25)) / Double(Self.dropletCount)
            let speed = Double.random(in: 200...320) * size
            droplets.append(Droplet(position: head, velocity: SIMD2(cos(angle), sin(angle)) * speed))
        }
    }

    /// How far the tail reaches along its nodes, in points.
    private var tailLength: Double {
        var length = 0.0
        var ahead = anchor
        for node in nodes {
            length += simd_distance(node, ahead)
            ahead = node
        }
        return length
    }

    /// 0 below 0, 1 above 1, and a smooth S in between.
    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The arrow as a liquid: melting softer and rounder (never fully round) while its tail is out, the more the
    /// longer the tail (`softness`, 0 to 1), gathering into its shape again as the tail flows back. `arrow` blends with
    /// the plain dot while switching forms.
    private func liquidArrow(size: Double, arrow: Double, softness: Double) -> [CGPoint] {
        let scale = size / Glyph.designRadius
        let roundness = Self.arrowMelt * softness
        let shrink = 1 - 0.15 * softness
        let middle = Self.arrowMiddle * scale
        return Self.arrowOutline.map { sample in
            let pointed = SIMD2(Double(sample.arrow.x), Double(sample.arrow.y)) * scale
            let unit = SIMD2(Double(sample.circle.x), Double(sample.circle.y))
            let rounded = middle + unit * Self.arrowDropRadius * scale
            let liquid = middle + (pointed + (rounded - pointed) * roundness - middle) * shrink
            let dot = unit * size
            let point = dot + (liquid - dot) * arrow
            return CGPoint(x: point.x, y: point.y)
        }
    }

    /// How round the arrow gets at most while it moves, from 0 (stays an arrow) to 1 (becomes a drop).
    private static let arrowMelt = 0.55
    /// Radius of the drop the arrow would melt into, at the design radius.
    private static let arrowDropRadius = 5.0

    /// The arrow, at the design radius, as evenly spaced points from its tip going counter-clockwise, each with
    /// its partner on a unit circle, at the same share of the way round. The tip sits on the hot spot.
    private static let arrowOutline: [(arrow: CGPoint, circle: CGPoint)] = {
        var points = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -16), CGPoint(x: 4.4, y: -12), CGPoint(x: 11.5, y: -11.5)]
        // Corner cutting with small cuts: every corner, the tip included, gets just rounded and the edges stay
        // straight, so it still reads as an arrow.
        let cut = 0.1
        for _ in 0..<3 {
            var smoother: [CGPoint] = []
            for (index, point) in points.enumerated() {
                let next = points[(index + 1) % points.count]
                smoother.append(CGPoint(x: point.x * (1 - cut) + next.x * cut, y: point.y * (1 - cut) + next.y * cut))
                smoother.append(CGPoint(x: point.x * cut + next.x * (1 - cut), y: point.y * cut + next.y * (1 - cut)))
            }
            points = smoother
        }
        // Rounding pulls the tip in; move the whole arrow back so its tip is on the hot spot again.
        let tip = points.min { $0.x - $0.y < $1.x - $1.y }!
        points = points.map { CGPoint(x: $0.x - tip.x, y: $0.y - tip.y) }
        let start = points.firstIndex(of: .zero)!
        points = Array(points[start...] + points[..<start]) + [CGPoint.zero]

        // Evenly spaced along the outline, so blends with a circle stay even all the way round.
        var lengths = [0.0]
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x,
                                                      points[index].y - points[index - 1].y))
        }
        let total = lengths.last!
        let count = 72
        var segment = 1
        return (0..<count).map { sample in
            let distance = total * Double(sample) / Double(count)
            while lengths[segment] < distance { segment += 1 }
            let t = (distance - lengths[segment - 1]) / max(lengths[segment] - lengths[segment - 1], 1e-9)
            let a = points[segment - 1], b = points[segment]
            // The circle starts on the side facing the tip, so the shapes turn into each other without twisting.
            let angle = 0.67 * Double.pi + 2 * Double.pi * Double(sample) / Double(count)
            return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), CGPoint(x: cos(angle), y: sin(angle)))
        }
    }()

    /// The middle of the arrow's body, at the design radius.
    private static let arrowMiddle: SIMD2<Double> = {
        let points = arrowOutline.map { SIMD2(Double($0.arrow.x), Double($0.arrow.y)) }
        return points.reduce(.zero, +) / Double(points.count)
    }()

    private func relative(_ point: SIMD2<Double>) -> CGPoint {
        CGPoint(x: point.x - head.x, y: point.y - head.y)
    }

    private func catmullRom(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>,
                            _ t: Double) -> SIMD2<Double> {
        let t2 = t * t
        let t3 = t2 * t
        // One term at a time: written as a single expression, older Swift compilers give up type-checking it.
        let linear: SIMD2<Double> = (p2 - p0) * t
        let bend: SIMD2<Double> = 2 * p0 - 5 * p1
        let quadratic: SIMD2<Double> = (bend + 4 * p2 - p3) * t2
        let cubic: SIMD2<Double> = (3 * p1 - p0 - 3 * p2 + p3) * t3
        let sum: SIMD2<Double> = 2 * p1 + linear + quadratic + cubic
        return 0.5 * sum
    }
}

extension LiquidBody.Shape {
    /// The outline of the whole body, grown outward by `margin`.
    ///
    /// The body is the union of simple pieces: a circle per blob, a quadrilateral bridging each pair of
    /// neighboring blobs in a stroke, and the rings. Every piece is wound the same way, so with the non-zero fill
    /// rule overlapping pieces merge into one shape instead of cutting holes in each other.
    func path(grownBy margin: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if outline.count > 2 {
            // Each point moves out along the outline's outward normal, which for a counter-clockwise outline is the
            // tangent turned a quarter clockwise.
            let count = outline.count
            let grown = outline.indices.map { index -> CGPoint in
                let previous = outline[(index + count - 1) % count]
                let next = outline[(index + 1) % count]
                let dx = next.x - previous.x
                let dy = next.y - previous.y
                let length = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                return CGPoint(x: outline[index].x + dy / length * margin, y: outline[index].y - dx / length * margin)
            }
            path.addLines(between: grown)
            path.closeSubpath()
        }
        for stroke in strokes {
            for (index, blob) in stroke.enumerated() {
                addCircle(at: blob.center, radius: blob.radius + margin, to: path)
                if index > 0 {
                    addBridge(from: stroke[index - 1], to: blob, grownBy: margin, to: path)
                }
            }
        }
        for ring in rings {
            addCircle(at: ring.center, radius: ring.radius + ring.width / 2 + margin, to: path)
            let hole = ring.radius - ring.width / 2 - margin
            if hole > 0 {
                // Wound the opposite way, this circle cancels the outer one inside it.
                path.move(to: CGPoint(x: ring.center.x + hole, y: ring.center.y))
                path.addArc(center: ring.center, radius: hole, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
                path.closeSubpath()
            }
        }
        return path
    }

    private func addCircle(at center: CGPoint, radius: CGFloat, to path: CGMutablePath) {
        path.move(to: CGPoint(x: center.x + radius, y: center.y))
        path.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        path.closeSubpath()
    }

    private func addBridge(from a: LiquidBody.Blob, to b: LiquidBody.Blob, grownBy margin: CGFloat,
                           to path: CGMutablePath) {
        let dx = b.center.x - a.center.x
        let dy = b.center.y - a.center.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.05 else { return }
        // Unit normal to the left of the direction of travel. Going out along the right side and back along the
        // left winds the same way as the circles.
        let nx = -dy / length
        let ny = dx / length
        let ra = a.radius + margin
        let rb = b.radius + margin
        path.move(to: CGPoint(x: a.center.x - nx * ra, y: a.center.y - ny * ra))
        path.addLine(to: CGPoint(x: b.center.x - nx * rb, y: b.center.y - ny * rb))
        path.addLine(to: CGPoint(x: b.center.x + nx * rb, y: b.center.y + ny * rb))
        path.addLine(to: CGPoint(x: a.center.x + nx * ra, y: a.center.y + ny * ra))
        path.closeSubpath()
    }
}
