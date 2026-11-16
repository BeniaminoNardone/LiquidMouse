import CoreGraphics

/// The app's mark, drawn by the app icon and the menu bar icon: a drop shaped like a cursor's tip, its left side
/// straight down, its right side at 45 degrees, its far end round. A cursor made of liquid.
enum Drop {
    /// The outline from the tip, at the origin, with y pointing down. `radius` is the round end's; `steps` how finely
    /// the round end is drawn.
    static func outline(radius: CGFloat, steps: Int) -> [CGPoint] {
        let half = CGFloat.pi / 8
        let reach = radius / sin(half)
        // The axis leans from the vertical by half the tip's angle, which makes the left side vertical.
        let center = CGPoint(x: reach * sin(half), y: reach * cos(half))
        // The sides run from the tip to where they touch the circle, then round its far side.
        let touch = acos(radius / reach)
        let back = atan2(-center.y, -center.x)
        return [.zero] + (0...steps).map { step in
            let angle = back + touch + (2 * .pi - 2 * touch) * CGFloat(step) / CGFloat(steps)
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }
}
