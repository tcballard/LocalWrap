import Foundation

struct WorkspaceGraph: Sendable {
    func stableTopologicalOrder(_ projects: [Project]) -> [Project] {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var permanent = Set<String>()
        var temporary = Set<String>()
        var result: [Project] = []

        func visit(_ project: Project) {
            guard !permanent.contains(project.id), !temporary.contains(project.id) else { return }
            temporary.insert(project.id)
            for dependencyID in unique(project.dependsOn ?? []) {
                if let dependency = byID[dependencyID] { visit(dependency) }
            }
            temporary.remove(project.id)
            permanent.insert(project.id)
            result.append(project)
        }
        for project in projects { visit(project) }
        return result
    }

    func cycleProjectIDs(_ projects: [Project]) -> Set<String> {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var visited = Set<String>()
        var visiting = Set<String>()
        var cycles = Set<String>()

        func visit(_ project: Project, stack: [String]) {
            if visiting.contains(project.id) {
                if let start = stack.firstIndex(of: project.id) {
                    cycles.formUnion(stack[start...])
                } else {
                    cycles.insert(project.id)
                }
                return
            }
            guard !visited.contains(project.id) else { return }
            visiting.insert(project.id)
            for dependencyID in unique(project.dependsOn ?? []) {
                if let dependency = byID[dependencyID] {
                    visit(dependency, stack: stack + [project.id])
                }
            }
            visiting.remove(project.id)
            visited.insert(project.id)
        }
        for project in projects { visit(project, stack: []) }
        return cycles
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
