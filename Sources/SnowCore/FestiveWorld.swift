import Foundation
import CoreGraphics

struct FestiveOptions: Codable, Equatable {
    var desktopGarland: Bool
    var windowGarlands: Bool
    var christmasTrees: Bool
    var aurora: Bool
    var shootingStars: Bool
    var duck: Bool

    init(desktopGarland: Bool = false, windowGarlands: Bool = false, christmasTrees: Bool = false,
         aurora: Bool = false, shootingStars: Bool = false, duck: Bool = true) {
        self.desktopGarland = desktopGarland
        self.windowGarlands = windowGarlands
        self.christmasTrees = christmasTrees
        self.aurora = aurora
        self.shootingStars = shootingStars
        self.duck = duck
    }

    enum CodingKeys: String, CodingKey {
        case desktopGarland, windowGarlands, christmasTrees, aurora, shootingStars, duck
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        desktopGarland = (try? fields.decode(Bool.self, forKey: .desktopGarland)) ?? false
        windowGarlands = (try? fields.decode(Bool.self, forKey: .windowGarlands)) ?? false
        christmasTrees = (try? fields.decode(Bool.self, forKey: .christmasTrees)) ?? false
        aurora = (try? fields.decode(Bool.self, forKey: .aurora)) ?? false
        shootingStars = (try? fields.decode(Bool.self, forKey: .shootingStars)) ?? false
        duck = (try? fields.decode(Bool.self, forKey: .duck)) ?? true
    }
}

struct FestiveTreePlacement {
    let id: UUID
    let surface: SnowSurface
    let base: CGPoint
    let height: CGFloat
    let variant: Int
    let bounds: CGRect
}

/// Main-thread-owned decorations, anchored to the same geometry as the snow.
/// Visibility is presentation state: hidden supports retain their placements.
final class FestiveWorld {
    private struct Anchor {
        let id: UUID
        var surfaceID: String
        var localX: CGFloat
        let variant: Int
    }

    private var anchors: [Anchor] = []
    private var nextVariant = 0
    private let maximumTrees = 8
    private let heights: [CGFloat] = [96, 112, 128]

    /// Decorations do not inherit the exposed floor band used by wide-window snow.
    static func desktopOccluders(in snow: SnowWorld) -> [CGRect] {
        let visible = snow.surfaces.filter(\.isVisible)
        return visible.filter { $0.kind == .window }.map(\.frame)
            + visible.flatMap(\.bodyOccluders)
            + visible.filter { $0.kind == .floor }.flatMap(\.occluders)
    }

    /// Renderer, selection and placement share the same whole-object visibility.
    static func occluders(for surface: SnowSurface, in snow: SnowWorld) -> [CGRect] {
        surface.kind == .floor ? desktopOccluders(in: snow) : surface.occluders + surface.bodyOccluders
    }

    func placements(in snow: SnowWorld) -> [FestiveTreePlacement] {
        anchors.compactMap { anchor in
            guard let surface = snow.surfaces.first(where: { $0.id == anchor.surfaceID }),
                  let range = supportRange(surface) else { return nil }
            let localX = min(range.upperBound, max(range.lowerBound, anchor.localX))
            let base = basePoint(surface: surface, localX: localX, snow: snow)
            let height = heights[anchor.variant]
            return FestiveTreePlacement(id: anchor.id, surface: surface, base: base,
                height: height, variant: anchor.variant,
                bounds: CGRect(x: base.x - height * 0.32, y: base.y, width: height * 0.64, height: height))
        }
    }

    @discardableResult
    func place(at point: CGPoint, displayFrame: CGRect, snow: SnowWorld) -> UUID? {
        guard anchors.count < maximumTrees,
              let target = target(at: point, displayFrame: displayFrame, snow: snow, belowTolerance: 8) else { return nil }
        let id = UUID()
        anchors.append(Anchor(id: id, surfaceID: target.surfaceID, localX: target.localX, variant: nextVariant))
        nextVariant = (nextVariant + 1) % heights.count
        return id
    }

    @discardableResult
    func move(id: UUID, to point: CGPoint, displayFrame: CGRect, snow: SnowWorld) -> Bool {
        guard let index = anchors.firstIndex(where: { $0.id == id }),
              let target = target(at: point, displayFrame: displayFrame, snow: snow,
                                  belowTolerance: SnowDrift.maximumHeight) else { return false }
        anchors[index].surfaceID = target.surfaceID
        anchors[index].localX = target.localX
        return true
    }

    func hitTest(_ point: CGPoint, displayFrame: CGRect, snow: SnowWorld) -> UUID? {
        guard valid(point), validDisplay(displayFrame), displayFrame.contains(point) else { return nil }
        let placements = placements(in: snow)
        // Snow surfaces are front-to-back. Within one support the latest tree is on top.
        for surface in snow.surfaces where surface.isVisible {
            guard !Self.occluders(for: surface, in: snow).contains(where: { $0.contains(point) }) else { continue }
            for placement in placements.reversed() where placement.surface.id == surface.id {
                if placement.bounds.contains(point) { return placement.id }
            }
        }
        return nil
    }

    func remove(id: UUID) { anchors.removeAll { $0.id == id } }

    func clear() {
        anchors.removeAll(keepingCapacity: true)
        nextVariant = 0
    }

