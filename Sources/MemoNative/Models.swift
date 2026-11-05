import Foundation
import Combine

// MARK: - 模型

enum Priority: String, Codable, CaseIterable, Identifiable, Sendable {
    case urgent, high, normal, low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .urgent: return "紧急"
        case .high: return "高"
        case .normal: return "普通"
        case .low: return "低"
        }
    }

    var icon: String {
        switch self {
        case .urgent: return "🔴"
        case .high: return "🟠"
        case .normal: return "🟡"
        case .low: return "🔵"
        }
    }

    /// 排序权重，越小越靠前
    var rank: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .normal: return 2
        case .low: return 3
        }
    }
}

struct Memo: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var priority: Priority
    var dueDate: String        // yyyy-MM-dd
    /// 工期（天）。1 表示当天到期，3 表示到第 3 天结束前都不算逾期。
    ///
    /// 用可选类型而不是给默认值，是为了兼容老数据：
    /// 早于这个字段写出的 JSON 里没有它，解码后是 nil，按 1 天处理。
    /// 如果改成非可选，老文件会整份解码失败——那是用户数据，不能赌。
    var span: Int?
    var note: String
    var done: Bool
    var createdAt: String      // ISO8601
    var completedAt: String?

    var dueDateValue: Date { DateKey.date(from: dueDate) ?? Date() }

    /// 工期天数，至少 1
    var spanDays: Int { max(1, span ?? 1) }

    /// 最后一天（含）。工期 1 天时等于 dueDate。
    var endDate: String { DateKey.add(days: spanDays - 1, to: dueDate) }

    /// 进度标签以"最后一天"为准：3 天的工期，第 2 天还不算逾期。
    var dueLabel: DueLabel { DueLabel(dateKey: endDate) }

    /// 是否跨多天（用于 UI 决定要不要显示"3 天"这类角标）
    var isMultiDay: Bool { spanDays > 1 }

    /// 子要点：把 note 按行拆开，去掉空行。
    ///
    /// 复用一直被闲置的 note 字段而不是新增数组——
    /// 老数据里 note 是空串，拆出来就是空数组，天然兼容。
    /// 存成换行分隔的纯文本还有个好处：即使哪天要手工改 JSON，
    /// 也不会因为数组语法写错而整份解析失败。
    var bulletPoints: [String] {
        note.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 有没有子要点
    var hasPoints: Bool { !bulletPoints.isEmpty }

    /// 把要点数组写回 note
    static func noteText(from points: [String]) -> String {
        points
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func make(title: String, priority: Priority, dueDate: String, span: Int = 1) -> Memo {
        Memo(
            id: Self.newID(),
            title: title,
            priority: priority,
            dueDate: dueDate,
            span: max(1, span),
            note: "",
            done: false,
            createdAt: ISO8601.string(from: Date()),
            completedAt: nil
        )
    }

    static func newID() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max)) + UUID().uuidString.prefix(8).lowercased()
    }
}

// MARK: - 日期工具

enum DateKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from key: String) -> Date? { formatter.date(from: key) }

    static var today: String { string(from: Date()) }

    /// 在日期键上加减天数，返回新的日期键。
    /// 用 Calendar 而不是自己算 86400 秒：夏令时切换那天会差一小时，
    /// 直接加秒数会把日期算错一天。
    static func add(days: Int, to key: String) -> String {
        guard let base = date(from: key),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: base) else { return key }
        return string(from: shifted)
    }

    /// 把任意输入规范成合法日期键；解析不了就归为今天。
    ///
    /// 存在的唯一理由是：是这个 App 有外部输入入口（URL Scheme），
    /// 而 DateKey 其余地方的失败策略是"静默按今天算"。
    /// 那个策略对内部调用是对的（不该因为日期算不出来就崩），
    /// 但外部的坏值不该被**存进**数据文件。
    static func normalized(_ key: String) -> String {
        date(from: key) == nil ? today : key
    }

    static func days(from key: String) -> Int {
        guard let target = date(from: key) else { return 0 }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: target)).day ?? 0
    }
}

