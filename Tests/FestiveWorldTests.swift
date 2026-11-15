import Foundation
import CoreGraphics

private struct FestiveFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum FestiveWorldTests {
    private static var checks = 0
    private static let display = CGRect(x: 0, y: 0, width: 600, height: 400)

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64 = 17
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw FestiveFailure(description: message) }
    }

    private static func floor(_ id: String = "floor", x: CGFloat = 0, width: CGFloat = 600) -> SnowSurface {
        SnowSurface(id: id, frame: CGRect(x: x, y: -1, width: width, height: 1), kind: .floor)
    }

    private static func window(_ id: String = "window") -> SnowSurface {
        SnowSurface(id: id, frame: CGRect(x: 80, y: 20, width: 240, height: 50), kind: .window, topInset: 16)
    }

    private static func configured(_ surfaces: [SnowSurface]) -> SnowWorld {
        let snow = SnowWorld(seed: 91)
        snow.syncSurfaces(surfaces)
        snow.prune(to: [CGRect(x: -600, y: 0, width: 1200, height: 400)])
        return snow
    }

    private static func options() throws {
        let defaults = FestiveOptions()
        try require(!defaults.desktopGarland && !defaults.windowGarlands && !defaults.christmasTrees
                    && !defaults.aurora && !defaults.shootingStars, "All effects default off")
        let empty = try JSONDecoder().decode(FestiveOptions.self, from: Data("{}".utf8))
        try require(empty == defaults, "Old settings without decoration fields retain defaults")
        let malformed = Data("{\"desktopGarland\":true,\"windowGarlands\":\"bad\",\"christmasTrees\":null,\"aurora\":true,\"shootingStars\":17}".utf8)
        let recovered = try JSONDecoder().decode(FestiveOptions.self, from: malformed)
        try require(recovered == FestiveOptions(desktopGarland: true, aurora: true),
                    "One invalid field must not discard other enabled effects")
        for index in 0..<5 {
            var value = defaults
            switch index {
            case 0: value.desktopGarland = true
            case 1: value.windowGarlands = true
            case 2: value.christmasTrees = true
            case 3: value.aurora = true
            default: value.shootingStars = true
            }
            let restored = try JSONDecoder().decode(FestiveOptions.self, from: JSONEncoder().encode(value))
            try require(restored == value, "Every independent toggle round-trips")
        }
    }

    private static func placementAndSnow() throws {
        let roof = window(), snow = configured([roof, floor()]), festive = FestiveWorld()
        let id = festive.place(at: CGPoint(x: 82, y: 88), displayFrame: display, snow: snow)
        try require(id != nil, "A point above a rounded corner snaps to the flat roof")
        let original = festive.placements(in: snow)[0]
        try require(original.surface.id == roof.id && original.base.x == 96 && original.base.y == 70,
                    "Nearest roof wins over the floor and clamps to its inset")
        try require(original.bounds.minY == original.base.y && original.bounds.midX == original.base.x,
                    "Bounds use a centered bottom anchor in world coordinates")
        try require(festive.move(id: id!, to: CGPoint(x: 200, y: 88), displayFrame: display, snow: snow), "Move along roof")
        for _ in 0..<600 { snow.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .blizzard), activeRegions: [display]) }
        let raised = festive.placements(in: snow)[0]
        try require(raised.base.y > roof.top + 1 && raised.base.x == 200 && raised.id == id,
                    "Growing snow lifts a tree without changing its identity or horizontal anchor")
        let mass = snow.drifts[roof.id]!.heights
        try require(festive.move(id: id!, to: CGPoint(x: 500, y: 20), displayFrame: display, snow: snow), "Tree can transfer onto the floor")
        try require(festive.placements(in: snow)[0].surface.kind == .floor && snow.drifts[roof.id]!.heights == mass,
                    "Decorative placement never removes or changes snow mass")
        let oldBase = festive.placements(in: snow)[0].base
        for _ in 0..<3_600 { snow.step(delta: 1.0 / 60, weather: SnowWeather(intensity: .blizzard), activeRegions: [display]) }
        try require(festive.placements(in: snow)[0].base.y > oldBase.y + 8, "Fixture snow grows beyond the placement tolerance")
        try require(festive.place(at: oldBase, displayFrame: display, snow: snow) == nil,
                    "A new placement cannot snap deeply upward through accumulated snow")
        try require(festive.move(id: id!, to: oldBase, displayFrame: display, snow: snow),
                    "Dragging an existing base tolerates the full snow-height difference without sticking")
    }

    private static func limitsAndRemoval() throws {
        let snow = configured([floor()]), festive = FestiveWorld()
        var ids: [UUID] = []
        for index in 0..<8 {
            let id = festive.place(at: CGPoint(x: 35 + index * 65, y: 20), displayFrame: display, snow: snow)
            try require(id != nil, "First eight placements are accepted")
            ids.append(id!)
        }
        let placements = festive.placements(in: snow)
        try require(Set(placements.map(\.id)).count == 8, "Tree IDs are distinct")
        try require(placements.map(\.height) == [96, 112, 128, 96, 112, 128, 96, 112], "Three stable sizes cycle deterministically")
        try require(festive.place(at: CGPoint(x: 100, y: 20), displayFrame: display, snow: snow) == nil, "Ninth placement hits the bound")
        try require(festive.move(id: ids[0], to: CGPoint(x: 40, y: 30), displayFrame: display, snow: snow), "Limit does not prevent moving existing trees")
        festive.remove(id: ids[3])
        try require(festive.placements(in: snow).count == 7 && festive.place(at: CGPoint(x: 260, y: 20), displayFrame: display, snow: snow) != nil,
                    "Removing one tree frees exactly one slot")
        festive.remove(id: UUID())
        try require(festive.placements(in: snow).count == 8, "Unknown removal has no effect")
        festive.clear()
        try require(festive.placements(in: snow).isEmpty, "Clear removes the temporary world")
    }

    private static func movingAndHiddenSupports() throws {
        var roof = window()
        let snow = configured([roof, floor()]), festive = FestiveWorld()
        let id = festive.place(at: CGPoint(x: 280, y: 85), displayFrame: display, snow: snow)!
        roof.frame.origin.x += 40; roof.frame.origin.y += 30
        snow.syncSurfaces([roof, floor()]); festive.syncSurfaces(snow.surfaces)
        try require(festive.placements(in: snow)[0].base == CGPoint(x: 320, y: 100), "Translation carries the local anchor")
        roof.frame.size.width = 130
        snow.syncSurfaces([roof, floor()]); festive.syncSurfaces(snow.surfaces)
        try require(festive.placements(in: snow)[0].base.x == roof.frame.maxX - 16, "Resize clamps to the remaining flat roof")
        roof.isVisible = false
        snow.syncSurfaces([roof, floor()]); festive.syncSurfaces(snow.surfaces)
        let hidden = festive.placements(in: snow)[0]
        try require(hidden.id == id && !hidden.surface.isVisible, "Hidden support retains its placement")
        try require(festive.hitTest(CGPoint(x: hidden.base.x, y: hidden.base.y + 20), displayFrame: display, snow: snow) == nil,
                    "Hidden tree cannot capture a click")
        roof.isVisible = true
        snow.syncSurfaces([roof, floor()]); festive.syncSurfaces(snow.surfaces)
        try require(festive.placements(in: snow)[0].id == id, "Reveal restores the same tree")
        snow.syncSurfaces([floor()]); festive.syncSurfaces(snow.surfaces)
        try require(festive.placements(in: snow).isEmpty, "Closed support removes its tree")
    }

    private static func masksAndHitOrder() throws {
        var roof = window()
        let snow = configured([roof, floor()]), festive = FestiveWorld()
        let id = festive.place(at: CGPoint(x: 180, y: 90), displayFrame: display, snow: snow)!
        let hit = CGPoint(x: 180, y: 110)
        try require(festive.hitTest(hit, displayFrame: display, snow: snow) == id, "Visible canopy can be selected")
        roof.occluders = [CGRect(x: 160, y: 100, width: 40, height: 80)]
        roof.bodyOccluders = roof.occluders
        var coveredFloor = floor()
        coveredFloor.occluders = roof.occluders
        snow.syncSurfaces([roof, coveredFloor]); festive.syncSurfaces(snow.surfaces)
        try require(festive.hitTest(hit, displayFrame: display, snow: snow) == nil, "Foreground mask blocks the clicked tree point")
        try require(festive.hitTest(CGPoint(x: 180, y: 75), displayFrame: display, snow: snow) == id,
                    "A mask over the canopy does not hide an exposed trunk point")
        try require(festive.move(id: id, to: hit, displayFrame: display, snow: snow) == false,
                    "Move cannot pass through the mask at the pointer")
        try require(festive.placements(in: snow)[0].base == CGPoint(x: 180, y: 70), "Rejected move retains its previous anchor")
        roof.occluders = [CGRect(x: 160, y: 65, width: 40, height: 20)]
        roof.bodyOccluders = roof.occluders
        snow.syncSurfaces([roof])
        try require(festive.place(at: hit, displayFrame: display, snow: snow) == nil,
                    "An exposed pointer cannot attach a new tree to a covered base")

        roof.occluders = []
        roof.bodyOccluders = []
        snow.syncSurfaces([roof, floor()]); festive.clear()
        let front = festive.place(at: CGPoint(x: 180, y: 90), displayFrame: display, snow: snow)!
        _ = festive.place(at: CGPoint(x: 180, y: 10), displayFrame: display, snow: snow)
        try require(festive.hitTest(CGPoint(x: 180, y: 80), displayFrame: display, snow: snow) == front,
                    "Foreground surface wins over a newer tree on a back surface")
        let newer = festive.place(at: CGPoint(x: 180, y: 90), displayFrame: display, snow: snow)!
        try require(festive.hitTest(CGPoint(x: 180, y: 80), displayFrame: display, snow: snow) == newer,
                    "Newest tree wins when both share the same support")
    }

    private static func decorationMaskRegressions() throws {
        var ground = floor()
        let snow = configured([ground]), festive = FestiveWorld()
        let id = festive.place(at: CGPoint(x: 180, y: 20), displayFrame: display, snow: snow)!
        let stem = CGPoint(x: 180, y: 10)
        try require(festive.hitTest(stem, displayFrame: display, snow: snow) == id,
                    "Uncovered floor tree has a selectable stem")
        let wide = SnowSurface(id: "wide", frame: CGRect(x: 0, y: 0, width: 600, height: 250), kind: .window)
        ground.occluders = [WideWindowPolicy.floorOccluder(wide.frame, ordinaryWindow: true, display: display)!]
        snow.syncSurfaces([wide, ground]); festive.syncSurfaces(snow.surfaces)
        try require(ground.isExposed(stem), "Fixture keeps the normal wide-window snow band exposed")
        try require(FestiveWorld.desktopOccluders(in: snow).contains { $0.contains(stem) },
                    "Desktop decoration mask covers the complete wide window")
        try require(festive.hitTest(stem, displayFrame: display, snow: snow) == nil,
                    "A floor-tree stem hidden by the wide window cannot be selected")
        try require(festive.place(at: stem, displayFrame: display, snow: snow) == nil
                    && !festive.move(id: id, to: stem, displayFrame: display, snow: snow),
                    "Placement and dragging cannot enter the decoration-only mask")
        try require(festive.placements(in: snow).first?.id == id, "Masking retains the anchored tree")
        var hidden = wide; hidden.isVisible = false
        snow.syncSurfaces([hidden, floor()])
        try require(festive.hitTest(stem, displayFrame: display, snow: snow) == id,
                    "A hidden window stops masking the floor tree")

        var roof = window()
        snow.syncSurfaces([roof]); festive.clear()
        let roofTree = festive.place(at: CGPoint(x: 180, y: 90), displayFrame: display, snow: snow)!
        let canopy = CGPoint(x: 180, y: 110)
        let ceiling = CGRect(x: 0, y: roof.top, width: display.width, height: display.maxY - roof.top)
        roof.occluders = [ceiling]
        snow.syncSurfaces([roof]); festive.syncSurfaces(snow.surfaces)
        try require(FestiveWorld.occluders(for: roof, in: snow).contains(ceiling),
                    "Tree renderer receives the same ceiling mask as the input model")
        try require(festive.hitTest(canopy, displayFrame: display, snow: snow) == nil
                    && festive.place(at: canopy, displayFrame: display, snow: snow) == nil,
                    "Ceiling-covered trees cannot be selected or newly placed")
        try require(festive.placements(in: snow).first?.id == roofTree, "Ceiling mask preserves the tree for reveal")
        roof.occluders = []
        roof.bodyOccluders = [CGRect(x: 160, y: 100, width: 40, height: 80)]
        snow.syncSurfaces([roof])
        try require(festive.hitTest(canopy, displayFrame: display, snow: snow) == nil
                    && !festive.move(id: roofTree, to: canopy, displayFrame: display, snow: snow),
                    "Real foreground body masks also apply without a duplicate roof mask")
        roof.bodyOccluders = []
        snow.syncSurfaces([roof])
        try require(festive.hitTest(canopy, displayFrame: display, snow: snow) == roofTree,
                    "Removing ceiling and body masks reveals the original tree")
    }

    private static func displayAndInvalidInput() throws {
        let left = CGRect(x: -600, y: 0, width: 600, height: 400)
        let snow = configured([floor("left", x: -600), floor()]), festive = FestiveWorld()
        let id = festive.place(at: CGPoint(x: -100, y: 20), displayFrame: left, snow: snow)!
        try require(festive.placements(in: snow)[0].base.x == -100, "Negative display coordinates remain world points")
        try require(festive.hitTest(CGPoint(x: -100, y: 30), displayFrame: display, snow: snow) == nil,
                    "Another display cannot select this point")
        try require(!festive.move(id: id, to: CGPoint(x: 100, y: 20), displayFrame: left, snow: snow), "Move is confined to the active display")
        try require(festive.place(at: CGPoint(x: 200, y: 200), displayFrame: display, snow: snow) == nil, "An excessive vertical snap is rejected")
        for point in [CGPoint(x: CGFloat.nan, y: 20), CGPoint(x: 20, y: CGFloat.infinity), CGPoint(x: 700, y: 20)] {
            try require(festive.place(at: point, displayFrame: display, snow: snow) == nil, "Invalid/off-display pointer is ignored")
        }
        try require(festive.place(at: CGPoint(x: 20, y: 20), displayFrame: .zero, snow: snow) == nil, "Empty active display is ignored")
        festive.prune(to: [display], snow: snow)
        try require(festive.placements(in: snow).isEmpty, "Unplug removes trees whose base belongs to the removed display")
        let dock = SnowSurface(id: "dock", frame: CGRect(x: 100, y: 0, width: 300, height: 60), kind: .dock)
        snow.syncSurfaces([dock, floor()])
        _ = festive.place(at: CGPoint(x: 200, y: 80), displayFrame: display, snow: snow)
        try require(festive.placements(in: snow)[0].surface.kind == .floor, "Dock never becomes a tree support")
        snow.syncSurfaces([dock]); festive.syncSurfaces(snow.surfaces)
        try require(festive.place(at: CGPoint(x: 200, y: 80), displayFrame: display, snow: snow) == nil, "Dock alone offers no placement")
        let tooNarrow = SnowSurface(id: "closed-inset", frame: CGRect(x: 10, y: 10, width: 20, height: 20), kind: .window, topInset: 10)
        snow.syncSurfaces([tooNarrow])
        try require(festive.place(at: CGPoint(x: 20, y: 40), displayFrame: display, snow: snow) == nil, "An empty flat edge cannot hold a tree")
    }

    private static func randomPlacement() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_600, height: 500)
        let snow = configured([floor(width: 1_600)]), festive = FestiveWorld()
        var generator = SeededGenerator()
        let first = festive.scatter(in: frame, snow: snow, using: &generator)
        try require(first.trees == 3 && first.snowmen == 2 && snow.balls.count == 6 && snow.snowmen.count == 2,
                    "A free floor gets visible trees and complete snowmen immediately")
        let trees = festive.placements(in: snow)
        let existing = snow.balls.map(\.id)
        try require(trees.allSatisfy { frame.contains($0.bounds) }
                    && snow.balls.allSatisfy { frame.contains($0.position) }, "Every object stays on the chosen display")
        for _ in 0..<20 { snow.step(delta: 0.1, weather: SnowWeather(), activeRegions: [frame]) }
        try require(snow.snowmen.count == 2 && snow.balls.map(\.id) == existing,
                    "Generated snowmen remain ordinary stable snowballs during simulation")
        let head = snow.balls.first { $0.id == snow.snowmen[0].ballIDs[2] }!
        try require(snow.beginDrag(at: head.position) == head.id, "A generated snowman can be taken apart")
        snow.endDrag()
        for _ in 0..<12 { _ = festive.scatter(in: frame, snow: snow, using: &generator) }
        try require(festive.placements(in: snow).count <= 8 && snow.balls.count <= 30
                    && existing.allSatisfy { id in snow.balls.contains { $0.id == id } },
                    "Repeated placement respects limits and preserves existing objects")
        var blocked = floor(width: 1_600)
        blocked.occluders = [frame]
        let covered = configured([blocked]), blockedFestive = FestiveWorld()
        let none = blockedFestive.scatter(in: frame, snow: covered, using: &generator)
        try require(none.trees == 0 && none.snowmen == 0 && covered.balls.isEmpty,
                    "Covered areas cannot receive objects")
    }

    static func main() throws {
        try options()
        try placementAndSnow()
        try limitsAndRemoval()
        try movingAndHiddenSupports()
        try masksAndHitOrder()
        try decorationMaskRegressions()
        try displayAndInvalidInput()
        try randomPlacement()
        print("FestiveWorld: 8 scenarios, \(checks) checks passed")
    }
}
