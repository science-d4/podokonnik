import AppKit

@main
enum PodokonnikMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationController()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
