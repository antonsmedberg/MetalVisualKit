#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvasSize = 1024
private let defaultOutput = "Examples/MetalVisualKitDemo/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func mix(_ start: (CGFloat, CGFloat, CGFloat), _ end: (CGFloat, CGFloat, CGFloat), amount: CGFloat) -> CGColor {
    color(
        start.0 + (end.0 - start.0) * amount,
        start.1 + (end.1 - start.1) * amount,
        start.2 + (end.2 - start.2) * amount
    )
}

private func particleColor(_ amount: CGFloat) -> CGColor {
    if amount < 0.52 {
        return mix((0.10, 0.86, 1.00), (0.31, 0.38, 1.00), amount: amount / 0.52)
    }
    return mix((0.31, 0.38, 1.00), (1.00, 0.25, 0.66), amount: (amount - 0.52) / 0.48)
}

private func drawGlow(
    in context: CGContext,
    centre: CGPoint,
    radius: CGFloat,
    colour: CGColor,
    opacity: CGFloat
) {
    let clear = color(
        colour.components?[0] ?? 1,
        colour.components?[1] ?? 1,
        colour.components?[2] ?? 1,
        0
    )
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [colour.copy(alpha: opacity) ?? colour, clear] as CFArray,
        locations: [0, 1]
    ) else { return }
    context.drawRadialGradient(
        gradient,
        startCenter: centre,
        startRadius: 0,
        endCenter: centre,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
}

private func drawIcon(in context: CGContext) {
    let centre = CGPoint(x: 512, y: 512)

    let backgroundColours = [
        color(0.018, 0.030, 0.075),
        color(0.035, 0.070, 0.160),
        color(0.100, 0.075, 0.250)
    ] as CFArray
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: backgroundColours,
        locations: [0, 0.58, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 60, y: 50),
        end: CGPoint(x: 960, y: 1_020),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    drawGlow(in: context, centre: CGPoint(x: 500, y: 530), radius: 470, colour: color(0.10, 0.65, 1), opacity: 0.22)
    drawGlow(in: context, centre: CGPoint(x: 720, y: 390), radius: 360, colour: color(0.95, 0.20, 0.65), opacity: 0.14)

    context.saveGState()
    context.setLineWidth(2)
    for offset in stride(from: -520, through: 520, by: 96) {
        context.setStrokeColor(color(0.55, 0.72, 1, 0.035))
        context.move(to: CGPoint(x: CGFloat(offset), y: 0))
        context.addLine(to: CGPoint(x: CGFloat(offset + 760), y: 1_024))
        context.strokePath()
    }
    context.restoreGState()

    let haloRadius: CGFloat = 330
    context.setStrokeColor(color(0.18, 0.34, 0.68, 0.42))
    context.setLineWidth(104)
    context.addArc(center: centre, radius: haloRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()

    let gapStart = CGFloat.pi * 0.12
    let gapEnd = CGFloat.pi * 0.40
    let arcStart = gapEnd
    let arcSpan = CGFloat.pi * 2 - (gapEnd - gapStart)
    let segments = 132
    context.setLineCap(.round)
    for index in 0..<segments {
        let amount = CGFloat(index) / CGFloat(segments - 1)
        let start = arcStart + arcSpan * CGFloat(index) / CGFloat(segments)
        let segmentEnd = (CGFloat(index) + 1.25) / CGFloat(segments)
        let end = arcStart + arcSpan * segmentEnd
        context.setStrokeColor(particleColor(amount))
        context.setLineWidth(92)
        context.addArc(center: centre, radius: haloRadius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()
    }

    let headAngle = arcStart + arcSpan
    let head = CGPoint(
        x: centre.x + cos(headAngle) * haloRadius,
        y: centre.y + sin(headAngle) * haloRadius
    )
    drawGlow(in: context, centre: head, radius: 112, colour: color(0.20, 0.92, 1), opacity: 0.52)
    context.setFillColor(color(0.88, 0.99, 1))
    context.fillEllipse(in: CGRect(x: head.x - 35, y: head.y - 35, width: 70, height: 70))

    context.saveGState()
    context.translateBy(x: centre.x, y: centre.y)
    context.rotate(by: -.pi / 16)
    context.translateBy(x: -centre.x, y: -centre.y)

    let rows: [(CGFloat, Int, CGFloat)] = [
        (-178, 3, 0.72),
        (-118, 6, 0.82),
        (-56, 8, 0.94),
        (8, 9, 1.00),
        (72, 8, 0.94),
        (134, 6, 0.82),
        (184, 3, 0.72)
    ]

    for (rowIndex, row) in rows.enumerated() {
        let (yOffset, count, scale) = row
        let width = CGFloat(count - 1) * 52
        for pointIndex in 0..<count {
            let amount = count == 1 ? 0.5 : CGFloat(pointIndex) / CGFloat(count - 1)
            let x = centre.x - width / 2 + CGFloat(pointIndex) * 52
            let stagger = rowIndex.isMultiple(of: 2) ? CGFloat(0) : CGFloat(11)
            let y = centre.y + yOffset + sin(amount * .pi) * 13
            let point = CGPoint(x: x + stagger, y: y)
            let depth = 0.68 + 0.32 * sin(amount * .pi)
            let radius = (13 + 9 * depth) * scale
            let tint = min(1, max(0, amount * 0.72 + CGFloat(rowIndex) * 0.045))
            let pointColour = particleColor(tint)

            drawGlow(in: context, centre: point, radius: radius * 3.2, colour: pointColour, opacity: 0.20)
            context.setFillColor(pointColour)
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }
    context.restoreGState()

    context.setStrokeColor(color(0.83, 0.96, 1, 0.34))
    context.setLineWidth(5)
    context.addEllipse(in: CGRect(x: 333, y: 333, width: 358, height: 358))
    context.strokePath()

    context.setFillColor(color(0.92, 0.99, 1))
    context.fillEllipse(in: CGRect(x: 487, y: 487, width: 50, height: 50))
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? defaultOutput)
let temporaryURL = outputURL
    .deletingPathExtension()
    .appendingPathExtension("pending.png")
let fileManager = FileManager.default
try? fileManager.removeItem(at: temporaryURL)
defer { try? fileManager.removeItem(at: temporaryURL) }

let colourSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: canvasSize * 4,
    space: colourSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Unable to create icon bitmap context")
}

drawIcon(in: context)
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          temporaryURL as CFURL,
          UTType.png.identifier as CFString,
          1,
          nil
      )
else {
    fatalError("Unable to create icon output")
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to finalise temporary icon")
}

do {
    if fileManager.fileExists(atPath: outputURL.path) {
        _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else {
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
    }
} catch {
    fatalError("Unable to replace \(outputURL.path): \(error)")
}

print("Generated opaque \(canvasSize)×\(canvasSize) icon at \(outputURL.path)")
