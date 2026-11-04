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
testOrbFreePosition()
testGlassAppearance()
testSpan()
    testOrbMotion()
    testPriorityBreakdown()

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
    // 留白要够：窗口必须能完整容纳阴影，否则边缘会被切出方形暗边
    check(OrbMetrics.bleed >= 12, "窗口每边留白至少要盖住阴影扩散半径")
    check(OrbMetrics.size - OrbMetrics.bubble == OrbMetrics.bleed * 2, "留白应左右对称")

    // 默认位置：球应完全落在可见区内
    let visible = NSRect(x: 0, y: 82, width: 1470, height: 841)
    let size = NSSize(width: OrbMetrics.size, height: OrbMetrics.size)
    let origin = NSPoint(x: visible.maxX - size.width - OrbMetrics.snapInset,
                         y: visible.maxY - size.height - OrbMetrics.snapInset - 40)
    let rect = NSRect(origin: origin, size: size)
    check(visible.contains(rect), "默认位置应完整落在可见区内")

    // 越界的旧坐标必须被拒绝（拔掉副屏后残留的 x=1605）
    let stale = NSRect(x: 1605, y: 819, width: size.width, height: size.height)
    check(!visible.contains(stale), "越界坐标应被判定为不可用")
}

// MARK: - 数据损坏保护

/// 悬浮球吸入曲线。
///
/// 这条曲线决定"球是被吸进去的还是被掐掉的"，参数很敏感：
/// 峰值调没了就变成单纯缩小，收得不够就看着像卡住。
func testOrbMotion() {
    // 端点
    check(abs(OrbMotion.scale(for: 0) - 1.0) < 0.0001, "吸入进度 0 时缩放应为 1")
    check(OrbMotion.scale(for: 1) < 0.5, "吸入完成时应明显缩小，而不是停在半路")
    check(OrbMotion.scale(for: 1) > 0.3, "也不能缩到看不见，得保留一点形体的记忆")

    // 峰值：中段必须先超过 1（鼓起来），这是"灵动"的来源
    let peakScale = OrbMotion.scale(for: OrbMotion.peak)
    check(peakScale > 1.02, "峰值处应大于常态（鼓起），否则就是单纯缩小")
    check(peakScale > OrbMotion.scale(for: 0.1), "0.1 处还没到峰，应该比峰值小")
    check(peakScale > OrbMotion.scale(for: 0.7), "越过峰后应该回落")

    // 单调性：过了峰值一路收，不能反弹
    var previous = OrbMotion.scale(for: OrbMotion.peak)
    var monotonic = true
    for i in stride(from: Int(OrbMotion.peak * 100) + 5, through: 100, by: 5) {
        let s = OrbMotion.scale(for: CGFloat(i) / 100)
        if s > previous + 0.0001 { monotonic = false; break }
        previous = s
    }
    check(monotonic, "过了峰值之后应单调收缩，不能来回弹")

    // 透明度：单调下降，且不归零
    check(abs(OrbMotion.opacity(for: 0) - 1.0) < 0.0001, "常态应完全不透明")
    check(OrbMotion.opacity(for: 1) > 0.0, "淡出不该归零，否则窗口可能被判为不可见")
    check(OrbMotion.opacity(for: 1) < 0.1, "但也要接近全透明，否则看着像没收进去")
    check(OrbMotion.opacity(for: 0.5) < OrbMotion.opacity(for: 0.2), "透明度应随进度单调下降")

    // 越界钳制：外部传入异常值不能算出离谱的形变
    check(abs(OrbMotion.scale(for: -1) - 1.0) < 0.0001, "负进度应钳到 0")
    check(OrbMotion.scale(for: 2) < 0.6, "超过 1 的进度应钳到 1 的效果")
    check(abs(OrbMotion.opacity(for: -1) - 1.0) < 0.0001, "负进度的透明度应为 1")
}

@MainActor

