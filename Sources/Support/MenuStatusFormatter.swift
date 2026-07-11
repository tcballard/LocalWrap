enum MenuStatusFormatter {
    static func summary(running: Int, saved: Int) -> String {
        "\(compactCount(running)) running / \(compactCount(saved)) saved"
    }

    private static func compactCount(_ value: Int) -> String {
        let normalized = max(0, value)
        return normalized > 999 ? "999+" : String(normalized)
    }
}

