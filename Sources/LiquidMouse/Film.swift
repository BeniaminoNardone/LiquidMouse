import AppKit

/// The launch film, drawn with the app's own code and its default settings: black ink on warm paper. The classic
/// arrow melts into the liquid one, which comes to rest at the end of the title, then shows what it does: it moves
/// like liquid, takes the shape of what you do, splashes when you click, turns into a dot and back, and steps aside
/// while you type. The arrow is the protagonist; the dot only shows as the other form. Every scene is said in plain
/// words while it happens, and nothing is sped up or slowed down.
///
/// `--film [it]` writes the frames to standard output as raw RGBA, 1920 × 1080, 60 a second, in English or Italian.
/// `--film gif` writes the English ones as the README's animation needs them: 50 a second, the fastest a GIF plays;
/// on plain paper, since a GIF cannot afford grain or shading; and without the end card, so that it ends on the bare
/// paper it can start again from. Scripts/make-film.sh turns the frames into the videos and the GIF.
enum Film {
    static let size = CGSize(width: 1920, height: 1080)

    // MARK: - The script

    /// A point the pointer passes through at a moment of the film, in world points. It only comes to rest where it
    /// `stops`; elsewhere it flows through, so that a gesture is one continuous movement.
    private struct Key {
        let time: Double
        let point: CGPoint
        var stops = false
    }

    private enum Draggable { case divider, photo }

    /// Everything the film says, or shows written, in one language.
    struct Words {
        var opening = ["For forty years,", "the cursor has barely changed."]
        var untilNow = "Until now."
        var tagline = "A liquid cursor for the Mac"
        var liquid = "It moves like liquid."
        var text = "Over text, it becomes a bar."
        var link = "Over a link, it gets smaller."
        var edge = "On an edge, it shows which way it moves."
        var grab = "To grab, it becomes a ring."
        var click = "Every click makes a splash."
        var dot = "Or a dot, if you prefer."
        var typing = "It steps aside while you type."
        var free = "Free and open source"
        var notes = "Notes"
        var notesLines = ["The pointer has barely changed", "since the first Macintosh. This one",
                          "is a drop of liquid: it stretches", "as it moves, and takes a new shape."]
        var story = "Read the full story"
        var continueLabel = "Continue"
        var get = "Get LiquidMouse"
        var typed = "Hello, liquid cursor."

        static let english = Words()
        static let italian = Words(
            opening: ["Da quarant'anni", "il cursore è cambiato appena."], untilNow: "Fino a oggi.",
            tagline: "Un cursore liquido per il Mac", liquid: "Si muove come un liquido.",
            text: "Sul testo diventa una barra.", link: "Su un link diventa più piccolo.",
            edge: "Su un bordo mostra da che parte si sposta.", grab: "Per afferrare diventa un anello.",
            click: "Ogni clic fa uno schizzo.", dot: "Oppure un punto, se preferisci.",
            typing: "Si fa da parte mentre scrivi.", free: "Gratis e open source", notes: "Note",
            notesLines: ["Il puntatore è cambiato appena", "dal primo Macintosh. Questo è",
                         "una goccia di liquido: si allunga", "quando si muove e cambia forma."],
            story: "Leggi la storia", continueLabel: "Continua", get: "Scarica LiquidMouse",
            typed: "Ciao, cursore liquido.")
    }

    /// The language being drawn.
    private static var words = Words.english

    /// Things in the world, in points, y down. The cursor is 13 points wide there, as on a screen.
    private static let titleFont = NSFont.systemFont(ofSize: 64, weight: .bold)
    private static let title = "LiquidMouse"
    private static let titleSize = NSAttributedString(string: title, attributes: titleAttributes).size()
    private static let titleOrigin = CGPoint(x: -titleSize.width / 2 - 14, y: -60 - titleSize.height / 2)
    private static let titleBaseline = titleOrigin.y + titleFont.ascender
    /// Where the arrow comes to rest: at the end of the title, as at the end of a line being written.
    private static let titleEnd = CGPoint(x: titleOrigin.x + titleSize.width + 12,
                                          y: titleBaseline - titleFont.capHeight * 0.6)
    private static let loops = CGPoint(x: titleEnd.x - 130, y: titleEnd.y + 40)

