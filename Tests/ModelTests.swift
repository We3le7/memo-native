import Foundation

// 轻量断言执行器：不依赖 XCTest（XCTest 需要 Xcode）
var failures = 0
func check(_ cond: Bool, _ name: String) {
    print(cond ? "  ✓ \(name)" : "  ✗ \(name)")
    if !cond { failures += 1 }
}

@MainActor
func runTests() {
print("ModelTests")
testOrbMetrics()
testCorruptedFileProtection()
testUndoDelete()

// 1. 排序：日期 → 完成态 → 优先级
let base = Memo(id: "x", title: "", priority: .normal, dueDate: "2026-11-05", note: "",
                done: false, createdAt: "2026-11-01T09:00:00+08:00", completedAt: nil)
var items: [Memo] = [
    Memo(id: "a", title: "后天-低", priority: .low, dueDate: "2026-11-06", note: "", done: false, createdAt: "2026-11-01T09:00:00+08:00", completedAt: nil),
    Memo(id: "b", title: "今天-普通", priority: .normal, dueDate: "2026-11-03", note: "", done: false, createdAt: "2026-11-01T09:00:00+08:00", completedAt: nil),
    Memo(id: "c", title: "后天-紧急", priority: .urgent, dueDate: "2026-11-06", note: "", done: false, createdAt: "2026-11-01T09:00:00+08:00", completedAt: nil),
    Memo(id: "d", title: "今天-已完成", priority: .urgent, dueDate: "2026-11-03", note: "", done: true, createdAt: "2026-11-01T09:00:00+08:00", completedAt: nil),
]
_ = base
let order = MemoSort.sorted(items).map(\.title)
check(order == ["今天-普通", "今天-已完成", "后天-紧急", "后天-低"], "排序：日期 → 完成态 → 优先级（实际：\(order)）")

// 2. 分组
let grouped = MemoSort.grouped(MemoSort.sorted(items))
check(grouped.count == 2, "分组数量为 2")
check(grouped[0].key == "2026-11-03" && grouped[1].key == "2026-11-06", "分组按日期升序")

// 3. 日期标签
let today = DateKey.today
let labelToday = DueLabel(dateKey: today)
check(labelToday.text == "今天" && labelToday.isToday, "今天的标签")
let tomorrow = DateKey.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
check(DueLabel(dateKey: tomorrow).text == "明天", "明天的标签")
let overdue = DateKey.string(from: Calendar.current.date(byAdding: .day, value: -3, to: Date())!)
let o = DueLabel(dateKey: overdue)
check(o.text == "逾期 3 天" && o.isOverdue, "逾期标签（实际：\(o.text)）")

// 4. 摘要
let pendingDigest = Digest.body(for: items.filter { !$0.done }, limit: 2)
check(pendingDigest.contains("共 3 项未完成"), "摘要头部")
check(pendingDigest.contains("另有 1 项"), "摘要截断（实际：\(pendingDigest)）")

// 5. 编码往返：与 Python 版格式兼容
let sample = Memo.make(title: "编码测试", priority: .high, dueDate: "2026-11-06")
let encoded = try! JSONEncoder().encode(sample)
let decoded = try! JSONDecoder().decode(Memo.self, from: encoded)
check(decoded.title == "编码测试" && decoded.priority == .high, "JSON 往返")
let json = String(data: encoded, encoding: .utf8)!
check(json.contains("\"priority\":\"high\"") && json.contains("\"dueDate\":\"2026-11-06\""), "字段名与 Python 版一致")

// 6. 存储层：增删改与持久化
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memo-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let storeFile = tmpDir.appendingPathComponent("memos.json")
let store = MemoStore(fileURL: storeFile)
store.add(title: "写周报", priority: .high, dueDate: "2026-11-06")
store.add(title: "买菜", priority: .normal, dueDate: today)
check(store.items.count == 2, "新增两条")
check(store.pending.count == 2, "待办数为 2")
check(store.stats.today == 1, "统计今天的待办")

let first = store.items.first!
store.toggleDone(first.id)
let doneItem = store.items.first { $0.id == first.id }
check(doneItem?.done == true && doneItem?.completedAt != nil, "标记完成并记录完成时间")
store.toggleDone(first.id)
check(store.items.first { $0.id == first.id }?.completedAt == nil, "撤销完成会清空完成时间")

// 立即写盘并重新加载，验证持久化
store.save()
let reloaded = MemoStore(fileURL: storeFile)
check(reloaded.items.count == 2, "重新加载后数量一致")
check(reloaded.reminders.isEmpty, "提醒记录初始为空")

// 提醒记录
let record = ReminderRecord(id: "r1", at: ISO8601.string(from: Date()), day: today,
                            title: "今日未完成备忘", body: "共 2 项", count: 2, read: false, channel: "test")
reloaded.recordReminder(record)
check(reloaded.unreadReminderCount == 1, "未读提醒计数为 1")
reloaded.markRemindersRead()
check(reloaded.unreadReminderCount == 0, "标记已读后计数归零")
check(reloaded.lastReminderDate == today, "记录最后提醒日期")

// 提醒记录上限 30
for n in 0..<40 {
    reloaded.recordReminder(ReminderRecord(id: "cap\(n)", at: "", day: today, title: "t", body: "", count: n, read: true, channel: "test"))
}
check(reloaded.reminders.count == 30, "提醒记录上限 30（实际 \(reloaded.reminders.count)）")

// 清理已完成
reloaded.add(title: "待完成项", priority: .low, dueDate: today)
let victim = reloaded.items.first { $0.title == "待完成项" }!
reloaded.toggleDone(victim.id)
let cleared = reloaded.clearDone()
check(cleared.count == 1, "清理已完成返回 1（实际 \(cleared.count)）")

// 空标题不落库
let before = reloaded.items.count
check(reloaded.add(title: "   ", priority: .normal, dueDate: today) == nil, "空标题被拒绝")
check(reloaded.items.count == before, "空标题不增加条目")

// MARK: - 时间与日期逻辑（新增）

// 时钟格式：24 小时制、补零
let shanghai = TimeZone(identifier: "Asia/Shanghai")!
var comps = DateComponents()
comps.year = 2026; comps.month = 11; comps.day = 3
comps.hour = 9; comps.minute = 5; comps.second = 7
var cal = Calendar(identifier: .gregorian)
cal.timeZone = shanghai
let fixed = cal.date(from: comps)!
check(UILogic.clockText(fixed, timeZone: shanghai) == "09:05:07",
      "时钟格式为 HH:mm:ss（实际 \(UILogic.clockText(fixed, timeZone: shanghai))）")

// createdAt 解析：带毫秒与不带毫秒都要能读
check(UILogic.parseISO("2026-11-03T09:05:07.123Z") != nil, "带毫秒的 ISO8601 可解析")
check(UILogic.parseISO("2026-11-03T09:05:07Z") != nil, "不带毫秒的 ISO8601 可解析")
check(UILogic.parseISO("不是时间") == nil, "非法时间返回 nil")
check(UILogic.createdTimeText("不是时间") == nil, "非法时间不显示（不崩溃）")
check(UILogic.createdTimeText("2026-11-03T01:05:07Z", timeZone: shanghai) == "09:05",
      "UTC 转本地时区正确（实际 \(UILogic.createdTimeText("2026-11-03T01:05:07Z", timeZone: shanghai) ?? "nil")）")

// 日期偏移
let uiBase = cal.date(from: comps)!
check(UILogic.dueKey(offsetDays: 0, from: uiBase, calendar: cal) == "2026-11-03", "今天偏移为 0 天")
check(UILogic.dueKey(offsetDays: 1, from: uiBase, calendar: cal) == "2026-11-04", "明天偏移为 1 天")
check(UILogic.dueKey(offsetDays: -1, from: uiBase, calendar: cal) == "2026-11-02", "昨天偏移为 -1 天")

// 相对描述
check(UILogic.relativeDayText(for: "2026-11-03", today: uiBase, calendar: cal) == "今天", "相对描述：今天")
check(UILogic.relativeDayText(for: "2026-11-04", today: uiBase, calendar: cal) == "明天", "相对描述：明天")
check(UILogic.relativeDayText(for: "2026-11-05", today: uiBase, calendar: cal) == "后天", "相对描述：后天")
check(UILogic.relativeDayText(for: "2026-11-01", today: uiBase, calendar: cal) == "已逾期 2 天", "相对描述：逾期")
check(UILogic.relativeDayText(for: "2026-11-08", today: uiBase, calendar: cal) == "5 天后", "相对描述：未来")

// 时间输入夹取
check(UILogic.parseTimeField("99", range: 0...23, fallback: 9) == 23, "小时 99 夹取为 23")
check(UILogic.parseTimeField("5", range: 0...23, fallback: 9) == 5, "单位数小时保留")
check(UILogic.parseTimeField("59", range: 0...59, fallback: 0) == 59, "分钟 59 合法")
check(UILogic.parseTimeField("", range: 0...23, fallback: 9) == 9, "空输入回退到原值")
check(UILogic.parseTimeField("abc", range: 0...23, fallback: 9) == 9, "非数字回退到原值")
check(UILogic.parseTimeField("123", range: 0...59, fallback: 0) == 12, "超过两位取前两位")
let clamped = UILogic.clampTime(hour: 30, minute: -5)
check(clamped.hour == 23 && clamped.minute == 0, "时间整体夹取正确")
check(UILogic.formatTimeUnit(7) == "07", "时间补零")

try? FileManager.default.removeItem(at: tmpDir)

print(failures == 0 ? "全部通过" : "\(failures) 项失败")
}



