import Foundation
import CoreGraphics

enum SnowIntensity: Int, Codable, CaseIterable {
    case light, steady, blizzard
    var title: String { ["Лёгкий", "Ровный", "Метель"][rawValue] }
    var deposition: Double { [0.12, 0.32, 0.65][rawValue] }
    var particleRate: Double { [22, 52, 110][rawValue] }
    var particleCap: Int { [450, 750, 1100][rawValue] }
}

enum SnowTool: Int, CaseIterable { case mitten, shovel, snowball, tree
    var title: String { ["Варежка", "Лопата", "Снежок", "Ёлочка"][rawValue] }
}

struct SnowWeather {
    var intensity: SnowIntensity = .steady
    var wind = CGVector.zero
    var reducedMotion = false
    var lowPower = false
}

/// One instanced quad. Layout matches the Metal shader: two aligned float4 values.
/// Coordinates and dimensions remain in the scene's local AppKit points.
struct SnowParticleInstance {
    var geometry: SIMD4<Float> // x, y, side length, rotation
    var appearance: SIMD4<Float> // opacity, crystal texture selector, reserved, reserved
}

enum SurfaceKind: String { case window, dock, floor }

/// World coordinates match AppKit: points, origin at the primary display's bottom left.
struct SnowSurface {
    /// Small system panels can share the owning app and layer of regular windows.
    static func meetsWindowSupportSize(_ frame: CGRect) -> Bool {
        frame.width >= 160 && frame.height >= 100
    }

    var id: String
    var frame: CGRect
    var kind: SurfaceKind
    var occluders: [CGRect] = []
    var isVisible = true
    /// Flat part of a rounded window's upper edge; frame remains the full window bounds.
    var topInset: CGFloat = 0
    /// Actual foreground rectangles only; unlike occluders, excludes roof ceiling masks.
    var bodyOccluders: [CGRect] = []
    /// For a floor captured from the desktop, the masks owned by system panels
    /// and other overlays. Ordinary windows remain part of `occluders` for snow.
    var floorOverlayOccluders: [CGRect]?
    /// Set only for the frontmost application's foremost ordinary window.
    var suppressesSnowfall = false
    var top: CGFloat { frame.maxY }
    func supports(x: CGFloat) -> Bool {
        let inset = min(max(0, topInset), frame.width / 2)
        return x >= frame.minX + inset && x <= frame.maxX - inset
    }
    func isSupportExposed(_ point: CGPoint) -> Bool {
        supports(x: point.x) && isExposed(point)
    }
    func isExposed(_ point: CGPoint) -> Bool {
        isVisible && !occluders.contains { $0.contains(point) }
    }
}

/// Per-display rules for wide ordinary windows, independent of focus discovery.
enum WideWindowPolicy {
    static func mask(forWindow window: CGRect, display: CGRect) -> CGRect? {
        guard valid(window), valid(display), window.minX <= display.minX + 2,
              window.maxX >= display.maxX - 2 else { return nil }
        let clipped = window.intersection(display)
        return valid(clipped) ? clipped : nil
    }

    static func snowfallMasks(surfaces: [SnowSurface], display: CGRect) -> [CGRect] {
        surfaces.compactMap { surface in
            guard surface.kind == .window, surface.isVisible, surface.suppressesSnowfall else { return nil }
            return mask(forWindow: surface.frame, display: display)
        }
    }

    /// Only this wide-window mask yields the bottom band. Panels and other
    /// foreground windows keep their masks, including over the exposed snow.
    static func floorOccluder(_ frame: CGRect, ordinaryWindow: Bool, display: CGRect) -> CGRect? {
        guard ordinaryWindow, mask(forWindow: frame, display: display) != nil else { return frame }
        let clipped = frame.intersection(display)
        let bottom = max(clipped.minY, display.minY + SnowDrift.maximumHeight + 2)
        guard clipped.maxY > bottom else { return nil }
        return CGRect(x: clipped.minX, y: bottom, width: clipped.width, height: clipped.maxY - bottom)
    }