/// 悬浮球的分档统计。
///
/// 口径错了不会崩，只会安静地骗人：球上写 3，用户以为是 3 件事，
/// 实际可能把已完成的也算进去了。
func testPriorityBreakdown() {
    let today = DateKey.today

    // 全空
    let empty = PriorityBreakdown.of([])
    check(empty.total == 0, "空列表总数为 0")
    check(empty.nonEmpty.isEmpty, "空列表不该有非空档")

    var items: [Memo] = [
        Memo.make(title: "A", priority: .urgent, dueDate: today),
        Memo.make(title: "B", priority: .urgent, dueDate: today),
        Memo.make(title: "C", priority: .high, dueDate: today),
        Memo.make(title: "D", priority: .normal, dueDate: today),
        Memo.make(title: "E", priority: .normal, dueDate: today),
        Memo.make(title: "F", priority: .normal, dueDate: today),
    ]
    // 已完成的不该计入——这是最容易写错的一处
    var finished = Memo.make(title: "G", priority: .low, dueDate: today)
    finished.done = true
    items.append(finished)

    let b = PriorityBreakdown.of(items)
    check(b.urgent == 2, "紧急应计 2")
    check(b.high == 1, "高应计 1")
    check(b.normal == 3, "普通应计 3")
    check(b.low == 0, "已完成的不计入，低应为 0")
    check(b.total == 6, "总数应只含未完成的 6 件")
    check(b.total == b.urgent + b.high + b.normal + b.low, "总应等于各档之和")

    // 非空档位按紧急程度降序，空档位不出现
    let ne = b.nonEmpty
    check(ne.count == 3, "只有 3 个非空档")
    check(ne.map(\.priority) == [.urgent, .high, .normal], "应按紧急程度从高到低排列")
    check(!ne.contains { $0.priority == .low }, "空的低档不该出现在列表里")

    // 只有一档时也只出这一档
    let single = PriorityBreakdown.of([Memo.make(title: "H", priority: .low, dueDate: today)])
    check(single.nonEmpty.count == 1, "只有一个低档时应只返回一项")
    check(single.nonEmpty.first?.priority == .low, "那一项应是最低优先")
    check(single.total == 1, "总数应为 1")
}

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

/// 悬浮球位置：不再吸附边缘，但必须留在可见区内。
/// 这是纯几何，出错代价是「球丢了抓不回来」，必须覆盖。

func testOrbFreePosition() {
    let size = CGSize(width: 80, height: 80)
    // 模拟主屏 1470x956，可见区 y 从 78 到 923（上方菜单栏、下方 Dock）
    let main = CGRect(x: 0, y: 78, width: 1470, height: 845)
    let screens = [main]

    // 1. 屏幕正中央 → 原样保留（这是"自由摆放"的核心要求）
    let center = CGPoint(x: 600, y: 400)
    check(OrbLayout.clamp(origin: center, size: size, screens: screens) == center,
          "屏幕中间的位置必须原样保留")

    // 2. 不再被吸附到左右边缘
    let nearLeft = CGPoint(x: 40, y: 400)
    check(OrbLayout.clamp(origin: nearLeft, size: size, screens: screens).x == 40,
          "靠近左边缘但不越界时，不应被吸到边缘")

    let nearRight = CGPoint(x: 1300, y: 400)
    check(OrbLayout.clamp(origin: nearRight, size: size, screens: screens).x == 1300,
          "靠近右边缘但不越界时，不应被吸到边缘")

    // 3. 越界必须拉回来（否则球会跑到屏幕外）
    let offLeft = CGPoint(x: -200, y: 400)
    check(OrbLayout.clamp(origin: offLeft, size: size, screens: screens).x == 0,
          "跑出左边界要被拉回")

    let offRight = CGPoint(x: 2000, y: 400)
    let clampedRight = OrbLayout.clamp(origin: offRight, size: size, screens: screens)
    check(clampedRight.x == 1470 - 80, "跑出右边界要被拉回到刚好贴边")

    let offBottom = CGPoint(x: 600, y: -500)
    check(OrbLayout.clamp(origin: offBottom, size: size, screens: screens).y == 78,
          "跑到 Dock 区域下要被拉回可见区")

    let offTop = CGPoint(x: 600, y: 2000)
    let clampedTop = OrbLayout.clamp(origin: offTop, size: size, screens: screens)
    check(clampedTop.y == 845 + 78 - 80, "跑到菜单栏上方要被拉回")

    // 4. 多屏：球中心在副屏上时应留在副屏，而不是被拽回主屏
    let secondary = CGRect(x: -251, y: 956, width: 1920, height: 1080)
    let twoScreens = [main, secondary]
    let onSecondary = CGPoint(x: 100, y: 1500)
    check(OrbLayout.clamp(origin: onSecondary, size: size, screens: twoScreens) == onSecondary,
          "在多块屏幕之间应能自由移动，不被拽回主屏")

    // 5. 空屏幕列表不应崩溃（极端兜底）
    let safe = OrbLayout.clamp(origin: center, size: size, screens: [])
    check(safe == center, "没有屏幕信息时原样返回，不崩溃")
}