    func scatter<R: RandomNumberGenerator>(in display: CGRect, snow: SnowWorld, using generator: inout R)
        -> (trees: Int, snowmen: Int) {
        let surfaces = snow.surfaces.filter {
            $0.isVisible && ($0.kind == .floor || $0.kind == .window)
                && $0.frame.maxX > display.minX && $0.frame.minX < display.maxX
        }
        guard !surfaces.isEmpty else { return (0, 0) }
        var counts = (trees: 0, snowmen: 0)
        for tree in [true, false] {
            let desired = tree ? 3 : 2
            for _ in 0..<80 {
                if (tree ? counts.trees : counts.snowmen) >= desired { break }
                guard let surface = surfaces.randomElement(using: &generator), let range = supportRange(surface),
                      let drift = snow.drifts[surface.id] else { continue }
                let margin: CGFloat = tree ? 42 : 20
                let lower = max(surface.frame.minX + range.lowerBound + margin, display.minX + margin)
                let upper = min(surface.frame.minX + range.upperBound - margin, display.maxX - margin)
                guard upper > lower else { continue }
                let x = CGFloat.random(in: lower...upper, using: &generator)
                let base = surface.top + drift.visibleContour.height(at: x - surface.frame.minX)
                let bounds = CGRect(x: x - margin, y: base, width: margin * 2, height: tree ? 128 : 88)
                let masks = Self.occluders(for: surface, in: snow)
                let objects = placements(in: snow).map(\.bounds) + snow.balls.map {
                    CGRect(x: $0.position.x - $0.radius, y: $0.position.y - $0.radius,
                           width: $0.radius * 2, height: $0.radius * 2)
                }
                guard display.contains(bounds), !masks.contains(where: { $0.intersects(bounds) }),
                      !objects.contains(where: { $0.insetBy(dx: -10, dy: -2).intersects(bounds) }) else { continue }
                if tree {
                    let point = CGPoint(x: x, y: base + 1)
                    if target(at: point, displayFrame: display, snow: snow, belowTolerance: 8)?.surfaceID == surface.id,
                       place(at: point, displayFrame: display, snow: snow) != nil {
                        counts.trees += 1
                    }
                } else if snow.placeSnowman(on: surface, x: x) {
                    counts.snowmen += 1
                }
            }
        }
        return counts
    }

    func syncSurfaces(_ surfaces: [SnowSurface]) {
        anchors = anchors.compactMap { anchor in
            guard let surface = surfaces.first(where: { $0.id == anchor.surfaceID }),
                  let range = supportRange(surface) else { return nil }
            var retained = anchor
            retained.localX = min(range.upperBound, max(range.lowerBound, anchor.localX))
            return retained
        }
    }

    /// Physical display removal only; a fullscreen/inactive display is not unplugged.
    func prune(to regions: [CGRect], snow: SnowWorld) {
        syncSurfaces(snow.surfaces)
        let regions = regions.filter(validDisplay)
        let keep = Set(placements(in: snow).filter { placement in
            regions.contains { $0.contains(placement.base) }
        }.map(\.id))
        anchors.removeAll { !keep.contains($0.id) }
    }

    private func target(at point: CGPoint, displayFrame: CGRect, snow: SnowWorld,
                        belowTolerance: CGFloat) -> (surfaceID: String, localX: CGFloat)? {
        guard valid(point), validDisplay(displayFrame), displayFrame.contains(point) else { return nil }
        var selected: (surfaceID: String, localX: CGFloat)?
        var nearest = CGFloat.infinity
        for surface in snow.surfaces where surface.isVisible {
            guard let range = supportRange(surface),
                  point.x >= surface.frame.minX, point.x <= surface.frame.maxX else { continue }
            let masks = Self.occluders(for: surface, in: snow)
            guard !masks.contains(where: { $0.contains(point) }) else { continue }
            let lower = max(surface.frame.minX + range.lowerBound, displayFrame.minX)
            let upper = min(surface.frame.minX + range.upperBound, displayFrame.maxX)
            guard upper > lower else { continue }
            let localX = min(upper, max(lower, point.x)) - surface.frame.minX
            let base = basePoint(surface: surface, localX: localX, snow: snow)
            let drop = point.y - base.y
            guard displayFrame.contains(base), surface.supports(x: base.x),
                  !masks.contains(where: { $0.contains(base) }),
                  drop >= -belowTolerance, drop <= 140 else { continue }
            let distance = abs(drop)
            // A tie retains the earlier, foreground surface.
            if distance < nearest {
                nearest = distance
                selected = (surface.id, localX)
            }
        }
        return selected
    }

    private func basePoint(surface: SnowSurface, localX: CGFloat, snow: SnowWorld) -> CGPoint {
        let height = snow.drifts[surface.id]?.visibleContour.height(at: localX) ?? 0
        return CGPoint(x: surface.frame.minX + localX, y: surface.top + height)
    }

    private func supportRange(_ surface: SnowSurface) -> ClosedRange<CGFloat>? {
        guard surface.kind == .window || surface.kind == .floor,
              valid(surface.frame.origin), surface.frame.width.isFinite, surface.frame.height.isFinite,
              surface.frame.width > 0, surface.frame.height >= 0,
              surface.frame.maxX.isFinite, surface.top.isFinite else { return nil }
        let inset = surface.topInset.isFinite ? min(max(0, surface.topInset), surface.frame.width / 2) : 0
        guard surface.frame.width > inset * 2 else { return nil }
        return inset...(surface.frame.width - inset)
    }

    private func valid(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private func validDisplay(_ rect: CGRect) -> Bool {
        valid(rect.origin) && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