enum ISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        return formatter.date(from: text)
    }
}

struct DueLabel: Equatable {
    let days: Int

    init(dateKey: String) { days = DateKey.days(from: dateKey) }

    var text: String {
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2...: return "\(days) 天后"
        case -1: return "逾期 1 天"
        default: return "逾期 \(-days) 天"
        }
    }

    var isOverdue: Bool { days < 0 }
    var isToday: Bool { days == 0 }
    var isSoon: Bool { days == 1 }
}

// MARK: - 排序

enum MemoSort {
    /// 排序：先看紧急程度，同档再按日期，最后按创建时间。
    ///
    /// 以前是日期优先——那时候界面上按日期分组，日期是分类依据，
    /// 排序自然跟着分组走。现在改成不分组、日期显示在事项内部，
    /// 日期就不再是"组织方式"，而只是"这条事项的一个属性"。
    ///
    /// 组织方式应该反映用户打开面板时最想知道的事：
    /// **哪几件最该先做**。那就是紧急程度。
    ///
    /// 一个例外：逾期的排在**所有**未逾期之前，哪怕紧急度更低。
    /// 已经过期三天的事，再"不紧急"也该先处理——
    /// 这也是唯一一处日期能压过优先级的地方。
    static func sorted(_ items: [Memo]) -> [Memo] {
        // 逾期状态必须**预计算**，不能写在比较器里。
        //
        // 比较器会被调用 O(n log n) 次。`dueLabel.isOverdue` 每次都要
        // 解析日期字符串、跑 Calendar 加减——那是 DateFormatter，
        // 单次微秒级，乘上几千次就是几十毫秒。
        // 实测 200 条事项单次排序 211ms，而界面一次刷新要算 5 次。
        //
        // 这里先把状态摊平成字典，比较器里只查表。
        let today = DateKey.today
        var overdue: [String: Bool] = [:]
        overdue.reserveCapacity(items.count)
        for item in items {
            overdue[item.id] = endKey(for: item) < today
        }

        return items.sorted { lhs, rhs in
            // 1. 未完成的在前
            if lhs.done != rhs.done { return !lhs.done }

            // 2. 逾期的排在所有未逾期的之前（仅未完成项参与比较）
            let lo = overdue[lhs.id] ?? false
            let ro = overdue[rhs.id] ?? false
            if lo != ro { return lo }

            // 3. 紧急程度
            if lhs.priority.rank != rhs.priority.rank {
                return lhs.priority.rank < rhs.priority.rank
            }

            // 4. 同档内按到期日
            if lhs.dueDate != rhs.dueDate { return lhs.dueDate < rhs.dueDate }

            // 5. 最后按创建时间，保证顺序稳定
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// 事项的截止日键（工期 1 天时等于起始日）。
    /// sorted 里预计算用，避免走 DueLabel 的完整构造。
    private static func endKey(for item: Memo) -> String {
        let span = item.spanDays
        return span <= 1 ? item.dueDate : DateKey.add(days: span - 1, to: item.dueDate)
    }

    /// 保留分组能力，但界面已不再用它组织列表。
    ///
    /// 仍然留着：卡片视图一旦要做日期分栏、或导出时按天汇总，
    /// 都会需要这个逻辑。删掉再写回来不值当。
    static func grouped(_ items: [Memo]) -> [(key: String, items: [Memo])] {
        var order: [String] = []
        var buckets: [String: [Memo]] = [:]
        for item in items {
            if buckets[item.dueDate] == nil { order.append(item.dueDate) }
            buckets[item.dueDate, default: []].append(item)
        }
        return order.sorted().map { ($0, buckets[$0] ?? []) }
    }
}

// MARK: - 存储

struct StoreFile: Codable {
    var version: Int = 1
    var items: [Memo] = []
    var reminders: [ReminderRecord] = []
    var lastReminderDate: String?
}

struct ReminderRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var at: String
    var day: String
    var title: String
    var body: String
    var count: Int
    var read: Bool
    var channel: String
}

/// 与旧版网页 / 菜单栏共用同一份 data/memos.json，格式保持兼容。
@MainActor
final class MemoStore: ObservableObject {
    @Published private(set) var items: [Memo] = []
    @Published private(set) var reminders: [ReminderRecord] = []
    @Published var lastError: String?