/// 玻璃强度的参数映射。
///
/// 这段逻辑最容易出的错是「方向反了」——用户往右拖本意是更透，
/// 结果材质 alpha 跟着变大反而更实。肉眼很难分辨，但用户会觉得滑杆没用。
func testGlassAppearance() {
    // 方向：强度越高，alpha 越低（alpha 低 = 更透）
    let low = GlassAppearance.materialAlpha(for: 0.0)
    let mid = GlassAppearance.materialAlpha(for: 0.5)
    let high = GlassAppearance.materialAlpha(for: 1.0)
    check(low > mid && mid > high, "强度越大，材质 alpha 应越小（更透）")
    check(low == 1.0, "强度 0 应完全不透（alpha = 1）")
    check(high > 0.3, "最透也不能到 0，否则模糊会消失只剩灰雾")

    // 着色层：越透，遮得越少
    check(GlassAppearance.veilOpacity(for: 0) > GlassAppearance.veilOpacity(for: 1),
          "越透的玻璃，着色层应越淡")

    // 球的材质：同样单调递减
    check(GlassAppearance.orbMaterialOpacity(for: 0) > GlassAppearance.orbMaterialOpacity(for: 1),
          "球在更透的强度下材质应更薄")

    // 实测锚点：球心 alpha 应随强度单调下降，且两端差异要足够明显
    //
    // 这一条是为了防"调了参数但用户看不出变化"——
    // 之前底衬权重过大，实测 alpha 只从 1.00 走到 0.80，滑杆几乎无效。
    let orbAlpha = { (s: Double) -> Double in
        let solid = GlassAppearance.orbSolidOpacity(for: s)
        let mat = GlassAppearance.orbMaterialOpacity(for: s)
        return 1 - (1 - solid) * (1 - mat)
    }
    check(orbAlpha(0) > 0.95, "强度 0 时球应近乎不透明，保证清晰可辨")
    check(orbAlpha(1) < 0.72, "强度 1 时球要明显透光，否则滑杆形同虚设")
    check(orbAlpha(0) - orbAlpha(1) > 0.3, "两端透光差应足够大，用户能一眼看出区别")
    check(orbAlpha(0.5) < orbAlpha(0) && orbAlpha(0.5) > orbAlpha(1), "中间档应落在两端之间")

    // 底衬在高强度下必须完全让位，否则会把透光堵回去
    check(GlassAppearance.orbSolidOpacity(for: 1) < 0.02, "最高强度时底衬应几乎退出")

    // 球的边缘高光：越透越需要轮廓，方向相反
    check(GlassAppearance.orbRimOpacity(for: 1) > GlassAppearance.orbRimOpacity(for: 0),
          "玻璃越透，边缘高光越要强，否则球会化进背景")

    // 越界钳制：外部传进任何值都不能把参数带飞
    check(GlassAppearance.materialAlpha(for: -5) == 1.0, "负强度按 0 处理")
    check(GlassAppearance.materialAlpha(for: 9) == GlassAppearance.materialAlpha(for: 1.0),
          "超过 1 的强度按 1 处理")

    // 档位名：单调，且两端有区分
    check(GlassAppearance.label(for: 0.05) == "几乎不透明", "低强度档位名")
    check(GlassAppearance.label(for: 0.95) == "极透", "高强度档位名")
    check(GlassAppearance.defaultStrength > 0 && GlassAppearance.defaultStrength < 1,
          "默认值应在两端之间")

    // 默认值应落在「标准」区间，避免一上来就极端
    check(GlassAppearance.label(for: GlassAppearance.defaultStrength) == "标准",
          "默认强度应落在标准档")
}

