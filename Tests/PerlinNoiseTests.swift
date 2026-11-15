import Foundation
import CoreGraphics

@main
enum PerlinNoiseTests {
    private static var checks = 0
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        checks += 1
    }

    static func main() {
        // These exact binary fractions distinguish gradient dot products and
        // quintic interpolation from value noise, cubic fade or sinusoidal waves.
        check(SnowHeightEnvelope.noise(at: 0.25, seed: 42) == 0.3017578125, "gradient/quintic reference sample")
        check(SnowHeightEnvelope.noise(at: 0.75, seed: 0) == -0.146484375, "equal-gradient reference sample")
        check(SnowHeightEnvelope.noise(at: -1.75, seed: 123) == -0.146484375, "negative lattice reference sample")
        for cell in -30...30 {
            let x = Double(cell), epsilon = 0.0001
            let center = SnowHeightEnvelope.noise(at: x, seed: 42)
            let left = SnowHeightEnvelope.noise(at: x - epsilon, seed: 42)
            let right = SnowHeightEnvelope.noise(at: x + epsilon, seed: 42)
            check(center == 0, "gradient noise is zero at every lattice point")
            check(abs((center - left) / epsilon - (right - center) / epsilon) < 0.00001,
                  "first derivative must join continuously across lattice boundaries")
            check(abs((left - 2 * center + right) / (epsilon * epsilon)) < 0.01,
                  "quintic fade gives a continuous zero second derivative at the lattice")
        }
        let envelope = SnowHeightEnvelope(surfaceID: "window:123:456")
        let same = SnowHeightEnvelope(surfaceID: "window:123:456")
        let other = SnowHeightEnvelope(surfaceID: "window:123:457")
        var heights: [CGFloat] = []
        var differs = false
        for index in -1000...2000 {
            let x = CGFloat(index) * 1.25
            let value = envelope.height(atLocalX: x)
            check(value.isFinite && value >= 14 && value <= 28, "envelope must remain finite in 14...28 points")
            check(value == same.height(atLocalX: x), "equal IDs and coordinates are deterministic")
            check(abs(value - envelope.height(atLocalX: x + 4)) < 2.6, "natural cap must remain smoother than the allowed snow slope")
            differs = differs || value != other.height(atLocalX: x)
            heights.append(value)
        }
        check(differs, "distinct support IDs need independent patterns")
        check(heights.max()! - heights.min()! > 6, "multiple octaves must retain visible hills")
        check(envelope.height(atLocalX: .nan).isFinite && envelope.height(atLocalX: .infinity).isFinite,
              "invalid coordinates cannot leak NaN into profile limits")
        let samples = envelope.samples(width: 403, count: 102)
        check(samples.last == envelope.height(atLocalX: 403), "the final shortened grid cell uses the actual width")
        let window = SnowSurface(id: "window:123:456", frame: CGRect(x: 100, y: 30, width: 800, height: 68), kind: .window)
        var dock = window; dock.kind = .dock
        let windowLimits = SnowHeightEnvelope.samples(for: window, count: 201)
        let dockLimits = SnowHeightEnvelope.samples(for: dock, count: 201)
        for index in dockLimits.indices {
            check(dockLimits[index] >= 11 && dockLimits[index] <= 22, "Dock cap stays within the smaller 11...22 pt envelope")
            check(abs(windowLimits[index] * 22 / 28 - dockLimits[index]) < 0.00001,
                  "Dock retains its uneven pattern with a lower amplitude")
            check(windowLimits[index] == envelope.height(atLocalX: CGFloat(index) * 4), "Window limits are unchanged")
        }
        check(dockLimits.max()! - dockLimits.min()! > 3, "Reduced Dock still has visible hills")
        let floor = SnowSurface(id: "floor", frame: CGRect(x: -800, y: 0, width: 800, height: 1), kind: .floor)
        let floorLimits = SnowHeightEnvelope.samples(for: floor, count: 201)
        let floorEnvelope = SnowHeightEnvelope(surfaceID: "snezhno:continuous-floor")
        check(floorLimits == (0...200).map { floorEnvelope.height(atLocalX: -800 + CGFloat($0) * 4) },
              "Floor retains its world-coordinate envelope and height")
        print("PerlinNoiseTests: \(checks) checks passed")
    }
}