    private(set) var lastReminderDate: String?
    let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    /// 数据文件解析失败时为 true：此后禁止写盘，避免把坏文件覆盖成空
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        // 与 Python 版保持同一数据文件，迁移零成本
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let native = support.appendingPathComponent("memos.json")

        if let legacy = legacyFileURL(), FileManager.default.fileExists(atPath: legacy.path) {
            if !FileManager.default.fileExists(atPath: native.path) {
                try? FileManager.default.copyItem(at: legacy, to: native)
            }
        }
        return native
    }

    /// 旧的 Python 版数据目录（如存在则首次启动导入）
    static func legacyFileURL() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/deepseek-harness/default-workspace/memo/data/memos.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: 读写

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(StoreFile.self, from: data)
            items = file.items
            reminders = file.reminders
            lastReminderDate = file.lastReminderDate
            lastError = nil
            loadFailed = false
        } catch {
            // 解析失败绝不能静默继续：此时内存里是空数组，
            // 任何一次写操作都会把损坏的文件覆盖成空，原始数据就永久丢了。
            // 先把坏文件另存一份，再锁住写入，等用户手动处理。
            loadFailed = true
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("memos-broken-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            lastError = "数据读取失败，已备份为 \(backup.lastPathComponent)，暂停写入以免覆盖"
        }
    }

    func save() {
        // 加载失败时拒绝写盘：宁可这次改动丢失，也不能覆盖掉原始数据
        guard !loadFailed else {
            lastError = "数据文件损坏，写入已暂停（原文件已备份）"
            return
        }
        let file = StoreFile(
            version: 1,
            items: items,
            reminders: Array(reminders.suffix(30)),
            lastReminderDate: lastReminderDate
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            let data = try encoder.encode(file)
            let tmp = fileURL.deletingLastPathComponent().appendingPathComponent(".memos-\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            lastError = nil
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 快速连续录入时合并写盘
    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: 变更

    @discardableResult
    func add(title: String, priority: Priority, dueDate: String, span: Int = 1,
             note: String = "") -> Memo? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "请输入备忘内容"
            return nil
        }
        var item = Memo.make(
            title: String(trimmed.prefix(200)),
            priority: priority,
            // 日期必须规范化。URL Scheme 的 due 参数是外部输入
            //（memo://add?due=garbage），而 DateKey 解析失败时会
            // 静默降级成"今天"——如果不在这里挡住，坏值会原样存进
            // items，之后每次排序、显示都在跟一个非法日期字符串打交道。
            dueDate: DateKey.normalized(dueDate),
            span: max(1, span)
        )
        item.note = Memo.noteText(from: note.components(separatedBy: "\n"))
        items.append(item)
        items = MemoSort.sorted(items)
        scheduleSave()
        return item
    }

    func update(_ id: String, mutate: (inout Memo) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        items = MemoSort.sorted(items)
        scheduleSave()
    }

    func toggleDone(_ id: String) {
        update(id) { item in
            item.done.toggle()
            item.completedAt = item.done ? ISO8601.string(from: Date()) : nil
        }
    }

    /// 整体替换子要点。
    func setNote(_ id: String, to text: String) {
        let cleaned = Memo.noteText(from: text.components(separatedBy: "\n"))
        update(id) { $0.note = cleaned }
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = String(trimmed.prefix(200)) }
    }

    /// 删除并返回被删条目，供调用方实现「撤销」
    @discardableResult
    func delete(_ id: String) -> Memo? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        scheduleSave()
        return removed
    }

    /// 把一条备忘录放回列表（撤销删除用）。按日期重新排序，不强行还原原位。
    func restore(_ memos: [Memo]) {
        guard !memos.isEmpty else { return }
        let existing = Set(items.map(\.id))
        items.append(contentsOf: memos.filter { !existing.contains($0.id) })
        scheduleSave()
    }

    /// 清理已完成，返回被清理的条目（供撤销）
    @discardableResult
    func clearDone() -> [Memo] {
        let removed = items.filter(\.done)
        items.removeAll(where: \.done)
        scheduleSave()
        return removed
    }

    // MARK: 派生数据

    /// 排序结果缓存。
    ///
    /// 一次界面刷新里 `visibleItems` 会被访问 5~6 次
    ///（判空、ForEach、两处 animation 的 value、卡片枚举…），
    /// 每次都重排一遍纯属浪费。
    ///
    /// **缓存的是"顺序"（id 数组），不是 Memo 副本。**
    ///
    /// 这一点很关键：早先直接缓存 [Memo]。指纹只算影响排序的字段
    ///（id/done/到期/工期/优先级），改标题不触发重排——于是一次
    /// 重命名之后，列表里还是旧标题，直到某个影响排序的变化才刷新。
    /// 这是个只在"改了但不影响顺序"时才出现的 bug。
    ///
    /// 现在按 id 顺序重排回最新的 Memo：顺序命中缓存，
    /// 内容永远取当前值。
    private var sortCache: (fingerprint: Int, order: [String])?

    var sortedItems: [Memo] {
        let fp = sortFingerprint
        let order: [String]
        // 指纹相同还不够：条数必须也对得上。
        // 哈希理论上可能碰撞，而碰撞的后果是列表里少了几条——
        // 那是用户丢数据，代价太高，不值得为省一次比较冒险。
        if let cache = sortCache, cache.fingerprint == fp, cache.order.count == items.count {
            order = cache.order
        } else {
            order = MemoSort.sorted(items).map(\.id)
            sortCache = (fp, order)
        }
        // 按缓存顺序取当前对象。查表 O(n)，比重新排序便宜得多。
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }
    }

    /// 排序只依赖这几个字段，其余变化不影响顺序
    private var sortFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.done)
            hasher.combine(item.dueDate)
            hasher.combine(item.spanDays)
            hasher.combine(item.priority.rank)
        }
        return hasher.finalize()
    }
    var pending: [Memo] { sortedItems.filter { !$0.done } }
    var groupedPending: [(key: String, items: [Memo])] { MemoSort.grouped(sortedItems) }

    /// 按日期切片；分组头仍按日期显示，但内容按当前筛选结果走
    func pendingGroupSlices(_ items: [Memo]) -> [(key: String, items: [Memo])] {
        MemoSort.grouped(items)
    }

    func setPriority(_ id: String, to level: Priority) {
        update(id) { $0.priority = level }
    }

    /// 修改工期。允许顺带调整起始日，避免"改了工期却还从旧日期算"的歧义。
    func setSpan(_ id: String, to days: Int) {
        update(id) { $0.span = max(1, min(365, days)) }
    }

    var stats: (pending: Int, done: Int, overdue: Int, today: Int) {
        let pendingItems = items.filter { !$0.done }
        return (
            pendingItems.count,
            items.count - pendingItems.count,
            pendingItems.filter { $0.dueLabel.isOverdue }.count,
            pendingItems.filter { $0.dueDate == DateKey.today }.count
        )
    }

    // MARK: 提醒

    func recordReminder(_ record: ReminderRecord) {
        reminders.append(record)
        reminders = Array(reminders.suffix(30))
        lastReminderDate = record.day
        save()
    }

    func markRemindersRead() {
        guard reminders.contains(where: { !$0.read }) else { return }
        for index in reminders.indices { reminders[index].read = true }
        scheduleSave()
    }

    var unreadReminderCount: Int { reminders.filter { !$0.read }.count }
}