    static func hidesParticle(center: CGPoint, side: CGFloat, rotation: CGFloat, masks: [CGRect]) -> Bool {
        guard !masks.isEmpty else { return false }
        // An enclosing square includes every corner of the rotated texture quad,
        // so no unmasked edge can protrude into the window from outside its bounds.
        let halfExtent = side * 0.5 * (abs(cos(rotation)) + abs(sin(rotation)))
        let quadBounds = CGRect(x: center.x - halfExtent, y: center.y - halfExtent,
                                width: halfExtent * 2, height: halfExtent * 2)
        return masks.contains { quadBounds.intersects($0) }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && !rect.isInfinite && !rect.isNull
    }
}

struct SnowDrift {
    var surface: SnowSurface
    var heights: [CGFloat]
    /// Cached per support geometry. Only floors also depend on world X, so their
    /// neighboring display edges sample the same continuous height envelope.
    let heightLimits: [CGFloat]
    static let spacing: CGFloat = 4
    static let maximumHeight: CGFloat = 28
    static let dockMaximumHeight: CGFloat = 22

    init(surface: SnowSurface, heights: [CGFloat], heightLimits: [CGFloat]? = nil) {
        self.surface = surface
        self.heights = heights
        self.heightLimits = heightLimits ?? SnowHeightEnvelope.samples(for: surface, count: heights.count)
    }

    var visibleContour: SnowContour {
        SnowContour(heights: heights, width: surface.frame.width,
                    roundedEnds: surface.kind != .floor, topInset: surface.topInset)
    }
}

/// A stationary, two-octave 1D gradient Perlin envelope. Windows and Dock use local
/// points; all floors share a seed and world X to keep display seams continuous.
/// Lattice gradients are seeded signs; quintic interpolation joins their dot products.
struct SnowHeightEnvelope {
    private let seed: UInt64
    private let phase: Double

    init(surfaceID: String) {
        seed = surfaceID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        phase = Double(seed & 0xffff) / 1024 + 0.37
    }

    func height(atLocalX x: CGFloat) -> CGFloat {
        guard x.isFinite else { return 21 }
        let long = Self.noise(at: Double(x) / 240 + phase, seed: seed)
        let short = Self.noise(at: Double(x) / 76 + phase + 19.61, seed: seed ^ 0x9e3779b97f4a7c15)
        // A unit 1D gradient produces at most +/-0.5. Normalize each octave.
        return min(SnowDrift.maximumHeight, max(14, 21 + CGFloat(long * 0.72 + short * 0.28) * 14))
    }

    func samples(width: CGFloat, count: Int) -> [CGFloat] {
        (0..<max(0, count)).map { height(atLocalX: min(CGFloat($0) * SnowDrift.spacing, width)) }
    }

    static func samples(for surface: SnowSurface, count: Int) -> [CGFloat] {
        let floor = surface.kind == .floor
        let envelope = SnowHeightEnvelope(surfaceID: floor ? "snezhno:continuous-floor" : surface.id)
        let origin = floor ? surface.frame.minX : 0
        let scale = surface.kind == .dock ? SnowDrift.dockMaximumHeight / SnowDrift.maximumHeight : 1
        return (0..<max(0, count)).map {
            envelope.height(atLocalX: origin + min(CGFloat($0) * SnowDrift.spacing, surface.frame.width)) * scale
        }
    }

    static func noise(at x: Double, seed: UInt64) -> Double {
        guard x.isFinite, abs(x) < 9_000_000_000_000_000 else { return 0 }
        let cell = floor(x)
        let t = x - cell
        func gradient(_ index: Int64) -> Double {
            var hash = UInt64(bitPattern: index) &+ seed &+ 0x9e3779b97f4a7c15
            hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
            hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
            hash ^= hash >> 31
            return hash & 1 == 0 ? -1 : 1
        }
        let left = gradient(Int64(cell)) * t
        let right = gradient(Int64(cell) + 1) * (t - 1)
        let fade = t * t * t * (t * (t * 6 - 15) + 10)
        return left + fade * (right - left)
    }
}

/// Shared visible roof geometry. Stored heights still represent snow mass; this
/// contour supplies the identical tapered, quadratic outline to drawing and contacts.
struct SnowContour {
    private let heights: [CGFloat]
    private let width: CGFloat
    private let roundedEnds: Bool
    private var start: CGFloat = 0
    private var end: CGFloat = 0
    private var firstGridIndex = 0
    private var interiorCount = 0
    private var leftRadius: CGFloat = 1
    private var rightRadius: CGFloat = 1