    private static let notesCard = CGRect(x: -470, y: -200, width: 380, height: 200)
    private static let linkCard = CGRect(x: -50, y: -200, width: 380, height: 200)
    private static let splitCard = CGRect(x: -470, y: 40, width: 380, height: 200)
    private static let photoCard = CGRect(x: -50, y: 40, width: 380, height: 200)
    private static let notesText = CGRect(x: -446, y: -142, width: 330, height: 112)
    private static let link = CGRect(x: -26, y: -158, width: 168, height: 26)
    private static let continueButton = CGRect(x: -26, y: -104, width: 132, height: 44)
    private static let divider = -280.0
    private static let button = CGRect(x: 130, y: 28, width: 280, height: 64)
    private static let field = CGRect(x: 40, y: -12, width: 520, height: 64)

    // Places the pointer goes to.
    private static let lineStart = CGPoint(x: -430, y: -118), lineEnd = CGPoint(x: -205, y: -104)
    private static let linkSpot = CGPoint(x: 40, y: -146)
    private static let dividerSpot = CGPoint(x: divider, y: 140), dragged = CGPoint(x: divider + 46, y: 140)
    private static let photoSpot = CGPoint(x: 130, y: 145), photoDropped = CGPoint(x: 200, y: 178)
    private static let click = CGPoint(x: button.midX + 28, y: button.midY + 9)
    private static let click2 = CGPoint(x: button.midX - 34, y: button.midY + 4)
    private static let forms = CGPoint(x: 300, y: 110), formsEnd = CGPoint(x: 315, y: 125)
    private static let resting = CGPoint(x: 450, y: 112), back = CGPoint(x: 392, y: 130)

