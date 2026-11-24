import Foundation

@main @MainActor private struct SearchInputChecks {
    @MainActor private final class QueryTarget {
        var query: String
        var commits: [String] = []
        init(_ query: String = "") { self.query = query }
        func commit(_ query: String) { self.query = query; commits.append(query) }
    }
    @MainActor private final class WeakQueryTarget {
        weak var value: QueryTarget?
        init(_ value: QueryTarget) { self.value = value }
    }
    private enum Failure: Error { case check(String) }
    private static var passed = 0

    static func main() async {
        do {
            try await run()
            print("Search input checks: \(passed) passed")
        } catch { print("FAIL \(error)"); exit(1) }
    }

    private static func run() async throws {
        let input = SearchInputCoordinator()
        let target = QueryTarget()
        for text in ["C", "Cl", "Clo", "Cloud", "Cloud-", "Cloud-001"] {
            input.edit(text, currentQuery: target.query) { [weak target] query in target?.commit(query) }
            try check(input.text == text, "编辑态文本立即保留完整输入：\(text)")
        }
        try check(target.commits.isEmpty, "连续输入时不立即提交中间查询")
        try await Task.sleep(for: .milliseconds(260))
        try check(target.commits == ["Cloud-001"], "连续输入仅在停输后提交最后一个完整查询")
        try check(!input.externalQueryChanged(target.query), "自己的提交回流不覆盖输入状态")

        input.edit("pending", currentQuery: target.query) { [weak target] query in target?.commit(query) }
        input.clear(currentQuery: target.query) { [weak target] query in target?.commit(query) }
        try check(target.query.isEmpty && input.text.isEmpty, "清除按钮立即清空查询和编辑态文本")
        let clearedCommits = target.commits
        try await Task.sleep(for: .milliseconds(260))
        try check(target.commits == clearedCommits, "清除后旧输入任务不会回填查询")
        _ = input.externalQueryChanged(target.query)

        input.edit("stale", currentQuery: target.query) { [weak target] query in target?.commit(query) }
        target.query = "External Album"
        try check(input.externalQueryChanged(target.query) && input.text == target.query, "外部查询变化立即同步同一编辑态对象")
        let beforeExternal = target.commits
        try await Task.sleep(for: .milliseconds(260))
        try check(target.query == "External Album" && target.commits == beforeExternal,
                  "外部查询取消旧输入，不被延迟任务覆盖")

        target.query = ""; _ = input.externalQueryChanged("")
        input.edit("A", currentQuery: target.query) { [weak target] query in target?.commit(query) }
        try await Task.sleep(for: .milliseconds(260))
        input.edit("AB", currentQuery: target.query) { [weak target] query in target?.commit(query) }
        try check(!input.externalQueryChanged("A") && input.text == "AB", "旧提交回流不会覆盖或取消更晚的用户输入")
        try await Task.sleep(for: .milliseconds(260))
        try check(target.query == "AB", "提交回流和新输入交错时仍保留最新文本")
        _ = input.externalQueryChanged(target.query)

        input.edit("disappeared", currentQuery: target.query) { [weak target] query in target?.commit(query) }
        input.cancel()
        let beforeCancel = target.commits
        try await Task.sleep(for: .milliseconds(260))
        try check(target.commits == beforeCancel, "界面离开取消未提交输入")

        input.edit(target.query, currentQuery: target.query) { [weak target] query in target?.commit(query) }
        try await Task.sleep(for: .milliseconds(260))
        try check(target.commits == beforeCancel, "相同查询不重复触发提交")
        input.edit("", currentQuery: target.query) { [weak target] query in target?.commit(query) }
        try check(target.query.isEmpty, "键盘删空输入时立即解除搜索")
        input.cancel()

        target.query = "Local-"; _ = input.externalQueryChanged(target.query)
        input.clear(currentQuery: target.query) { [weak target] query in target?.commit(query) }
        for text in ["C", "Cl", "Cloud", "Cloud-", "Cloud-0", "Cloud-001"] {
            input.edit(text, currentQuery: target.query) { [weak target] query in target?.commit(query) }
        }
        _ = input.externalQueryChanged("")
        try check(input.text == "Cloud-001", "清除Local后旧清除回流不抹掉Cloud前缀")
        try await Task.sleep(for: .milliseconds(260))
        try check(target.query == "Cloud-001" && input.text == "Cloud-001", "清除后继续输入的完整查询同时保留于编辑态与提交态")
        input.cancel()

        var released: QueryTarget? = QueryTarget()
        let weakTarget = WeakQueryTarget(released!)
        input.edit("late", currentQuery: "") { [weak released] query in released?.commit(query) }
        released = nil
        try check(weakTarget.value == nil, "延迟提交闭包可以弱持有查询目标，不延长其生命周期")
        input.cancel()
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
        passed += 1
        print("PASS \(message)")
    }
}