/// 工期（span）语义。
///
/// 这是数据模型改动，出错会让「该逾期的不逾期」或「不该逾期的提前报红」，
/// 用户会直接失去对提醒的信任，所以逐条钉住。
@MainActor
func testSpan() {
    let today = DateKey.today
    let yesterday = DateKey.add(days: -1, to: today)
    let twoAgo = DateKey.add(days: -2, to: today)
    let threeAgo = DateKey.add(days: -3, to: today)

    // 默认 1 天，行为与改造前一致
    let single = Memo.make(title: "A", priority: .normal, dueDate: today)
    check(single.spanDays == 1, "默认工期为 1 天")
    check(single.endDate == today, "1 天工期：结束日 = 起始日")
    check(!single.isMultiDay, "1 天工期不算多天")

    // 老数据兼容：span 为 nil 时按 1 天算，不能崩也不能当成 0
    var legacy = Memo.make(title: "B", priority: .normal, dueDate: today)
    legacy.span = nil
    check(legacy.spanDays == 1, "老数据没有 span 字段时按 1 天处理")

    // 工期 3 天：前两天不该逾期
    let s3 = Memo.make(title: "C", priority: .normal, dueDate: twoAgo, span: 3)
    check(s3.spanDays == 3, "工期为 3")
    check(s3.isMultiDay, "3 天应被标记为多天")
    check(s3.endDate == today, "前天开始 + 3 天 → 今天结束")
    check(!s3.dueLabel.isOverdue, "★ 3 天工期的最后一天不该算逾期")

    // 超过工期才逾期，且逾期天数从结束日算
    let late = Memo.make(title: "D", priority: .normal, dueDate: threeAgo, span: 3)
    check(late.endDate == yesterday, "3 天前开始 + 3 天 → 昨天结束")
    check(late.dueLabel.isOverdue, "超过工期后应逾期")
    check(late.dueLabel.text == "逾期 1 天", "逾期天数按结束日算，不是起始日")

    // 边界：非法值要被钳住
    let zero = Memo.make(title: "E", priority: .normal, dueDate: today, span: 0)
    check(zero.spanDays == 1, "工期 0 应被钳成 1 天")
    let negative = Memo.make(title: "F", priority: .normal, dueDate: today, span: -5)
    check(negative.spanDays == 1, "负工期应被钳成 1 天")

    // 日期加法要跨月正确（用 Calendar，不是加秒数）
    check(DateKey.add(days: 1, to: "2026-01-31") == "2026-02-01", "跨月加一天")
    check(DateKey.add(days: 1, to: "2026-12-31") == "2027-01-01", "跨年加一天")
    check(DateKey.add(days: -1, to: "2026-03-01") == "2026-02-28", "跨月减一天")
    check(DateKey.add(days: 0, to: today) == today, "加 0 天不变")

    // store 层：setSpan 要写进数据
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("span-\(UUID().uuidString).json")
    let store = MemoStore(fileURL: tmp)
    if let added = store.add(title: "测试", priority: .normal, dueDate: today, span: 5) {
        check(store.items.first { $0.id == added.id }?.spanDays == 5, "add 应保存工期")
        store.setSpan(added.id, to: 2)
        check(store.items.first { $0.id == added.id }?.spanDays == 2, "setSpan 应更新工期")
        store.setSpan(added.id, to: 0)
        check(store.items.first { $0.id == added.id }?.spanDays == 1, "setSpan 应钳住非法值")
    } else {
        check(false, "add 应成功")
    }
    try? FileManager.default.removeItem(at: tmp)




}
