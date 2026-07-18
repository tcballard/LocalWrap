import AppKit

struct DirectoryPickerService {
    let chooseRepository: @MainActor () -> URL?

    @MainActor
    func choose() -> URL? {
        chooseRepository()
    }

    static let live = DirectoryPickerService {
        let panel = NSOpenPanel()
        panel.title = "Open Repository"
        panel.message = "Choose a repository to inspect. LocalWrap will not run anything yet."
        panel.prompt = "Review Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