    init(heights: [CGFloat], width: CGFloat, roundedEnds: Bool, topInset: CGFloat) {
        self.heights = heights
        self.width = width
        self.roundedEnds = roundedEnds
        guard heights.count > 1, width.isFinite, width > 0 else { return }
        let inset = topInset.isFinite ? min(max(0, topInset), width / 2) : 0
        start = inset
        end = width - inset
        guard end > start else { return }
        firstGridIndex = Int(floor(start / SnowDrift.spacing)) + 1
        let lastGridIndex = Int(ceil(end / SnowDrift.spacing)) - 1
        interiorCount = max(0, lastGridIndex - firstGridIndex + 1)
        let flatWidth = end - start
        let windowCap = inset > 0
        let edgeSample = min(windowCap ? 24 : 12, flatWidth / 2)
        let capMaximum: CGFloat = windowCap ? 24 : 12
        let capMinimum: CGFloat = windowCap ? 8 : 4
        let capRatio: CGFloat = windowCap ? 0.85 : 0.55
        leftRadius = min(flatWidth / 2, min(capMaximum, max(capMinimum, storedHeight(at: start + edgeSample) * capRatio)))
        rightRadius = min(flatWidth / 2, min(capMaximum, max(capMinimum, storedHeight(at: end - edgeSample) * capRatio)))
    }

    var pointCount: Int { end > start ? interiorCount + 2 : 0 }