// MARK: - 悬浮球几何

@MainActor
func testOrbMetrics() {
    // 球的窗口尺寸必须大于可视气泡，留出阴影空间
    check(OrbMetrics.size > OrbMetrics.bubble, "球窗口应大于气泡，给阴影留空间")
    check(OrbMetrics.size - OrbMetrics.bubble >= 4, "阴影至少留 2pt 四边")
    check(OrbMetrics.gap > 0, "球与面板之间需要有间距")
    check(OrbMetrics.snapInset >= 8, "吸附边缘时不要贴死")

    // 吸附逻辑：球应完全落在可见区内
    let visible = NSRect(x: 0, y: 82, width: 1470, height: 841)
    let size = NSSize(width: OrbMetrics.size, height: OrbMetrics.size)
    var origin = NSPoint(x: visible.maxX - size.width - OrbMetrics.snapInset,
                         y: visible.maxY - size.height - OrbMetrics.snapInset - 40)
    let rect = NSRect(origin: origin, size: size)
    check(visible.contains(rect), "默认位置应完整落在可见区内")

    // 越界的旧坐标必须被拒绝（拔掉副屏后残留的 x=1605）
    let stale = NSRect(x: 1605, y: 819, width: size.width, height: size.height)
    check(!visible.contains(stale), "越界坐标应被判定为不可用")
}

