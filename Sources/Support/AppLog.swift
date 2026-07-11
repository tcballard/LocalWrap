import OSLog

enum AppLog {
    private static let subsystem = "com.localwrap.app.native"

    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let windowing = Logger(subsystem: subsystem, category: "Windowing")
    static let runtime = Logger(subsystem: subsystem, category: "Runtime")
}