    func point(at index: Int) -> CGPoint {
        let x: CGFloat
        if index <= 0 { x = start }
        else if index >= pointCount - 1 { x = end }
        else { x = CGFloat(firstGridIndex + index - 1) * SnowDrift.spacing }
        func easing(_ value: CGFloat) -> CGFloat {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        let edge = roundedEnds ? min(easing((x - start) / max(0.001, leftRadius)),
                                     easing((end - x) / max(0.001, rightRadius))) : 1
        return CGPoint(x: x, y: storedHeight(at: x) * edge)
    }

    func height(at x: CGFloat) -> CGFloat {
        guard pointCount > 1, x >= start, x <= end else { return 0 }
        let curve = segment(at: segmentIndex(at: x))
        let a = curve.start.x - 2 * curve.control.x + curve.end.x
        let b = 2 * (curve.control.x - curve.start.x)
        let distance = x - curve.start.x
        let denominator = b + sqrt(max(0, b * b + 4 * a * distance))
        let t = min(1, max(0, denominator > 1e-12 ? 2 * distance / denominator : 0))
        return quadratic(curve.start.y, curve.control.y, curve.end.y, t)
    }

    /// Swept intersections with the same curves SpriteKit draws, not their chords.
    /// Only crossings from above are returned. Occlusion remains the caller's rule.
    func crossings(from: CGPoint, to: CGPoint) -> [(time: CGFloat, point: CGPoint)] {
        guard pointCount > 1, max(from.x, to.x) >= start, min(from.x, to.x) <= end else { return [] }
        let dx = to.x - from.x, dy = to.y - from.y
        if abs(dx) < 1e-10 {
            guard from.x >= start, from.x <= end, dy < -1e-6 else { return [] }
            let y = height(at: from.x)
            let t = (y - from.y) / dy
            return t >= -0.00001 && t <= 1 ? [(max(0, t), CGPoint(x: from.x, y: y))] : []
        }
        let first = segmentIndex(at: max(start, min(from.x, to.x)))
        let last = segmentIndex(at: min(end, max(from.x, to.x)))
        var result: [(time: CGFloat, point: CGPoint)] = []
        for index in first...last {
            let curve = segment(at: index)
            let ax = curve.start.x - 2 * curve.control.x + curve.end.x
            let bx = 2 * (curve.control.x - curve.start.x)
            let ay = curve.start.y - 2 * curve.control.y + curve.end.y
            let by = 2 * (curve.control.y - curve.start.y)
            let a = dy * ax - dx * ay
            let b = dy * bx - dx * by
            let c = dy * (curve.start.x - from.x) - dx * (curve.start.y - from.y)
            func append(_ u: CGFloat) {
                guard u >= -0.00001, u <= 1.00001 else { return }
                let u = min(1, max(0, u))
                let x = quadratic(curve.start.x, curve.control.x, curve.end.x, u)
                let time = (x - from.x) / dx
                guard time >= -0.00001, time <= 1 else { return }
                var tangentX = 2 * ax * u + bx
                var tangentY = 2 * ay * u + by
                if abs(tangentX) < 1e-10 {
                    tangentX = curve.end.x - curve.start.x
                    tangentY = curve.end.y - curve.start.y
                }
                guard dy * tangentX - dx * tangentY < -0.000001 * tangentX else { return }
                result.append((max(0, time), CGPoint(x: x, y: quadratic(curve.start.y, curve.control.y, curve.end.y, u))))
            }
            if abs(a) < 1e-10 {
                if abs(b) > 1e-10 { append(-c / b) }
            } else {
                let discriminant = b * b - 4 * a * c
                if discriminant >= 0 {
                    let root = sqrt(discriminant)
                    let q = -0.5 * (b + (b >= 0 ? root : -root))
                    if abs(q) < 1e-12 { append(-b / (2 * a)) }
                    else { append(q / a); append(c / q) }
                }
            }
        }
        return result
    }

    private func storedHeight(at x: CGFloat) -> CGFloat {
        let lower = min(heights.count - 1, max(0, Int(x / SnowDrift.spacing)))
        let upper = min(heights.count - 1, lower + 1)
        let leftX = min(width, CGFloat(lower) * SnowDrift.spacing)
        let rightX = min(width, CGFloat(upper) * SnowDrift.spacing)
        let t = rightX > leftX ? (x - leftX) / (rightX - leftX) : 0
        return max(0, heights[lower] + (heights[upper] - heights[lower]) * t)
    }

    private func segmentIndex(at x: CGFloat) -> Int {
        if x <= (point(at: 0).x + point(at: 1).x) * 0.5 { return 0 }
        if x >= (point(at: pointCount - 2).x + point(at: pointCount - 1).x) * 0.5 { return pointCount - 1 }
        return min(pointCount - 2, max(1, Int((x / SnowDrift.spacing).rounded()) - firstGridIndex + 1))
    }

    private func segment(at index: Int) -> (start: CGPoint, control: CGPoint, end: CGPoint) {
        let control = point(at: index)
        let before = point(at: max(0, index - 1))
        let after = point(at: min(pointCount - 1, index + 1))
        return (CGPoint(x: (before.x + control.x) * 0.5, y: (before.y + control.y) * 0.5), control,
                CGPoint(x: (control.x + after.x) * 0.5, y: (control.y + after.y) * 0.5))
    }

    private func quadratic(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ t: CGFloat) -> CGFloat {
        let remaining = 1 - t
        return remaining * remaining * a + 2 * remaining * t * b + t * t * c
    }
}

struct Snowball {
    var id: UUID = UUID()
    var position: CGPoint
    var velocity: CGVector = .zero
    var radius: CGFloat
    var surfaceID: String?
    var restingTime: Double = 0
}

enum SnowballContact {
    /// A settled stack compresses slightly without changing either ball's mass.
    /// Flying and side-impact collision detection still uses the full radius sum.
    static func stackedCenterDistance(radius: CGFloat, otherRadius: CGFloat) -> CGFloat {
        radius + otherRadius - min(3, min(radius, otherRadius) * 0.12)
    }
}

struct Snowman {
    var ballIDs: [UUID] // bottom, middle, head
}

struct SnowDebris {
    var position: CGPoint
    var velocity: CGVector
    var lifetime: Double
    var radius: CGFloat
}

struct DesktopSnapshot {
    var generation: UInt64
    var surfaces: [SnowSurface]
    var fullscreenDisplayIDs: Set<UInt32>
    var accessibilityTrusted: Bool
    var dockDetected: Bool
    var windowCount: Int
    var captureMilliseconds: Double
    var hiddenWindowSupportIDs: Set<String> = []
    var screenshotSelectionActive = false
}

enum WorldCoordinates {
    static func fromQuartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