    private static let path: [Key] = {
        func at(_ base: CGPoint, _ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
        return [
            // Forty years of the same arrow; then it melts into liquid and runs off.
            Key(time: 0, point: .zero, stops: true), Key(time: 2.6, point: .zero, stops: true),
            Key(time: 3.05, point: CGPoint(x: 95, y: 42)), Key(time: 3.55, point: CGPoint(x: 200, y: -15)),
            // To the end of the title.
            Key(time: 4.15, point: at(titleEnd, 210, -170)), Key(time: 4.75, point: titleEnd, stops: true),
            Key(time: 6.3, point: titleEnd, stops: true),
            // It moves like liquid: one long figure of eight.
            Key(time: 6.65, point: at(loops, 160, -70)), Key(time: 7.05, point: at(loops, 10, 70)),
            Key(time: 7.45, point: at(loops, -180, -50)), Key(time: 7.85, point: at(loops, -30, 85)),
            Key(time: 8.25, point: at(loops, 150, 35)), Key(time: 8.7, point: at(loops, 60, -30), stops: true),
            Key(time: 8.95, point: at(loops, 60, -30), stops: true),
            // It takes the shape of what you are doing: text, a link, a divider, a photo to drag. Each long enough
            // to read what it says.
            Key(time: 9.35, point: CGPoint(x: -150, y: -230)), Key(time: 9.7, point: lineStart),
            Key(time: 10.9, point: lineEnd, stops: true), Key(time: 11.4, point: linkSpot, stops: true),
            Key(time: 12.2, point: linkSpot, stops: true), Key(time: 12.7, point: dividerSpot, stops: true),
            Key(time: 13.0, point: dividerSpot, stops: true), Key(time: 13.55, point: dragged, stops: true),
            Key(time: 13.9, point: dragged, stops: true), Key(time: 14.4, point: photoSpot, stops: true),
            Key(time: 14.7, point: photoSpot, stops: true), Key(time: 15.5, point: photoDropped, stops: true),
            Key(time: 16.0, point: photoDropped, stops: true),
            // Every click makes a splash.
            Key(time: 16.45, point: CGPoint(x: 300, y: 140)), Key(time: 16.75, point: click, stops: true),
            Key(time: 17.2, point: click, stops: true), Key(time: 17.5, point: click2, stops: true),
            Key(time: 18.5, point: click2, stops: true),
            // Or a dot.
            Key(time: 18.9, point: forms, stops: true), Key(time: 19.25, point: forms, stops: true),
            Key(time: 19.6, point: at(forms, 130, -60)), Key(time: 19.95, point: at(forms, -90, -50)),
            Key(time: 20.3, point: formsEnd, stops: true), Key(time: 20.9, point: formsEnd, stops: true),
            // It steps aside while you type, and is back at the first movement.
            Key(time: 21.3, point: resting, stops: true), Key(time: 22.55, point: resting, stops: true),
            Key(time: 22.9, point: back, stops: true), Key(time: 25.9, point: back, stops: true),
        ]
    }()

    private static let presses: [ClosedRange<Double>] = [12.95...13.6, 14.65...15.55, 17.05...17.17, 17.65...17.77]
    private static let drags: [(span: ClosedRange<Double>, what: Draggable)] = [
        (13.0...13.55, .divider), (14.7...15.5, .photo),
    ]
    /// The arrow throughout, but for the scene that shows the other form.
    private static func form(at time: Double) -> CursorForm { (19.0..<20.2).contains(time) ? .dot : .arrow }
    private static let hidden: [ClosedRange<Double>] = [21.45...22.55, 23.05...99]
    private static let typingStarts = 21.45
    private static let typingPace = 0.04

    /// Where the camera looks, how close, and how much it leans towards the pointer, over film time. It follows
    /// these on a spring, so it never stops dead between two of them.
    private static let camera: [(time: Double, x: Double, y: Double, zoom: Double, follow: Double)] = [
        (0, 5 - 600 / 10, 8, 10, 0), (2.6, 5 - 600 / 10.6, 8, 10.6, 0), (3.6, 140, 0, 5, 0),
        (4.2, 10, -40, 1.75, 0), (6.2, 10, -40, 1.8, 0), (6.5, loops.x, loops.y, 6.5, 0.7),
        (8.8, loops.x, loops.y, 6.8, 0.7), (9.1, -70, -40, 1.95, 0), (16.0, -70, -40, 2.0, 0),
        (16.4, click.x, click.y, 6, 0.2), (18.4, click.x, click.y, 6.2, 0.2), (18.8, forms.x, forms.y, 5.2, 0.3),
        (20.7, forms.x, forms.y, 5.4, 0.3), (21.1, 320, 50, 2.4, 0), (22.9, 320, 50, 2.45, 0),
        (25.9, 320, 50, 2.5, 0),
    ]

    private struct Caption {
        let text: String
        let start: Double, end: Double
        let at: CGPoint
        let size: CGFloat
    }

    private static var captions: [Caption] {
        let top = CGPoint(x: 140, y: 96)
        return [
            Caption(text: words.opening[0], start: 0.2, end: 2.45, at: CGPoint(x: 180, y: 380), size: 84),
            Caption(text: words.opening[1], start: 0.45, end: 2.45, at: CGPoint(x: 180, y: 486), size: 84),
            Caption(text: words.untilNow, start: 2.7, end: 3.95, at: CGPoint(x: 180, y: 452), size: 112),
            Caption(text: words.liquid, start: 6.35, end: 8.85, at: top, size: 56),
            Caption(text: words.text, start: 9.5, end: 10.95, at: top, size: 56),
            Caption(text: words.link, start: 11.15, end: 12.3, at: top, size: 56),
            Caption(text: words.edge, start: 12.55, end: 13.95, at: top, size: 56),
            Caption(text: words.grab, start: 14.25, end: 15.95, at: top, size: 56),
            Caption(text: words.click, start: 16.3, end: 18.55, at: top, size: 56),
            Caption(text: words.dot, start: 18.75, end: 20.85, at: top, size: 56),
            Caption(text: words.typing, start: 21.0, end: 22.95, at: top, size: 56),
        ]
    }

    // MARK: - Rendering

    static func render(language: Words = .english, forGIF: Bool = false) {
        words = language
        let framesPerSecond = forGIF ? 50.0 : 60.0
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let paper = drawPaper(width: width, height: height, plain: forGIF)
        else { return }
        let grain = forGIF ? nil : makeGrain()
        // Laid out from the top-left corner, y down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = nil }

        let end = path.last!.time
        var body = LiquidBody(at: .zero)
        var lens = Lens(target: cameraTarget(at: 0, pointer: .zero))
        var time = 0.0
        var first = true
        var generator = SystemRandomNumberGenerator()
        while time < end {
            let point = pointer(at: time)
            let pressed = presses.contains { $0.contains(time) }
            let scene = Scene(time: time, dividerOffset: dragOffset(.divider, at: time).width,
                              photoOffset: dragOffset(.photo, at: time))
            let step = 1 / framesPerSecond
            var tuning = LiquidBody.Tuning()
            tuning.form = form(at: time)
            body.tuning = tuning
            // The body's own coordinates have y up.
            body.step(to: SIMD2(Double(point.x), Double(-point.y)), dt: first ? 0 : step,
                      context: scene.cursor(at: point, pressed: pressed), pressed: pressed,
                      present: !hidden.contains { $0.contains(time) })
            first = false
            lens.follow(cameraTarget(at: time, pointer: point), over: 1 / framesPerSecond)

            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(paper, in: CGRect(origin: .zero, size: size))
            context.restoreGState()

            context.saveGState()
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: lens.zoom, y: lens.zoom)
            context.translateBy(x: -lens.center.x, y: -lens.center.y)
            scene.drawWorld(in: context, pressed: pressed)
            if time < 2.6 {
                // The system's own arrow, fading into ours.
                let image = NSCursor.arrow.image
                let fade = time < 2.25 ? 1 : 1 - ease((time - 2.25) / 0.35)
                image.draw(in: CGRect(x: -NSCursor.arrow.hotSpot.x, y: -NSCursor.arrow.hotSpot.y,
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: fade, respectFlipped: true, hints: nil)
            }
            if time > 2.25 {
                context.setAlpha(ease((time - 2.25) / 0.35))
                Gallery.drawBody(body.shape, look: .dark, hotSpot: point, in: context, pixelsPerPoint: lens.zoom)
                context.setAlpha(1)
            }
            context.restoreGState()

            for caption in captions {
                draw(caption, at: time)
            }
            if !forGIF {
                drawEndCard(at: time, in: context)
            }
            if let grain {
                let offset = CGPoint(x: -Double.random(in: 0..<256, using: &generator),
                                     y: -Double.random(in: 0..<256, using: &generator))
                context.saveGState()
                // Overlaid, so that it neither lightens nor darkens the paper on the whole.
                context.setBlendMode(.overlay)
                context.setAlpha(0.07)
                context.draw(grain, in: CGRect(origin: offset, size: CGSize(width: 256, height: 256)), byTiling: true)
                context.restoreGState()
            }

            guard let data = context.data else { return }
            FileHandle.standardOutput.write(Data(bytes: data, count: width * height * 4))
            time += step
        }
    }

    /// What the world holds at a moment of the film, and what cursor an app would show over it.
    private struct Scene {
        let time: Double
        let dividerOffset: Double
        let photoOffset: CGSize

        var cardsShown: Double { window(time, 8.95, 16.2) }
        var buttonShown: Double { window(time, 16.2, 18.7) }
        var fieldShown: Double { window(time, 20.9, 23.05) }
        var dividerX: Double { divider + dividerOffset }
        var photo: CGRect { photoCard.offsetBy(dx: photoOffset.width, dy: photoOffset.height) }

        func cursor(at point: CGPoint, pressed: Bool) -> CursorContext {
            if cardsShown > 0.5 {
                if notesText.contains(point) { return .text(halfHeight: 9) }
                if link.contains(point) || continueButton.contains(point) { return .link }
                if abs(point.x - dividerX) < 6, splitCard.insetBy(dx: 0, dy: 8).contains(point) {
                    return .resize(direction: CGVector(dx: 1, dy: 0), bothWays: true, divider: true)
                }
                if photo.insetBy(dx: 20, dy: 20).contains(point) { return pressed ? .grabbing : .grab }
            }
            if buttonShown > 0.5, button.contains(point) { return .link }
            return .pointer
        }

        func drawWorld(in context: CGContext, pressed: Bool) {
            drawTitle(in: context)
            if cardsShown > 0 {
                context.saveGState()
                context.setAlpha(cardsShown)
                drawCards(in: context)
                context.restoreGState()
            }
            if buttonShown > 0 {
                context.saveGState()
                context.setAlpha(buttonShown)
                drawButton(in: context)
                context.restoreGState()
            }
            if fieldShown > 0 {
                context.saveGState()
                context.setAlpha(fieldShown)
                drawField(in: context)
                context.restoreGState()
            }
        }

        private func drawTitle(in context: CGContext) {
            let leaving = time > 6.0 ? 1 - ease((time - 6.0) / 0.35) : 1
            guard time > 3.9, leaving > 0 else { return }
            var x = titleOrigin.x
            for (index, letter) in title.enumerated() {
                let appear = ease((time - 4.0 - 0.03 * Double(index)) / 0.45)
                let string = String(letter)
                let width = NSAttributedString(string: string, attributes: titleAttributes).size().width
                if appear > 0 {
                    var attributes = titleAttributes
                    attributes[.foregroundColor] = ink.withAlphaComponent(appear * leaving)
                    (string as NSString).draw(at: CGPoint(x: x, y: titleOrigin.y + 14 * (1 - appear)),
                                              withAttributes: attributes)
                }
                x += width
            }
            let tagline = ease((time - 4.55) / 0.45) * leaving
            if tagline > 0 {
                text(words.tagline + ".", at: CGPoint(x: titleOrigin.x + 2, y: titleBaseline + 22),
                     font: .systemFont(ofSize: 22), color: NSColor(white: 0.36, alpha: tagline))
            }
        }

        private func drawCards(in context: CGContext) {
            for card in [notesCard, linkCard, splitCard] {
                drawCard(card, in: context)
            }
            text(words.notes, at: CGPoint(x: notesCard.minX + 24, y: notesCard.minY + 22),
                 font: .systemFont(ofSize: 20, weight: .semibold), color: ink)
            let lines = words.notesLines
            for (index, line) in lines.enumerated() {
                text(line, at: CGPoint(x: notesText.minX, y: notesText.minY + 2 + 27 * CGFloat(index)),
                     font: .systemFont(ofSize: 17), color: NSColor(white: 0.33, alpha: 1))
            }
            text(words.story, at: CGPoint(x: link.minX, y: link.minY + 1), font: .systemFont(ofSize: 19),
                 color: ink, underlined: true)
            context.addPath(CGPath(roundedRect: continueButton, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.setFillColor(ink.cgColor)
            context.fillPath()
            let label = NSFont.systemFont(ofSize: 16, weight: .semibold)
            let labelWidth = NSAttributedString(string: words.continueLabel, attributes: [.font: label]).size().width
            text(words.continueLabel, at: CGPoint(x: continueButton.midX - labelWidth / 2, y: continueButton.minY + 12),
                 font: label, color: .white)
            // A split view: the divider between its panes can be dragged.
            context.saveGState()
            context.addPath(CGPath(roundedRect: splitCard, cornerWidth: 20, cornerHeight: 20, transform: nil))
            context.clip()
            context.setFillColor(CGColor(gray: 0.955, alpha: 1))
            context.fill(CGRect(x: splitCard.minX, y: splitCard.minY, width: dividerX - splitCard.minX,
                                height: splitCard.height))
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            context.fill(CGRect(x: dividerX - 0.5, y: splitCard.minY, width: 1, height: splitCard.height))
            for (index, widthShare) in [0.7, 0.5, 0.62].enumerated() {
                let left = CGRect(x: splitCard.minX + 22, y: splitCard.minY + 30 + 34 * CGFloat(index),
                                  width: (dividerX - splitCard.minX - 44) * widthShare, height: 12)
                context.addPath(CGPath(roundedRect: left, cornerWidth: 6, cornerHeight: 6, transform: nil))
                let right = CGRect(x: dividerX + 22, y: splitCard.minY + 30 + 34 * CGFloat(index),
                                   width: (splitCard.maxX - dividerX - 44) * widthShare, height: 12)
                context.addPath(CGPath(roundedRect: right, cornerWidth: 6, cornerHeight: 6, transform: nil))
            }
            context.setFillColor(CGColor(gray: 0.86, alpha: 1))
            context.fillPath()
            context.restoreGState()
            drawPhotoCard(in: context)
        }

        /// A card holding a photograph, in shades of gray: a pale sun over dark hills.
        private func drawPhotoCard(in context: CGContext) {
            drawCard(photo, in: context)
            let picture = photo.insetBy(dx: 16, dy: 16)
            context.saveGState()
            context.addPath(CGPath(roundedRect: picture, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.clip()
            let sky = [CGColor(gray: 0.72, alpha: 1), CGColor(gray: 0.9, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sky,
                                         locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: picture.minY),
                                           end: CGPoint(x: 0, y: picture.maxY), options: [])
            }
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fillEllipse(in: CGRect(x: picture.midX + 40, y: picture.minY + 26, width: 46, height: 46))
            let hills = CGMutablePath()
            hills.move(to: CGPoint(x: picture.minX, y: picture.maxY))
            hills.addLine(to: CGPoint(x: picture.minX, y: picture.minY + 110))
            hills.addCurve(to: CGPoint(x: picture.midX, y: picture.minY + 96),
                           control1: CGPoint(x: picture.minX + 70, y: picture.minY + 60),
                           control2: CGPoint(x: picture.midX - 60, y: picture.minY + 70))
            hills.addCurve(to: CGPoint(x: picture.maxX, y: picture.minY + 104),
                           control1: CGPoint(x: picture.midX + 70, y: picture.minY + 120),
                           control2: CGPoint(x: picture.maxX - 60, y: picture.minY + 80))
            hills.addLine(to: CGPoint(x: picture.maxX, y: picture.maxY))
            hills.closeSubpath()
            context.addPath(hills)
            context.setFillColor(CGColor(gray: 0.28, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        private func drawButton(in context: CGContext) {
            drawCard(button, radius: button.height / 2, in: context)
            let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
            let width = NSAttributedString(string: words.get, attributes: [.font: font]).size().width
            text(words.get, at: CGPoint(x: button.midX - width / 2, y: button.midY - font.pointSize * 0.62),
                 font: font, color: ink)
        }

        private func drawField(in context: CGContext) {
            drawCard(field, radius: 16, in: context)
            let count = max(0, min(words.typed.count, Int((time - typingStarts) / typingPace)))
            let shown = String(words.typed.prefix(count))
            let font = NSFont.systemFont(ofSize: 24)
            text(shown, at: CGPoint(x: field.minX + 24, y: field.minY + 17), font: font, color: ink)
            let width = NSAttributedString(string: shown, attributes: [.font: font]).size().width
            // The caret blinks while nothing is typed.
            let typing = time > typingStarts && time < typingStarts + typingPace * Double(words.typed.count) + 0.1
            if typing || Int(time * 2.2) % 2 == 0 {
                context.setFillColor(ink.cgColor)
                context.fill(CGRect(x: field.minX + 25 + width, y: field.minY + 16, width: 2, height: 32))
            }
        }

        private func drawCard(_ rect: CGRect, radius: CGFloat = 20, in context: CGContext) {
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -12), blur: 46, color: CGColor(gray: 0, alpha: 0.09))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    // MARK: - Pieces

    private static let ink = NSColor(white: 0.07, alpha: 1)
    private static var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: titleFont, .foregroundColor: ink, .kern: -1.8]
    }

    private static func draw(_ caption: Caption, at time: Double) {
        let appear = ease((time - caption.start) / 0.35)
        let leave = time > caption.end - 0.3 ? 1 - ease((time - caption.end + 0.3) / 0.3) : 1
        let alpha = appear * leave
        guard alpha > 0 else { return }
        let weight: NSFont.Weight = caption.size > 80 ? .bold : caption.size > 40 ? .semibold : .regular
        let color = caption.size > 40 ? ink : NSColor(white: 0.4, alpha: 1)
        text(caption.text, at: CGPoint(x: caption.at.x, y: caption.at.y + 16 * (1 - appear)),
             font: .systemFont(ofSize: caption.size, weight: weight), color: color.withAlphaComponent(alpha),
             kern: -caption.size * 0.025)
    }

    /// The icon, the name and where to find it.
    private static func drawEndCard(at time: Double, in context: CGContext) {
        guard time > 23.1 else { return }
        let icon = overshoot((time - 23.15) / 0.6)
        if icon > 0 {
            let side = 230 * (0.8 + 0.2 * icon)
            let tile = CGRect(x: size.width / 2 - side / 2, y: 300 - side / 2 + 40, width: side, height: side)
            context.saveGState()
            context.setAlpha(min(1, icon))
            context.setShadow(offset: CGSize(width: 0, height: -16), blur: 50, color: CGColor(gray: 0, alpha: 0.16))
            context.addPath(CGPath(roundedRect: tile, cornerWidth: side * 0.225, cornerHeight: side * 0.225,
                                   transform: nil))
            context.setFillColor(CGColor(gray: 0.985, alpha: 1))
            context.fillPath()
            context.restoreGState()
            let drop = Drop.outline(radius: side * 0.16, steps: 120)
            let box = drop.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            let offset = CGPoint(x: tile.midX - box.midX - side * 0.01, y: tile.midY - box.midY + side * 0.01)
            let path = CGMutablePath()
            path.addLines(between: drop.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) })
            path.closeSubpath()
            context.saveGState()
            context.setAlpha(min(1, icon))
            context.addPath(path)
            context.setFillColor(ink.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        let name = ease((time - 23.4) / 0.45)
        if name > 0 {
            centered("LiquidMouse", y: 560 + 16 * (1 - name), font: .systemFont(ofSize: 76, weight: .bold),
                     color: ink.withAlphaComponent(name), kern: -2)
        }
        let line = ease((time - 23.6) / 0.45)
        if line > 0 {
            centered(words.tagline, y: 662, font: .systemFont(ofSize: 32),
                     color: NSColor(white: 0.36, alpha: line))
        }
        let footer = ease((time - 23.8) / 0.45)
        if footer > 0 {
            centered(words.free + "  ·  github.com/BeniaminoNardone/LiquidMouse", y: 750,
                     font: .systemFont(ofSize: 24), color: NSColor(white: 0.45, alpha: footer))
        }
    }

    private static func centered(_ string: String, y: CGFloat, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        let width = NSAttributedString(string: string, attributes: [.font: font, .kern: kern]).size().width
        text(string, at: CGPoint(x: size.width / 2 - width / 2, y: y), font: font, color: color, kern: kern)
    }

    private static func text(_ string: String, at point: CGPoint, font: NSFont, color: NSColor, kern: CGFloat = 0,
                             underlined: Bool = false) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        if underlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        (string as NSString).draw(at: point, withAttributes: attributes)
    }

    /// Warm paper, a little lighter at the top left, darker towards the corners. `plain` paper is its middle shade
    /// all over.
    private static func drawPaper(width: Int, height: Int, plain: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if plain {
            context.setFillColor(CGColor(red: 0.954, green: 0.945, blue: 0.927, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let wash = [CGColor(red: 0.975, green: 0.968, blue: 0.952, alpha: 1),
                    CGColor(red: 0.932, green: 0.922, blue: 0.902, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: wash, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)),
                                       end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        let vignette = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.07)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: vignette, locations: [0.55, 1]) {
            let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(width) * 0.62, options: [.drawsAfterEndLocation])
        }
        return context.makeImage()
    }

    /// A tile of fine noise, laid over every frame at a different place, like film grain.
    private static func makeGrain() -> CGImage? {
        let side = 256
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0..<(side * side) {
            let shade = UInt8.random(in: 0...255, using: &generator)
            // Premultiplied: a gray that is as opaque as it is dark or light, so it both lightens and darkens.
            pixels[index * 4] = shade
            pixels[index * 4 + 1] = shade
            pixels[index * 4 + 2] = shade
            pixels[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Motion

    /// The camera: it chases its target on a critically damped spring, in position and in the logarithm of the zoom,
    /// so that it eases into every change and never stops dead.
    private struct Lens {
        var center: CGPoint
        var logZoom: Double
        private var velocity = SIMD3<Double>.zero
        var zoom: CGFloat { exp(logZoom) }

        init(target: (center: CGPoint, zoom: Double)) {
            center = target.center
            logZoom = log(target.zoom)
        }

        mutating func follow(_ target: (center: CGPoint, zoom: Double), over seconds: Double) {
            let omega = 2 * Double.pi * 1.3
            var value = SIMD3(Double(center.x), Double(center.y), logZoom)
            let goal = SIMD3(Double(target.center.x), Double(target.center.y), log(target.zoom))
            for _ in 0..<4 {
                let h = seconds / 4
                velocity += (omega * omega * (goal - value) - 2 * omega * velocity) * h
                value += velocity * h
            }
            center = CGPoint(x: value.x, y: value.y)
            logZoom = value.z
        }
    }

    /// Where the camera wants to be: between its keyframes, leaning towards the pointer as much as they say.
    private static func cameraTarget(at time: Double, pointer: CGPoint) -> (center: CGPoint, zoom: Double) {
        let next = camera.firstIndex { $0.time > time } ?? camera.count - 1
        let a = camera[max(next - 1, 0)], b = camera[next]
        let t = b.time > a.time ? min(max((time - a.time) / (b.time - a.time), 0), 1) : 1
        let x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t
        let follow = a.follow + (b.follow - a.follow) * t
        let zoom = a.zoom * pow(b.zoom / a.zoom, t)
        return (CGPoint(x: x + (pointer.x - x) * follow, y: y + (pointer.y - y) * follow), zoom)
    }

    /// Where the pointer is: through its keys on a Catmull-Rom curve in time, with no speed where it stops.
    private static func pointer(at time: Double) -> CGPoint {
        guard let next = path.firstIndex(where: { $0.time > time }), next > 0 else { return path.last!.point }
        let a = path[next - 1], b = path[next]
        func tangent(_ index: Int) -> CGPoint {
            let key = path[index]
            guard !key.stops, index > 0, index < path.count - 1 else { return .zero }
            let before = path[index - 1], after = path[index + 1]
            let span = after.time - before.time
            return CGPoint(x: (after.point.x - before.point.x) / span, y: (after.point.y - before.point.y) / span)
        }
        let duration = b.time - a.time
        let t = (time - a.time) / duration
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        let m0 = tangent(next - 1), m1 = tangent(next)
        return CGPoint(x: h00 * a.point.x + h10 * duration * m0.x + h01 * b.point.x + h11 * duration * m1.x,
                       y: h00 * a.point.y + h10 * duration * m0.y + h01 * b.point.y + h11 * duration * m1.y)
    }

    /// How far a dragged thing has moved by `time`: with the pointer while dragged, and staying where it was left.
    private static func dragOffset(_ what: Draggable, at time: Double) -> CGSize {
        guard let drag = drags.first(where: { $0.what == what }), time > drag.span.lowerBound else { return .zero }
        let start = pointer(at: drag.span.lowerBound), now = pointer(at: min(time, drag.span.upperBound))
        return CGSize(width: now.x - start.x, height: now.y - start.y)
    }

    /// 0 before, 1 after, a smooth S between.
    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Up to 1 with a small overshoot, like something set down with a bounce.
    private static func overshoot(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        let c = 1.7
        return t <= 0 ? 0 : 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }

    /// How much of something is shown between `start` and `end`, fading in and out over half a second.
    private static func window(_ time: Double, _ start: Double, _ end: Double) -> Double {
        min(ease((time - start) / 0.5), 1 - ease((time - end + 0.5) / 0.5))
    }
}