// MARK: - 数据损坏保护

@MainActor
func testCorruptedFileProtection() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corrupt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("memos.json")

    // 1) 写入一个无法解析的文件
    let corrupt = "{ not json ".data(using: .utf8)!
    try? corrupt.write(to: file)

    let store = MemoStore(fileURL: file)
    check(store.lastError != nil, "损坏文件应报错")
    check(store.items.isEmpty, "损坏文件不应解析出条目")

    // 2) 备份必须生成
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
        .filter { $0.contains("broken") } ?? []
    check(!backups.isEmpty, "损坏文件应被备份")

    // 3) 关键：尝试写盘后，原始损坏文件不能被覆盖
    _ = store.add(title: "不应覆盖", priority: .normal, dueDate: DateKey.today)
    store.save()
    let after = try? Data(contentsOf: file)
    check(after == corrupt, "加载失败后禁止写盘，原文件须保持不变")

    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 撤销删除

@MainActor
func testUndoDelete() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString).json")
    let store = MemoStore(fileURL: tmp)
    let a = store.add(title: "A", priority: .urgent, dueDate: DateKey.today)!
    let b = store.add(title: "B", priority: .normal, dueDate: DateKey.today)!

    let removed = store.delete(a.id)
    check(removed?.id == a.id, "delete 返回被删条目")
    check(store.items.count == 1, "删除后剩 1 条")

    store.restore([removed!])
    check(store.items.count == 2, "撤销后恢复 2 条")
    check(store.items.contains { $0.id == a.id }, "被删条目回来")

    // 幂等：重复恢复不该产生副本
    store.restore([removed!])
    check(store.items.count == 2, "重复恢复不产生重复条目")

    // 清理已完成也支持撤销
    store.toggleDone(b.id)
    let cleared = store.clearDone()
    check(cleared.count == 1, "clearDone 返回被清理条目")
    store.restore(cleared)
    check(store.items.count == 2, "撤销清理后恢复")

    check(store.delete("不存在") == nil, "删除不存在 id 返回 nil")
}

