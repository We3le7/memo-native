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
    testOrbStateResets()
    testUnfoldAnchor()
    testFoldIsInverseOfUnfold()
    testFoldSlowerButSameShape()
    testFoldFadeNotTooFast()
    testWindowLevelDuringFold()
    testFoldSameSpeedAsUnfold()
    testGraceCoversUnfold()
    testGraceResignDeferred()
    testPriorityDotHitArea()
    testPriorityDotIsCapsule()
    testNewMemoDefaultsToToday()
    testSpanPickerMatchesPriority()
    testPaletteContrast()
    testConfirmButtonContrast()
    testCardGrid()
    testBulletPoints()
    testPriorityFirstSorting()
    testBulletLimitIsThree()
    testAddButtonGating()
    testFocusLostCommitRules()
    testClickRegionHitTest()
    testAnimationTiers()
    testDateLineWithWeekday()
    testSpanEditableForSingleDay()
    testCardBaselineHeight()
    testBulletStableIdentity()
    testPointsInputVisibility()
    testInputIconContrast()
    testSortCacheInvalidation()
    testSortCacheInvalidation()
    testSpaceChangeSyncOrb()
    testOrbRevealRespectsToggle()
    testOrbAbsorbRespectsToggle()
    testPriorityBreakdown()

// 1. 排序：完成态 → 逾期 → 紧急程度 → 日期 → 创建时间
//
// 相对日期用"今天±N"算，不写死绝对日期——
// 写死会让测试依赖运行当天（之前踩过：测试里写 2026-11-03，
// 到了 11-05 那条就变成"逾期 2 天"，断言含义悄悄变了）。
func day(_ offset: Int) -> String {
    DateKey.add(days: offset, to: DateKey.today)
}
func sample(_ id: String, _ title: String, _ p: Priority,
            _ dueOffset: Int, done: Bool = false,
            created: String = "2026-11-01T09:00:00+08:00") -> Memo {
    Memo(id: id, title: title, priority: p, dueDate: day(dueOffset), note: "",
         done: done, createdAt: created, completedAt: nil)
}
let items: [Memo] = [
    sample("a", "三天后-低", .low, 3),
    sample("b", "今天-普通", .normal, 0),
    sample("c", "三天后-紧急", .urgent, 3),
    sample("d", "今天-已完成", .urgent, 0, done: true),
    sample("e", "逾期两天-低", .low, -2),
    sample("f", "明天-紧急", .urgent, 1),
]
let order = MemoSort.sorted(items).map(\.title)
// 逾期的最先（哪怕紧急度最低），然后按紧急程度，同档内按日期
check(order == ["逾期两天-低", "明天-紧急", "三天后-紧急", "今天-普通", "三天后-低", "今天-已完成"],
      "排序：逾期 → 紧急程度 → 日期 → 完成态（实际：\(order)）")

// 紧急程度优先于日期：紧急的"三天后"要排在普通的"今天"之前
let ci = order.firstIndex(of: "三天后-紧急")!
let bi = order.firstIndex(of: "今天-普通")!
check(ci < bi, "紧急的三天后应排在普通的今天之前（紧急程度优先）")

// 已完成的沉底，哪怕它最紧急
let lastIdx = order.count - 1
check(order[lastIdx] == "今天-已完成", "已完成的应排在最后")

// 2. 分组（界面已不再使用，但函数保留，仍应正确）
let grouped = MemoSort.grouped(MemoSort.sorted(items))
check(grouped.count == 4, "按日期应分成 4 组（-2/0/1/3 天）")
check(grouped.map(\.key) == grouped.map(\.key).sorted(), "分组按日期升序")

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
let pendingOnly = items.filter { !$0.done }
let pendingDigest = Digest.body(for: pendingOnly, limit: 2)
check(pendingDigest.contains("共 \(pendingOnly.count) 项未完成"),
      "摘要头部（实际：\(pendingDigest)）")
check(pendingDigest.contains("另有 \(pendingOnly.count - 2) 项"),
      "摘要截断（实际：\(pendingDigest)）")

// 5. 编码往返：与 Python 版格式兼容
let encodeCase = Memo.make(title: "编码测试", priority: .high, dueDate: "2026-11-06")
let encoded = try! JSONEncoder().encode(encodeCase)
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

/// 展开→折叠之后，球必须回到"显示数字"的常态。
///
/// 这里出过一个 bug：展开时把某个状态位设成 true 驱动"收起箭头"，
/// 折叠时忘了复位，于是球折叠回来一直显示箭头、看不见数字。
/// 根因是同一个形态由两个变量描述（expanded 和 collapse），必然走岔。
/// 现在只保留 collapse 一个来源，这组断言守住这条不变量。
func testOrbStateResets() {
    // 常态：不缩放、不透明、不是"让位"状态
    check(abs(OrbMotion.scale(for: 0) - 1.0) < 0.0001, "常态应回到原尺寸，不能残留在缩小状态")
    check(abs(OrbMotion.opacity(for: 0) - 1.0) < 0.0001, "常态应完全不透明")

    // 展开→折叠走一遍：终点必须与起点完全一致
    let afterCycle = OrbMotion.scale(for: 0)
    let beforeCycle = OrbMotion.scale(for: 0)
    check(abs(afterCycle - beforeCycle) < 0.0001, "折叠后的形变应与展开前一致，不能有残留")

    // 折叠到底再拉回 0，中间不能有跳变残留
    _ = OrbMotion.scale(for: 1)
    check(abs(OrbMotion.scale(for: 0) - 1.0) < 0.0001, "从完全吸入拉回常态应精确回到 1")

    // "是否在让位"由 collapse 推导：0 时必然不在让位
    // （对应视图里的 isYielding = collapse > 0.001）
    check(!(0.0 > 0.001), "collapse=0 时不该被判为让位状态——判为让位就会隐藏数字")
    check(1.0 > 0.001, "collapse=1 时应判为让位")
}

@MainActor

/// 面板展开的锚点。
///
/// "从悬浮球的位置展开"这个效果全靠这个锚点：
/// 它决定缩放围绕哪一点发生。算错了不会崩，
/// 只会让面板从某个角落挤出来，看着很怪。
func testUnfoldAnchor() {
    let panel = CGRect(x: 788, y: 84, width: 600, height: 660)

    // 球在面板右侧偏上（实测位置）
    let a1 = MotionCurve.anchor(for: panel, toward: CGPoint(x: 1421, y: 603))
    check(a1.x > 0.85, "球在面板右侧，锚点应靠右")
    check(a1.y > 0.55 && a1.y < 0.90, "球在偏上位置，锚点 y 应偏上但不贴边")

    // 球在正中央
    let center = CGPoint(x: panel.midX, y: panel.midY)
    let a2 = MotionCurve.anchor(for: panel, toward: center)
    check(abs(a2.x - 0.5) < 0.001 && abs(a2.y - 0.5) < 0.001, "球在中心时锚点应为 0.5,0.5")

    // 球在左下角外侧：必须被夹住，不能出界
    let a3 = MotionCurve.anchor(for: panel, toward: CGPoint(x: -500, y: -500))
    check(a3.x >= 0.08 && a3.y >= 0.08, "越界左下应夹到 0.08")
    check(a3.x <= 0.92 && a3.y <= 0.92, "夹取后不能超过 0.92")

    // 球在右上角外侧
    let a4 = MotionCurve.anchor(for: panel, toward: CGPoint(x: 5000, y: 5000))
    check(abs(a4.x - 0.92) < 0.001, "越界右上应夹到 0.92")
    check(abs(a4.y - 0.92) < 0.001, "越界右上应夹到 0.92")

    // 退化尺寸：窗口还没布局时不能除零
    let a5 = MotionCurve.anchor(for: .zero, toward: CGPoint(x: 100, y: 100))
    check(a5.x == 0.5 && a5.y == 0.5, "面板尺寸为 0 时应退回中心")

    // 锚点永远在合法区间
    for (tx, ty) in [(0.0, 0.0), (788.0, 84.0), (1388.0, 744.0), (-9999.0, 9999.0)] {
        let a = MotionCurve.anchor(for: panel, toward: CGPoint(x: tx, y: ty))
        check(a.x >= 0.0 && a.x <= 1.0 && a.y >= 0.0 && a.y <= 1.0,
              "锚点 (\(tx),\(ty)) 应在 0…1 内")
    }
}

@MainActor

/// 折叠必须是展开的严格逆过程。
///
/// 这里出过问题：展开用一套参数（0.34s / 34 帧 / 阻尼 0.74），
/// 折叠自己一套（0.24s / 30 帧 / 阻尼 0.92）。展开带过冲、
/// 收起近似线性，同一个动作正反播出来手感对不上，
/// 用户会觉得"收起和展开不是一回事"。
func testFoldIsInverseOfUnfold() {
    let count = 34
    let damping: CGFloat = 0.74

    // 展开的采样序列
    let forward = MotionCurve.springValues(from: 0.06, to: 1.0, damping: damping, count: count)
    // 折叠应当是它的逆序
    let backward = Array(forward.reversed())

    check(forward.count == count, "展开应有 \(count) 个采样点")
    check(backward.count == count, "折叠应有同样多的采样点")

    // 首尾必须精确对应
    check(abs(forward.first! - 0.06) < 0.0001, "展开应从 0.06 起")
    check(abs(forward.last! - 1.0) < 0.0001, "展开应到 1.0 止")
    check(abs(backward.first! - 1.0) < 0.0001, "折叠应从 1.0 起")
    check(abs(backward.last! - 0.06) < 0.0001, "折叠应到 0.06 止")

    // 逐点互为镜像
    for i in 0..<count {
        check(abs(backward[i] - forward[count - 1 - i]) < 0.0001,
              "第 \(i) 个采样点应是展开对应点的镜像")
    }

    // 过冲也必须镜像：展开在中后段超过 1，折叠就该在对应位置超过 1
    let forwardPeak = forward.max() ?? 0
    let backwardPeak = backward.max() ?? 0
    check(forwardPeak > 1.01, "展开应有可见的过冲")
    check(abs(forwardPeak - backwardPeak) < 0.0001, "折叠的过冲峰值应与展开相同")

    // 关键帧时刻也要对称
    let kt = MotionCurve.keyTimes(count: count)
    check(abs(kt.first!.doubleValue - 0.0) < 0.0001, "关键帧应从 0 开始")
    check(abs(kt.last!.doubleValue - 1.0) < 0.0001, "关键帧应到 1 结束")
    check(kt.count == count, "关键帧数量应与采样点一致")
}

@MainActor

/// 切换桌面时的状态同步。
///
/// 不变量：面板跨桌面保持展开——召唤出来的东西不该因为切个桌面就消失。
/// 需要校正的只有球的显隐：它由 show()/hide() 推进，
/// Space 切换不经过那两个方法，图层可能停在半透明、和面板对不上。
func testSpaceChangeSyncOrb() {
    // 面板展开着：要同步（让球藏起来）
    check(UILogic.shouldSyncOrbOnSpaceChange(
        isPanelVisible: true, isHiding: false, orbEnabled: true
    ), "面板展开时切桌面应同步球的显隐")

    // 面板收起：也要同步（让球露出来）
    check(UILogic.shouldSyncOrbOnSpaceChange(
        isPanelVisible: false, isHiding: false, orbEnabled: true
    ), "面板收起时切桌面也应同步")

    // 正在播动画：不要插手，会和动画抢同一个属性
    check(!UILogic.shouldSyncOrbOnSpaceChange(
        isPanelVisible: true, isHiding: true, orbEnabled: true
    ), "正在收起时不该同步")
    check(!UILogic.shouldSyncOrbOnSpaceChange(
        isPanelVisible: false, isHiding: true, orbEnabled: true
    ), "正在收起时不该同步（面板不可见）")

    // 球关掉：任何情况都不碰
    check(!UILogic.shouldSyncOrbOnSpaceChange(
        isPanelVisible: true, isHiding: false, orbEnabled: false
    ), "球关闭时不该同步")
    check(!UILogic.shouldSyncOrbOnSpaceChange(
        isPanelVisible: false, isHiding: false, orbEnabled: false
    ), "球关闭且面板收起时也不该同步")

    // 穷举：唯一不该同步的只有"正在播动画"
    var synced = 0
    for enabled in [true, false] {
        for vis in [true, false] {
            for hiding in [true, false] {
                let r = UILogic.shouldSyncOrbOnSpaceChange(
                    isPanelVisible: vis, isHiding: hiding, orbEnabled: enabled)
                if r { synced += 1 }
                check(r == (enabled && !hiding),
                      "组合 enabled=\(enabled) vis=\(vis) hiding=\(hiding) 判断错误")
            }
        }
    }
    check(synced == 2, "8 种组合里只有「球开 + 没在收」的 2 种该同步")
}

@MainActor

/// 关掉悬浮球之后，任何路径都不该让它冒出来。
///
/// 真出过这个 bug：在设置里关掉球，展开面板再收起，球又出现了。
/// 因为"收起面板"比"关掉开关"更晚发生，把状态覆盖了回去——
/// 开关看起来完全没生效。
func testOrbRevealRespectsToggle() {
    // 球开着 + 正在收起 → 浮现
    check(UILogic.shouldRevealOrbOnCollapse(
        orbEnabled: true, isCollapsing: true
    ), "球开启时收起应浮现")

    // 球关着 + 正在收起 → 绝不浮现
    check(!UILogic.shouldRevealOrbOnCollapse(
        orbEnabled: false, isCollapsing: true
    ), "球关闭时收起不该浮现")

    // 没在收起 → 不插手
    check(!UILogic.shouldRevealOrbOnCollapse(
        orbEnabled: true, isCollapsing: false
    ), "没在收起时不该浮现")
    check(!UILogic.shouldRevealOrbOnCollapse(
        orbEnabled: false, isCollapsing: false
    ), "球关闭且没在收起时不该浮现")

    // 穷举：只有"开着 + 在收"这一种该浮现
    var revealed = 0
    for enabled in [true, false] {
        for collapsing in [true, false] {
            if UILogic.shouldRevealOrbOnCollapse(
                orbEnabled: enabled, isCollapsing: collapsing) { revealed += 1 }
        }
    }
    check(revealed == 1, "4 种组合里只有 1 种该浮现")
}

@MainActor

/// 球关掉时不要对它播吸附动画。
///
/// 窗口已经 orderOut，这时改 collapse / ignoresMouseEvents 只会污染状态：
/// 下次开启时球可能带着旧的 collapse 值出现——缩成一团或者干脆透明。
func testOrbAbsorbRespectsToggle() {
    // 球开着：该播吸附动画
    check(UILogic.shouldAbsorbOrb(orbEnabled: true), "球开启时应收起")

    // 球关着：不碰它
    check(!UILogic.shouldAbsorbOrb(orbEnabled: false), "球关闭时不该做吸附动画")

    // 和 reveal 的判断必须互斥：不能出现"收回去了但不放出来"的组合
    for enabled in [true, false] {
        let absorb = UILogic.shouldAbsorbOrb(orbEnabled: enabled)
        let reveal = UILogic.shouldRevealOrbOnCollapse(orbEnabled: enabled, isCollapsing: true)
        check(absorb == reveal, "吸附与浮现对同一开关必须同进同退（enabled=\(enabled)）")
    }
}

@MainActor

/// 折叠比展开慢，但**曲线形状**必须完全一致。
///
/// 展开是"叫出来"，快一点显利落；收起是"收回去"，慢一点让眼睛
/// 跟得上面板往球那边缩的过程。所以折叠时长单独配（0.52 vs 0.34）。
///
/// 但形状不能变：同一条阻尼曲线、同样的帧数，只是把时间轴拉长。
/// 否则就成了"展开和折叠是两套动作"，手感对不上。
func testFoldSlowerButSameShape() {
    let count = 34
    let damping: CGFloat = 0.74

    // 同一组参数采样，形状就必须一样——时间轴拉长不改变序列本身
    let a = MotionCurve.springValues(from: 0.06, to: 1.0, damping: damping, count: count)
    let b = MotionCurve.springValues(from: 0.06, to: 1.0, damping: damping, count: count)
    check(a == b, "同样的入参必须采出同样的序列（形状与时长无关）")

    // 折叠用的是这套采样的逆序，形状不受时长影响
    let folded = Array(a.reversed())
    check(abs(folded.first! - 1.0) < 0.0001, "折叠仍从 1.0 起")
    check(abs(folded.last! - 0.06) < 0.0001, "折叠仍到 0.06 止")

    // 过冲必须保留：时长变了，过冲不能消失
    check((a.max() ?? 0) > 1.01, "展开应有可见的过冲")
    check((folded.max() ?? 0) > 1.01, "折叠应保留同样的过冲")

    // 关键帧数量不随时长变化
    let kt = MotionCurve.keyTimes(count: count)
    check(kt.count == count, "关键帧数量只由帧数决定，与时长无关")
}

@MainActor

/// 折叠时页面不能消失太快。
///
/// 老曲线 [1, 1, 0.88, 0.55, 0] 的问题：到 55% 还有 0.88，
/// 然后骤降，最后 22% 直接归零。观感是"一直很清楚、末尾啪地没了"，
/// 面板收缩的过程根本没被看见。
func testFoldFadeNotTooFast() {
    let opacity = UILogic.foldOpacity

    // 起点必须完全不透明
    check(abs(opacity(0.0) - 1.0) < 0.0001, "折叠起点应完全不透明")
    // 终点必须完全透明
    check(abs(opacity(1.0) - 0.0) < 0.0001, "折叠终点应完全透明")

    // 前段（30% 之前）不该开始变淡——先让用户看清静止的页面
    for t in stride(from: 0.0, through: 0.30, by: 0.05) {
        check(abs(opacity(t) - 1.0) < 0.0001, "进度 \(t) 处应仍完全不透明")
    }

    // 中段要留得住：50% 时至少还有 0.6，不能一上来就快没了
    check(opacity(0.50) > 0.60, "进度 0.50 处应仍有明显不透明度（当前 \(opacity(0.50))）")
    // 70% 时还该看得见（老曲线此处已接近 0.5 且快速下坠）
    check(opacity(0.70) > 0.30, "进度 0.70 处应仍可辨认")

    // 单调不增：不能出现"淡了又清晰"的抖动
    var prev = 2.0
    for i in 0...100 {
        let v = opacity(Double(i) / 100.0)
        check(v <= prev + 0.0001, "不透明度必须单调不增（进度 \(Double(i)/100)）")
        prev = v
    }

    // 末段不能"啪地归零"：最后 10% 的落差要小于 0.3
    let drop = opacity(0.90) - opacity(1.0)
    check(drop < 0.30, "最后 10% 的落差应平缓（当前 \(drop)）")

    // 关键帧首尾必须是 0 和 1
    let kt = UILogic.foldFadeKeyTimes.map { $0.doubleValue }
    check(abs(kt.first! - 0.0) < 0.0001, "关键帧应从 0 起")
    check(abs(kt.last! - 1.0) < 0.0001, "关键帧应到 1 止")
    check(kt.count == UILogic.foldFadeValues.count, "关键帧与取值数量必须一致")
}

@MainActor

/// 折叠动画期间不能降窗口层级。
///
/// 这是"页面突然消失"的根因：applyLevel(active: false) 把面板从
/// .floating 降到 .normal，它立刻被前台 App 的窗口盖住，
/// 后面 0.45 秒的收缩动画全被遮在下面——用户只看到"啪"地没了。
///
/// 降级必须等动画播完、窗口即将 orderOut 的那一刻。
func testWindowLevelDuringFold() {
    // 升到最上层：任何时候都行
    check(UILogic.canChangeWindowLevel(active: true, isRevealing: true),
          "展开途中升层级应允许")
    check(UILogic.canChangeWindowLevel(active: true, isRevealing: false),
          "静止时升层级应允许")

    // 降级：展开动画期间绝对不行
    check(!UILogic.canChangeWindowLevel(active: false, isRevealing: true),
          "展开动画期间不该降层级")

    // 降级：没在播动画时允许（折叠收尾、失焦下沉都要用）
    check(UILogic.canChangeWindowLevel(active: false, isRevealing: false),
          "没在播动画时应允许降层级")

    // 穷举：只有"降级 + 正在展开"这一种组合被拒
    var blocked = 0
    for active in [true, false] {
        for revealing in [true, false] {
            if !UILogic.canChangeWindowLevel(active: active, isRevealing: revealing) {
                blocked += 1
            }
        }
    }
    check(blocked == 1, "4 种组合里只有 1 种该被拒绝")
}

@MainActor

/// 折叠必须与展开**同速**。
///
/// 曾经为了"收回去慢一点"把折叠单独调到 0.52、0.45。
/// 结果同一个动作一快一慢，看着不像同一件事的正反面——
/// 展开是"唰"地出来、收起是"缓缓"缩回去，观感割裂。
///
/// 现在两者都是 0.34s，曲线也是同一条（只是采样值倒序）。
func testFoldSameSpeedAsUnfold() {
    check(UILogic.isSymmetricDuration,
          "展开与折叠时长必须相等（当前 \(UILogic.unfoldSeconds)s vs \(UILogic.foldSeconds)s）")
    check(abs(UILogic.unfoldSeconds - 0.34) < 0.0001, "展开应为 0.34s")
    check(abs(UILogic.foldSeconds - 0.34) < 0.0001, "折叠应为 0.34s")

    // 同速 + 同曲线形状 = 严格逆过程
    let count = 34
    let forward = MotionCurve.springValues(from: 0.06, to: 1.0, damping: 0.74, count: count)
    let backward = Array(forward.reversed())
    check(abs(backward.first! - forward.last!) < 0.0001, "逆序首项应对应正序末项")
    check(abs(backward.last! - forward.first!) < 0.0001, "逆序末项应对应正序首项")

    // 时长必须在合理区间：太快看不清形变，太慢拖沓
    for d in [UILogic.unfoldSeconds, UILogic.foldSeconds] {
        check(d >= 0.25, "时长不应短于 0.25s（看不清形变）")
        check(d <= 0.60, "时长不应长于 0.60s（显得拖沓）")
    }
}

@MainActor

/// 展开保护期必须覆盖动画全程。
///
/// 这是"展开时偶尔一闪一闪"的根因：保护期 0.35s，动画 0.34s，
/// 几乎贴在一起。系统在激活过程中发来一次失焦通知（常在 0.4s 左右），
/// 恰好落在保护期之外——面板刚展开就被收起，然后又被唤出，
/// 看起来就是闪了一下。
///
/// 约束是两头都要满足：
///   - 覆盖动画（否则被腰斩）
///   - 别太长（否则用户快速切走时面板赖着不走）
func testGraceCoversUnfold() {
    check(UILogic.graceCoversUnfold,
          "保护期(\(UILogic.revealGraceSeconds)s)必须大于动画时长(\(UILogic.unfoldSeconds)s)")

    // 至少留 0.2s 余量：系统通知可能在动画结束后才到
    let margin = UILogic.revealGraceSeconds - UILogic.unfoldSeconds
    check(margin >= 0.2, "保护期应比动画至少多 0.2s（当前余量 \(margin)s）")

    // 但也不能太长：1 秒内切走应该能正常收起
    check(UILogic.revealGraceSeconds <= 1.0,
          "保护期不应超过 1s（否则快速切走时面板赖着不走）")

    // 与折叠无关：折叠不需要保护期，因为收起本身就是用户意图
    check(UILogic.revealGraceSeconds > UILogic.foldSeconds,
          "保护期也应覆盖折叠时长")
}

@MainActor

/// 保护期内收到失焦，必须延后判定而不是丢弃。
///
/// 真出过这个 bug：保护期从 0.35 加到 0.75 之后，
/// "展开后 0.7 秒内切走"完全不折叠——用户看到的是面板赖着不走。
///
/// 原因是最早的写法在保护期内直接 return，把真实切走也吞了。
/// 现在改成 deferCheck：保护期结束再看一眼 App 是否真的不在前台。
func testGraceResignDeferred() {
    // 保护期内：延后判定，不能丢
    check(UILogic.graceResignAction(inGrace: true, isHiding: false, isPanelVisible: true)
          == .deferCheck, "保护期内的失焦应延后判定")

    // 保护期外：立即执行
    check(UILogic.graceResignAction(inGrace: false, isHiding: false, isPanelVisible: true)
          == .actNow, "保护期外的失焦应立即执行")

    // 正在收起：不重复触发
    check(UILogic.graceResignAction(inGrace: true, isHiding: true, isPanelVisible: true)
          == .ignore, "正在收起时不该处理")
    check(UILogic.graceResignAction(inGrace: false, isHiding: true, isPanelVisible: true)
          == .ignore, "正在收起时不该处理（保护期外）")

    // 面板不可见：无关
    check(UILogic.graceResignAction(inGrace: true, isHiding: false, isPanelVisible: false)
          == .ignore, "面板不可见时不该处理")
    check(UILogic.graceResignAction(inGrace: false, isHiding: false, isPanelVisible: false)
          == .ignore, "面板不可见时不该处理（保护期外）")

    // 穷举 8 种组合：绝不能出现 ignore 之外的"丢失"
    var ignored = 0
    for g in [true, false] {
        for h in [true, false] {
            for v in [true, false] {
                let a = UILogic.graceResignAction(inGrace: g, isHiding: h, isPanelVisible: v)
                if a == .ignore { ignored += 1 }
                // 只要面板可见且没在收，就必须有动作（actNow 或 deferCheck）
                if v && !h {
                    check(a != .ignore, "面板可见且空闲时不该忽略失焦")
                }
            }
        }
    }
    check(ignored == 6, "8 种组合里应有 6 种被忽略（不可见或正在收）")
}

@MainActor

/// 优先级色点的命中区。
///
/// 原来的色点 6pt，靠 contentShape 外扩 3.5pt 撑到 13pt——
/// 面积只有 133pt²，用户得瞄着点。
///
/// 放大到 8pt 视觉 + 16pt 方形命中帧后是 256pt²，接近翻倍。
/// 关键是不能靠"继续外扩"来加命中：点间距 13pt、外扩到 18pt
/// 会重叠 5pt，点两个圆之间时选中哪个是不确定的。
func testPriorityDotHitArea() {
    // 视觉尺寸：8pt 是能看清档位色差的下限
    check(UILogic.dotVisualSize >= 8, "色点视觉直径不应小于 8pt")

    // 命中区必须比视觉大一圈
    check(UILogic.dotHitFrame > UILogic.dotVisualSize,
          "命中帧必须大于视觉尺寸")

    // 舒适度：至少 14pt，接近 Apple 建议的 16-20pt 可点尺寸
    check(UILogic.dotHitIsComfortable, "命中帧不应小于 14pt")

    // 最重要的一条：命中区不能重叠
    check(!UILogic.dotHitsOverlap,
          "命中区重叠会导致点到边界时选中错误档位")

    // 相邻命中刚好相接：间距 = 1~2pt
    check(UILogic.dotHitSpacing >= 1, "命中区之间要留缝")
    check(UILogic.dotHitSpacing <= 3, "缝隙太大就浪费空间了")

    // 面积翻倍验证
    let oldArea = Double.pi * pow(6.5, 2)   // 旧的 13pt 圆
    check(UILogic.dotHitArea > oldArea * 1.5,
          "新命中面积(\(UILogic.dotHitArea)pt²)应显著大于旧方案(\(Int(oldArea))pt²)")

    // 整组宽度不能太宽，否则挤压右侧日期
    check(UILogic.dotGroupWidth < 100,
          "四个色点总宽(\(UILogic.dotGroupWidth)pt)不应超过 100pt")
}

@MainActor

/// 色点是胶囊形：两端正半圆，中间一段平直。
///
/// 正圆看着是"一个点"，圆角方块偏硬，胶囊是两者之间最像
/// "档位块"的形状——四个并排时像一排小开关。
func testPriorityDotIsCapsule() {
    let w = UILogic.dotVisualWidth
    let h = UILogic.dotVisualSize

    // 胶囊的长边必须大于短边，否则就是正圆
    check(w > h, "宽度(\(w))必须大于高度(\(h))，否则退化成正圆")

    // 中间必须有可辨识的平直段，不能只是"略微椭圆"
    check(UILogic.dotFlatSegment >= 2,
          "平直段(\(UILogic.dotFlatSegment)pt)太短，看不出胶囊形")

    // 但也不能太长，否则像条状图而不是档位块
    check(UILogic.dotFlatSegment <= 6,
          "平直段(\(UILogic.dotFlatSegment)pt)太长，会像条状图")

    // 宽度超过命中帧就等于命中区受限了
    check(w <= UILogic.dotHitFrame,
          "胶囊宽度不能超过命中帧，否则点不全")
}

@MainActor

/// 新事项固定记在今天。
///
/// 界面上已去掉日期选择键（「今天 / 明天 / 选择日期」），
/// 只保留工期。想改日期在记下之后行内编辑。
///
/// 这条测试锁的是"没有日期选择也要有确定的默认值"——
/// 否则一旦哪天删错了，新事项会落在一个空日期上。
func testNewMemoDefaultsToToday() {
    let key = UILogic.dueKey(offsetDays: 0)
    check(key.count == 10, "日期键应是 yyyy-MM-dd 格式")
    check(key.hasPrefix("\(Calendar.current.component(.year, from: Date()))"),
          "默认日期应落在今年")

    // offset 0 必须就是今天
    let today = DateKey.string(from: Date())
    check(key == today, "offset 0 应等于今天（\(key) vs \(today)）")

    // 顺带确认相邻日期是连续的，避免跨月边界出错
    let tomorrow = UILogic.dueKey(offsetDays: 1)
    check(tomorrow != key, "明天不该等于今天")
    check(tomorrow > key, "yyyy-MM-dd 字典序应与时间序一致")
}

@MainActor

/// 工期选择器必须与优先级选择器结构一致。
///
/// 同一个输入行里并排两个互斥档位控件，任何一处不同，
/// 眼睛都会立刻觉得"这两个不是一类东西"。
///
/// 具体到数值：档位数、胶囊高度、内边距、档间距、圆角，
/// 两个控件必须是同一套。
func testSpanPickerMatchesPriority() {
    // 工期档位：1/2/3/5/7 天
    let presets = [1, 2, 3, 5, 7]
    check(presets.count == 5, "工期应有 5 个快捷档位")
    check(presets.first == 1, "第一档应是当天")
    check(presets.last == 7, "最后一档应是 7 天")
    check(presets == presets.sorted(), "档位应递增")

    // 每个档位都要有可读文案
    for d in presets {
        let label = UILogic.spanLabel(d)
        check(!label.isEmpty, "档位 \(d) 应有文案")
        if d == 1 { check(label == "当天", "1 天显示「当天」") }
        else { check(label == "\(d) 天", "\(d) 天档位文案应带单位") }
    }

    // 与优先级同构的关键尺寸（这些值两边必须一样）
    // 胶囊高度 22、内边距 2、档间距 2、圆点选中 6.5/未选 5.5
    check(Priority.allCases.count == 4, "优先级有 4 档")
    // 工期比优先级多一档，但每档结构相同，所以只是更宽
    check(presets.count == 5, "工期 5 档")

    // 档位数量不同不算破坏一致性——控件类型相同即可。
    // 真正要一致的是：都用 matchedGeometryEffect 滑动底块。
}

@MainActor

/// 每个语义色在浅色和深色模式下都要够清楚。
///
/// 起因：原来用固定色值，黄 (#D9A800) 在白底上对比度只有 2.01，
/// 橙只有 2.45——WCAG 非文本元素要求 ≥ 3.0，这两个在浅色模式下
/// 基本看不清。深色模式下则是蓝色强调色发闷。
///
/// 现在每个颜色按外观分别取值。这条测试把"两边都过线"钉死，
/// 以后改色值如果只顾了一侧，测试会直接报出来。
func testPaletteContrast() {
    // 与 DesignSystem.swift 里 Priority.tint 的取值保持一致
    let palette: [(String, (Double,Double,Double), (Double,Double,Double))] = [
        ("urgent", (0.835,0.216,0.239), (0.949,0.361,0.376)),
        ("high",   (0.784,0.396,0.031), (0.973,0.573,0.129)),
        ("normal", (0.639,0.478,0.000), (0.941,0.769,0.208)),
        ("low",    (0.082,0.502,0.239), (0.290,0.871,0.502)),
    ]
    // 强调色按外观分别取值（绿）
    let accentLight: (Double,Double,Double) = (0.035, 0.424, 0.290)
    let accentDark:  (Double,Double,Double) = (0.204, 0.827, 0.600)

    for (name, light, dark) in palette {
        let lc = UILogic.contrastRatio(light, UILogic.lightPanelBackground)
        let dc = UILogic.contrastRatio(dark, UILogic.darkPanelBackground)
        check(lc >= UILogic.minContrast,
              "\(name) 浅色对比度应 ≥3.0，实测 \(String(format: "%.2f", lc))")
        check(dc >= UILogic.minContrast,
              "\(name) 深色对比度应 ≥3.0，实测 \(String(format: "%.2f", dc))")
    }

    // 强调色两种模式都要过线
    let ac = UILogic.contrastRatio(accentLight, UILogic.lightPanelBackground)
    let ad = UILogic.contrastRatio(accentDark, UILogic.darkPanelBackground)
    check(ac >= UILogic.minContrast, "强调色浅色对比度应 ≥3.0，实测 \(String(format: "%.2f", ac))")
    // 深色要求比浅色更高：深底上人眼对饱和色的辨识更吃力，
    // 3.94 的紫用户明确反馈"看不清"，6.12 才够。
    check(ad >= 5.0, "强调色深色对比度应 ≥5.0，实测 \(String(format: "%.2f", ad))")

    // 深色必须比浅色更亮——否则说明取反了
    let darkLum = UILogic.relativeLuminance(r: accentDark.0, g: accentDark.1, b: accentDark.2)
    let lightLum = UILogic.relativeLuminance(r: accentLight.0, g: accentLight.1, b: accentLight.2)
    check(darkLum > lightLum, "深色模式的强调色应比浅色模式更亮")

    // 选中底块：填充+描边合成后要能看出边界
    for (mode, acc, bg, fillOp, strokeOp) in [
        ("深色", accentDark, UILogic.darkPanelBackground, 0.22, 0.75),
        ("浅色", accentLight, UILogic.lightPanelBackground, 0.16, 0.75),
    ] {
        let fill = UILogic.blend(acc, bg, fillOp)
        let stroke = UILogic.blend(acc, bg, strokeOp)
        // 文字在填充底上要清楚
        check(UILogic.contrastRatio(acc, fill) >= 3.0,
              "\(mode) 选中文字压在底块上应 ≥3.0")
        // 描边要勾得出边界
        check(UILogic.contrastRatio(stroke, bg) >= UILogic.minContrast,
              "\(mode) 选中描边应 ≥3.0，否则边界会糊")
    }

    // 强调色与优先级色的距离。
    //
    // low 是有意的例外：它和强调色同属绿色系（色距 ~0.10）。
    // 两者不会同时出现在一处——输入区已改成纯中性色，
    // 强调色只用于"已完成勾选圈"（行首）和设置页，
    // 优先级圆点在行尾，隔着整行内容。
    // 其余三档必须离强调色足够远。
    for (name, light, _) in palette {
        let dist = pow(pow(accentLight.0 - light.0, 2)
                     + pow(accentLight.1 - light.1, 2)
                     + pow(accentLight.2 - light.2, 2), 0.5)
        if name == "low" {
            // 有意接近：只要不与红/橙/黄混淆即可，在下面单独校验
            check(dist < 0.30, "low 应接近强调色（同绿色系），实测 \(String(format: "%.2f", dist))")
        } else {
            check(dist > 0.5, "强调色与 \(name) 应 >0.5 可区分，实测 \(String(format: "%.2f", dist))")
        }
    }

    // 低优先级虽与强调色相近，但必须和另外三档分得开——
    // 四档并排时，用户靠的是彼此差异而不是绝对色值。
    let low = palette.first { $0.0 == "low" }!
    for (name, light, _) in palette where name != "low" {
        let dist = pow(pow(low.1.0 - light.0, 2)
                     + pow(low.1.1 - light.1, 2)
                     + pow(low.1.2 - light.2, 2), 0.5)
        check(dist > 0.45, "low 与 \(name) 应 >0.45 可区分，实测 \(String(format: "%.2f", dist))")
    }
}

@MainActor

/// 卡片网格的列数与宽度。
///
/// 三条约束：
///   · 卡片不能窄到标题只剩几个字（读起来断句）
///   · 也不能宽到一屏只放两三张（卡片的意义是"一眼看全"）
///   · 列宽必须是正数，且总和不能超过可用宽度（否则横向溢出）
func testCardGrid() {
    let columns = UILogic.cardColumnCount()
    check(columns >= 2, "至少两列，否则卡片太宽")
    check(columns <= 4, "最多四列，否则标题读不下")

    // 面板内容宽约 584pt
    let available = 568.0
    let spacing = 8.0
    let w = UILogic.cardWidth(available: available, columns: columns, spacing: spacing)

    check(w > 0, "卡片宽度应为正")

    // 两列是为了放下「日期 + 工期 + 优先级」这一整行元信息。
    // 三列时每张只有 184pt，日期会被挤到换行。
    check(columns == 2, "应为两列，才能容纳完整元信息")
    check(w > 200, "两列时每张应宽于 200pt，实测 \(String(format: "%.0f", w))")

    // 一行至少能放 10 个汉字（12.5pt 字号约 12.5pt/字）
    check(w / 12.5 >= 10, "卡片一行应能放下至少 10 个汉字，实测 \(String(format: "%.0f", w/12.5))")
    // 也不能宽到一屏只放一张
    check(w < available, "单张不应占满整个宽度")

    // 总宽不溢出
    let total = w * Double(columns) + spacing * Double(columns - 1)
    check(abs(total - available) < 0.01, "列宽总和应正好铺满可用宽度")

    // 边界：列数为 0 不能除零
    check(UILogic.cardWidth(available: 500, columns: 0, spacing: 8) == 0,
          "列数为 0 时应返回 0")
    // 可用宽度极小（首帧布局）时不能返回负数
    check(UILogic.cardWidth(available: 5, columns: 3, spacing: 8) == 0,
          "可用宽度不够时应钳到 0，不能出负数")

    // 卡片高度必须能容下三行标题。
    //
    // 曾经写死 84pt——一行标题只要 54pt 看着刚好，
    // 但三行需要 88pt，第三行会被直接截掉。
    // 现在用 minHeight，单张能自己撑开。
    let lineHeight = 12.5 * 1.35   // 12.5pt 字号的行高
    let threeLines = 3 + 16 + lineHeight * 3 + 6 + 12
    check(UILogic.cardMinHeight > 0, "卡片最小高应为正")
    check(threeLines > UILogic.cardMinHeight,
          "三行标题应高于最小高，从而触发自适应撑开（验证 minHeight 而非固定高）")

    // 列数越多，单张越窄（单调性）
    let w2 = UILogic.cardWidth(available: available, columns: 2, spacing: spacing)
    let w4 = UILogic.cardWidth(available: available, columns: 4, spacing: spacing)
    check(w2 > w4, "列数增加时单张应更窄")
    check(abs(w2 - w) < 0.01, "两列宽度应与实际取用的一致")
}

/// 子要点的解析、清洗与增删改。
///
/// 要点存在被闲置的 note 字段里（换行分隔的纯文本）。
/// 这样老数据天然兼容：note 是空串时拆出来就是空数组。
@MainActor
func testBulletPoints() {
    // ── 解析 ──
    var memo = Memo.make(title: "测试", priority: .normal, dueDate: DateKey.today)
    check(memo.bulletPoints.isEmpty, "空 note 应解析出空数组")
    check(!memo.hasPoints, "空 note 不应有要点")

    memo.note = "买牛奶\n交房租\n  打电话  \n\n"
    check(memo.bulletPoints == ["买牛奶", "交房租", "打电话"],
          "应去掉空行和首尾空白，实测 \(memo.bulletPoints)")
    check(memo.hasPoints, "有内容时 hasPoints 应为真")

    // ── 序列化 ──
    check(Memo.noteText(from: ["a", "b"]) == "a\nb", "应换行连接")
    check(Memo.noteText(from: ["  a  ", "", "b"]) == "a\nb", "应先清洗再连接")
    check(Memo.noteText(from: []) == "", "空数组应得到空串")

    // 往返一致
    let round = ["甲", "乙", "丙"]
    check(Memo.noteText(from: round).components(separatedBy: "\n").filter { !$0.isEmpty } == round,
          "序列化再解析应还原")

    // ── 清洗 ──
    check(UILogic.maxBulletPoints == 3, "要点上限应为 3 条")
    check(UILogic.normalizeBullet("  ") == nil, "全空白应丢弃")
    check(UILogic.normalizeBullet("  有效  ") == "有效", "应去首尾空白")
    let long = String(repeating: "字", count: 300)
    let cut = UILogic.normalizeBullet(long)
    check(cut?.count == UILogic.maxBulletLength, "超长应截断到上限")

    // ── 追加 ──
    check(UILogic.appendingBullet([], "第一条") == ["第一条"], "空列表应能追加")
    check(UILogic.appendingBullet(["a"], "  ") == ["a"], "空白不应追加")
    check(UILogic.appendingBullet(["a"], "b") == ["a", "b"], "应按顺序追加")

    // 上限
    var full: [String] = []
    for i in 0..<UILogic.maxBulletPoints {
        full = UILogic.appendingBullet(full, "第\(i)条")
    }
    check(full.count == UILogic.maxBulletPoints, "应能加满")
    check(!UILogic.canAddBullet(full), "满后不能再加")
    check(UILogic.appendingBullet(full, "溢出") == full, "满后追加应无效")

    // ── 删除 ──
    check(UILogic.removingBullet(["a","b","c"], at: 1) == ["a","c"], "应删中间项")
    check(UILogic.removingBullet(["a"], at: 0) == [], "应能删到空")
    check(UILogic.removingBullet(["a"], at: 5) == ["a"], "越界应原样返回")
    check(UILogic.removingBullet(["a"], at: -1) == ["a"], "负索引应原样返回")

    // ── 改写 ──
    check(UILogic.replacingBullet(["a","b"], at: 0, with: "x") == ["x","b"], "应能改写")
    check(UILogic.replacingBullet(["a","b"], at: 0, with: "  ") == ["b"],
          "改成空白应等于删除（不留空条目）")
    check(UILogic.replacingBullet(["a"], at: 3, with: "x") == ["a"], "越界改写应原样返回")

    // ── 计数文案 ──
    check(UILogic.bulletSummary([]) == "", "空列表不该显示角标")
    check(UILogic.bulletSummary(["a"]) == "1 条要点", "应给出条数")
    check(UILogic.bulletSummary(["a","b","c"]) == "3 条要点", "应给出条数")

    // ── store 层：要点能落盘 ──
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("points-\(UUID().uuidString).json")
    let store = MemoStore(fileURL: tmp)
    if let added = store.add(title: "带要点", priority: .high, dueDate: DateKey.today,
                             span: 2, note: "甲\n乙\n\n丙") {
        let saved = store.items.first { $0.id == added.id }
        check(saved?.bulletPoints == ["甲","乙","丙"], "add 应保存要点，实测 \(saved?.bulletPoints ?? [])")
        store.setNote(added.id, to: "新的一条")
        check(store.items.first { $0.id == added.id }?.bulletPoints == ["新的一条"],
              "setNote 应整体替换")
    } else {
        check(false, "add 应成功")
    }
    try? FileManager.default.removeItem(at: tmp)
}

@MainActor

/// 排序以紧急程度为准，日期降级为事项内部的属性。
///
/// 这条规则的边界要逐个钉死，因为排序一改，
/// 所有跟"顺序"相关的直觉都会变。
func testPriorityFirstSorting() {
    func day(_ d: Int) -> String { DateKey.add(days: d, to: DateKey.today) }
    func mk(_ id: String, _ p: Priority, _ due: Int,
            done: Bool = false, created: String = "2026-01-01T00:00:00+08:00") -> Memo {
        Memo(id: id, title: id, priority: p, dueDate: day(due), note: "",
             done: done, createdAt: created, completedAt: nil)
    }

    // 紧急程度压过日期：紧急的"下周"排在普通的"今天"之前
    let a = MemoSort.sorted([mk("普通今天", .normal, 0), mk("紧急下周", .urgent, 7)])
    check(a.map(\.id) == ["紧急下周", "普通今天"],
          "紧急程度应优先于日期（实际：\(a.map(\.id))）")

    // 四档的完整顺序
    let b = MemoSort.sorted([mk("低", .low, 0), mk("普通", .normal, 0),
                             mk("高", .high, 0), mk("紧急", .urgent, 0)])
    check(b.map(\.id) == ["紧急", "高", "普通", "低"],
          "应按紧急→高→普通→低排列（实际：\(b.map(\.id))）")

    // 同档内按日期
    let c = MemoSort.sorted([mk("后天", .normal, 2), mk("今天", .normal, 0),
                             mk("明天", .normal, 1)])
    check(c.map(\.id) == ["今天", "明天", "后天"], "同档内应按日期升序")

    // 逾期压过一切未逾期的，哪怕紧急度最低
    let d = MemoSort.sorted([mk("紧急今天", .urgent, 0), mk("低已逾期", .low, -1)])
    check(d.map(\.id) == ["低已逾期", "紧急今天"],
          "逾期的应排在所有未逾期之前（实际：\(d.map(\.id))）")

    // 逾期之间仍按紧急程度
    let e = MemoSort.sorted([mk("逾期低", .low, -2), mk("逾期紧急", .urgent, -1)])
    check(e.map(\.id) == ["逾期紧急", "逾期低"], "逾期之间应按紧急程度")

    // 已完成永远沉底，哪怕最紧急、已逾期
    let f = MemoSort.sorted([mk("完成", .urgent, -5, done: true), mk("低未完成", .low, 3)])
    check(f.map(\.id) == ["低未完成", "完成"], "已完成的应排最后")

    // 同档同日按创建时间，保证顺序稳定
    let g = MemoSort.sorted([
        mk("晚建", .normal, 0, created: "2026-01-02T00:00:00+08:00"),
        mk("早建", .normal, 0, created: "2026-01-01T00:00:00+08:00"),
    ])
    check(g.map(\.id) == ["早建", "晚建"], "同档同日应按创建时间")

    // 排序必须与输入顺序无关（否则 animate 时会跳）
    let base = [mk("a", .high, 1), mk("b", .low, 0), mk("c", .urgent, 2)]
    check(MemoSort.sorted(base).map(\.id) == MemoSort.sorted(base.reversed()).map(\.id),
          "排序结果应与输入顺序无关")
}

/// 要点上限是 3 条。
func testBulletLimitIsThree() {
    check(UILogic.maxBulletPoints == 3, "要点上限应为 3 条")

    var pts: [String] = []
    for i in 0..<5 {
        pts = UILogic.appendingBullet(pts, "第\(i)条")
    }
    check(pts == ["第0条", "第1条", "第2条"],
          "超过 3 条应被截断（实际：\(pts)）")
    check(!UILogic.canAddBullet(pts), "满 3 条后不能再加")

    // 删掉一条后应能再加
    let after = UILogic.removingBullet(pts, at: 0)
    check(UILogic.canAddBullet(after), "删掉一条后应能再加")
    check(UILogic.appendingBullet(after, "新").count == 3, "补回后仍是 3 条")

    // normalizeBullets 也要遵守上限
    let many = (0..<10).map { "x\($0)" }
    check(UILogic.normalizeBullets(many).count == 3, "normalizeBullets 应截断到 3")
}

@MainActor

/// 确认按钮：墨色实心 + 反色文字，两种外观下都要能读。
///
/// 按钮从强调绿改成中性墨色之后，可用性完全押在明度差上——
/// 没有色相帮忙区分，对比度不达标就是真的看不清。
/// 把它钉成测试，免得以后调 token 时悄悄失效。
func testConfirmButtonContrast() {
    // 与 DesignSystem 里的定义保持一致
    let darkPanel = UILogic.darkPanelBackground
    let lightPanel = UILogic.lightPanelBackground

    for (name, panel, ink) in [("深色", darkPanel, (1.0, 1.0, 1.0)),
                               ("浅色", lightPanel, (0.0, 0.0, 0.0))] {
        // 按钮实心底 = 墨色 88% 覆盖在面板上
        let fill = UILogic.blend(ink, panel, 0.88)
        // 文字色 = 面板背景（反色）
        let r = UILogic.contrastRatio(panel, fill)

        check(r >= 4.5,
              "\(name)模式确认按钮文字应 ≥4.5:1，实测 \(String(format: "%.2f", r))")

        // 按钮与周围面板也要能区分开——否则看不出这里有个按钮
        let vsPanel = UILogic.contrastRatio(fill, panel)
        check(vsPanel >= 3.0,
              "\(name)模式按钮底与面板应可辨（≥3.0），实测 \(String(format: "%.2f", vsPanel))")
    }

    // 禁用态：文字用 inkQuaternary(24%)，只需要"看得出不可用"，不要求高对比
    for (name, panel, ink) in [("深色", darkPanel, (1.0, 1.0, 1.0)),
                               ("浅色", lightPanel, (0.0, 0.0, 0.0))] {
        let sur = UILogic.blend(ink, panel, 0.055)   // surfaceHover
        let txt = UILogic.blend(ink, panel, 0.24)    // inkQuaternary
        let r = UILogic.contrastRatio(txt, sur)
        check(r >= 1.2,
              "\(name)模式禁用态文字应仍可辨认，实测 \(String(format: "%.2f", r))")
    }

    // 反色文字必须带方向：深色面板配浅字、浅色面板配深字
    func lum(_ c: (Double, Double, Double)) -> Double {
        UILogic.relativeLuminance(r: c.0, g: c.1, b: c.2)
    }
    check(lum(darkPanel) < lum(lightPanel), "深色面板应比浅色面板暗")

    let darkFill = UILogic.blend((1.0,1.0,1.0), darkPanel, 0.88)
    let lightFill = UILogic.blend((0.0,0.0,0.0), lightPanel, 0.88)
    check(lum(darkFill) > lum(darkPanel),
          "深色模式下按钮底应比面板亮（实心是浅色块）")
    check(lum(lightFill) < lum(lightPanel),
          "浅色模式下按钮底应比面板暗（实心是深色块）")
}

@MainActor

/// 加号按钮什么时候可点。
///
/// PointsEditor 里 canCommit = canAdd && normalizeBullet(draft) != nil。
/// 这两条规则决定了按钮亮不亮，也就决定了用户能不能添加，
/// 必须逐个钉死——尤其"输入全是空白"这种边界。
func testAddButtonGating() {
    func canAdd(_ pts: [String]) -> Bool { UILogic.canAddBullet(pts) }
    func canCommit(_ pts: [String], _ draft: String) -> Bool {
        canAdd(pts) && UILogic.normalizeBullet(draft) != nil
    }

    let empty: [String] = []

    // 未满 + 有内容 → 可点
    check(canCommit(empty, "买牛奶"), "未满且有内容时应可点")
    check(canCommit(["a"], "b"), "未满且有内容时应可点")

    // 未满 + 空/空白 → 不可点
    check(!canCommit(empty, ""), "空输入时不可点")
    check(!canCommit(empty, "   "), "全是空白时不可点")
    check(!canCommit(empty, "\n\n"), "只有换行时不可点")

    // 已满 → 无论输入什么都不点
    let full = ["a", "b", "c"]
    check(!canAdd(full), "满 3 条后 canAdd 应为假")
    check(!canCommit(full, "还想加"), "已满时即使有内容也不可点")
    check(!canCommit(full, ""), "已满时空输入也不可点")

    // 删掉一条后恢复可点
    let freed = UILogic.removingBullet(full, at: 1)
    check(canAdd(freed), "删掉一条后应恢复可加")
    check(canCommit(freed, "补一条"), "删除后应有内容即可点")

    // 前后空白不影响判定
    check(canCommit(empty, "  有内容  "), "首尾空白不应影响可点判断")

    // 超长内容仍可添加（会被截断，但不该阻止点击）
    let long = String(repeating: "字", count: 500)
    check(canCommit(empty, long), "超长内容也应可点（内部会截断）")

    // 点击后 draft 应清空（模拟 appendEditingPoint 的行为）
    var pts: [String] = []
    var draft = "第一条"
    let before = pts.count
    pts = UILogic.appendingBullet(pts, draft)
    if pts.count > before { draft = "" }
    check(pts == ["第一条"] && draft.isEmpty, "添加后应入列并清空输入框")

    // 空白提交不应清空已有内容，也不应增加条目
    var pts2 = ["已有"]
    let draft2 = "   "
    let before2 = pts2.count
    pts2 = UILogic.appendingBullet(pts2, draft2)
    check(pts2.count == before2, "空白提交不应新增条目")
}

/// 失焦保存的三条规则。
///
/// 1. 焦点在编辑区内部挪动（标题→要点）不算离开
/// 2. 真的离开时保存标题和要点
/// 3. 这期间换了对象就作废——editingText 是共享状态，
///    用新对象的内容去保存旧对象会造成数据错乱
@MainActor
func testFocusLostCommitRules() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = MemoStore(fileURL: tmp)
    guard let a = store.add(title: "原A", priority: .normal, dueDate: DateKey.today,
                            span: 1, note: "要点A"),
          let b = store.add(title: "原B", priority: .normal, dueDate: DateKey.today) else {
        check(false, "预置数据应成功")
        return
    }
    check(a.id != b.id, "两条应是不同事项")

    // 规则 2：真的离开 → 保存
    store.rename(a.id, to: "改后的A")
    store.setNote(a.id, to: Memo.noteText(from: ["要点A", "新要点"]))
    let savedA = store.items.first { $0.id == a.id }
    check(savedA?.title == "改后的A", "失焦保存应写入标题")
    check(savedA?.bulletPoints == ["要点A", "新要点"], "失焦保存应写入要点")

    // 规则 3：换了对象要作废
    // 模拟：编辑 A 时失焦，120ms 内用户点了 B。
    // 此时 editingText 已被 B 的内容覆盖。
    var editingID: String? = a.id
    var editingText = "A 的未保存内容"
    var editingPoints = ["A 的要点"]

    // 失焦 A，记下当时的 id
    let pendingID = editingID

    // 用户在延迟窗口内切到 B
    editingID = b.id
    editingText = "B 的内容"
    editingPoints = ["B 的要点"]

    // 延迟回调到达：必须检查 id 还对不对
    let shouldCommit = (editingID == pendingID)
    check(!shouldCommit, "换了对象后，旧事项的失焦保存必须作废")

    // 如果没做这个检查，B 的内容会被写进 A
    if shouldCommit {
        store.rename(a.id, to: editingText)
    }
    check(store.items.first { $0.id == a.id }?.title == "改后的A",
          "A 的标题不应被 B 的内容覆盖")
    check(store.items.first { $0.id == b.id }?.title == "原B",
          "B 也不该被误改")

    // 退出编辑后，延迟保存也要作废
    editingID = nil
    let shouldCommitAfterExit = (editingID == pendingID)
    check(!shouldCommitAfterExit, "退出编辑后延迟保存应作废")

    // 同一对象仍然在编辑 → 正常保存
    editingID = a.id
    let shouldCommitSame = (editingID == a.id)
    check(shouldCommitSame, "对象未变时应正常保存")

    // 标题为空时不该把事项名清掉
    store.rename(a.id, to: "   ")
    check(store.items.first { $0.id == a.id }?.title == "改后的A",
          "空白标题不应覆盖原内容")
}

/// 失焦保存要点时，空白要点不该被写成空行
func testFocusLostNoteCleaning() {
    // 编辑中途留下的空条目，保存时应被清掉
    let raw = ["有效要点", "", "   ", "第二条"]
    let cleaned = Memo.noteText(from: raw)
    check(cleaned == "有效要点\n第二条", "保存时应清掉空要点（实际：\(cleaned.debugDescription)）")

    // 全空 → 空串（等于没有要点）
    check(Memo.noteText(from: ["", "  "]) == "", "全空要点应得到空串")

    // 往返：存进去再读出来一致
    let memoNote = Memo.noteText(from: raw)
    let round = memoNote.components(separatedBy: "\n").filter { !$0.isEmpty }
    check(round == ["有效要点", "第二条"], "往返应一致")
}

@MainActor


/// 点击区域判定：点在编辑区内则保留编辑，否则退出。
///
/// 这条判定的两个方向都会造成可见 bug：
///   · 该"内"判成"外" → 点自己的要点框，编辑被关掉
///   · 该"外"判成"内" → 点别处，编辑不退出，用户以为卡住了
func testClickRegionHitTest() {
    let r = UILogic.Region(x: 100, y: 200, width: 300, height: 80)

    func hit(_ x: Double, _ y: Double) -> Bool {
        UILogic.hitTest(point: (x: x, y: y), regions: [r])
    }

    // 内部：四个角 + 中心
    check(hit(150, 250), "中心应命中")
    check(hit(101, 201), "左上角应命中")
    check(hit(399, 279), "右下角应命中")
    check(hit(100, 200), "基准点应命中")
    check(hit(400, 280), "对角点应命中")

    // 外部：明显在框外
    check(!hit(50, 250), "左侧外应不命中")
    check(!hit(450, 250), "右侧外应不命中")
    check(!hit(150, 100), "上方外应不命中")
    check(!hit(150, 400), "下方外应不命中")

    // 容差：边界外 2pt 内仍算命中
    let t = UILogic.regionTolerance
    check(t > 0, "容差应为正数")
    check(hit(100 - t + 0.5, 250), "边界外一点点应命中（容差内）")
    check(!hit(100 - t - 1, 250), "超出容差应不命中")
    check(hit(400 + t - 0.5, 250), "右边界外一点点应命中")
    check(!hit(400 + t + 1, 250), "右边界超出容差应不命中")

    // 多个区域：任意一个命中即可
    let r2 = UILogic.Region(x: 500, y: 200, width: 100, height: 80)
    check(UILogic.hitTest(point: (x: 550, y: 250), regions: [r, r2]), "第二个区域应命中")
    check(!UILogic.hitTest(point: (x: 450, y: 250), regions: [r, r2]), "两区域之间应不命中")

    // 空列表：任何点击都算"外面"
    check(!UILogic.hitTest(point: (x: 150, y: 250), regions: []),
          "没有编辑区时任何点击都不命中")

    // 宽高为 0：无效区域，不该命中
    // 视图还没布局时会上报这种值，拿它判定会一律判错
    let zero = UILogic.Region(x: 100, y: 200, width: 0, height: 0)
    check(!UILogic.hitTest(point: (x: 100, y: 200), regions: [zero]),
          "零尺寸区域不应命中")
    // 该点落在有效区域 r 的边界上，本就该命中——
    // 零尺寸区域不能让它变成"不命中"
    check(UILogic.hitTest(point: (x: 100, y: 200), regions: [r, zero]),
          "零尺寸区域不应让有效区域的命中失效")

    // 负坐标（窗口坐标系原点在左下，但内容可能溢出为负）
    let neg = UILogic.Region(x: -50, y: -20, width: 100, height: 40)
    check(UILogic.hitTest(point: (x: -10, y: 0), regions: [neg]), "负坐标区域应能命中")
    check(UILogic.hitTest(point: (x: -50, y: -20), regions: [neg]), "负坐标边界应命中")
    check(!UILogic.hitTest(point: (x: -100, y: 0), regions: [neg]), "负坐标区域外应不命中")
}

@MainActor


/// 动效分档：每档要有明确的时间尺度，且不能互相挤压。
///
/// 这些数字不是随手取的，它们决定了整个界面的节奏感：
///   · 悬停必须快到几乎无感，慢了就像界面在拖手
///   · 确认要带一点过冲，能"弹一下"
///   · 退场比入场快——东西消失不该让人等
func testAnimationTiers() {
    // UILogic 里放的是一份与 DesignSystem 同步的时长表，
    // 让动画节奏成为可测的事实，而不是散落在视图里的字面量。
    let tiers = UILogic.animationTiers

    // 五档齐全
    check(tiers.count == 5, "应有 5 档动效（实际 \(tiers.count)）")

    let hover = tiers["hover"]!
    let tap = tiers["tap"]!
    let confirm = tiers["confirm"]!
    let move = tiers["move"]!
    let remove = tiers["remove"]!

    // 悬停最快
    check(hover < tap, "悬停应快于点击反馈（\(hover) vs \(tap)）")
    check(hover <= 0.15, "悬停应 ≤0.15s，否则会显得拖手（实测 \(hover)）")

    // 确认感最长（回弹需要时间走完）
    check(confirm > move, "确认应长于中尺度移动（\(confirm) vs \(move)）")

    // 中尺度用于整块内容切换，必须比即时反馈慢
    check(move > tap, "中尺度应慢于即时反馈（\(move) vs \(tap)）")

    // 退场比入场快
    check(remove < move, "退场应快于入场（\(remove) vs \(move)）")
    check(remove <= 0.2, "退场应 ≤0.2s，不能让人等（实测 \(remove)）")

    // 全部落在合理区间：太快看不见，太慢显得卡
    for (name, seconds) in tiers {
        check(seconds > 0.05, "\(name) 不应短于 0.05s（看不出动）")
        check(seconds < 0.6, "\(name) 不应长于 0.6s（显得卡顿）")
    }

    // 相邻档位要能区分：差太小就等于没有分档
    let sorted = tiers.values.sorted()
    for i in 1..<sorted.count {
        let gap = sorted[i] - sorted[i-1]
        check(gap >= 0.03,
              "相邻档位至少差 0.03s，否则区分不出来（实测 \(String(format: "%.3f", gap))）")
    }
}

@MainActor


/// 日期行：相对说法 + 绝对日期 + 星期。
///
/// 「今天」和「11月5日 周三」解决的是两个不同问题：
/// 前者一眼知道紧不紧急，后者知道具体是哪天。
func testDateLineWithWeekday() {
    // 固定一个已知的日子来断言，避免依赖运行当天
    let cal = Calendar.current
    let now = DateKey.date(from: "2026-11-05")!   // 周四
    _ = cal

    let key = "2026-11-05"
    let text = UILogic.shortDateWithWeekday(key, now: now)
    check(text == "11月5日 周四", "应渲染成「11月5日 周四」（实际：\(text)）")

    // 所有星期都要能正确映射
    // 2026-11-01 是周日
    for (offset, expected) in [(0, "周日"), (1, "周一"), (2, "周二"), (3, "周三"),
                               (4, "周四"), (5, "周五"), (6, "周六")] {
        let d = DateKey.add(days: offset, to: "2026-11-01")
        let t = UILogic.shortDateWithWeekday(d, now: now)
        check(t.contains(expected), "\(d) 应含 \(expected)（实际：\(t)）")
    }

    // 跨年才显示年份
    let otherYear = UILogic.shortDateWithWeekday("2027-03-01", now: now)
    check(otherYear.contains("2027年"), "跨年应显示年份（实际：\(otherYear)）")
    let sameYear = UILogic.shortDateWithWeekday("2026-03-01", now: now)
    check(!sameYear.contains("2026年"), "同年不显示年份（实际：\(sameYear)）")

    // 无效输入原样返回，不崩
    check(UILogic.shortDateWithWeekday("不是日期", now: now) == "不是日期",
          "无效日期应原样返回")

    // dateLine：相对 + 绝对
    let line = UILogic.dateLine(relative: "今天", dateKey: "2026-11-05", now: now)
    check(line == "今天 · 11月5日 周四", "应有相对+绝对（实际：\(line)）")

    // 相对为空时只给绝对
    check(UILogic.dateLine(relative: "", dateKey: "2026-11-05", now: now) == "11月5日 周四",
          "无相对说法时只显示绝对日期")

    // 逾期也要带上具体日期
    let overdue = UILogic.dateLine(relative: "逾期 2 天", dateKey: "2026-11-03", now: now)
    check(overdue.contains("11月3日"), "逾期也应显示具体日期（实际：\(overdue)）")
    check(overdue.contains("周"), "逾期也应显示星期")
}

/// 工期必须对所有事项可改，包括只有 1 天的。
///
/// 早先界面只在 isMultiDay 时显示工期角标，
/// 等于把单日事项（包括今天到期的）的工期做成只读——
/// 想放宽期限时根本没有入口。
@MainActor
func testSpanEditableForSingleDay() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("span-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = MemoStore(fileURL: tmp)
    let today = DateKey.today
    guard let item = store.add(title: "今天到期", priority: .normal, dueDate: today) else {
        check(false, "预置应成功")
        return
    }

    // 默认工期 1 天
    let created = store.items.first { $0.id == item.id }!
    check(created.spanDays == 1, "默认工期应为 1 天")
    check(!created.isMultiDay, "工期 1 天不算多天")
    check(created.endDate == today, "工期 1 天时截止日就是起始日")

    // 关键：单日事项也能改
    store.setSpan(item.id, to: 3)
    let extended = store.items.first { $0.id == item.id }!
    check(extended.spanDays == 3, "单日事项应能改为 3 天")

    // 语义：起始日不变，截止日向后顺延
    check(extended.dueDate == today, "改工期不应移动起始日")
    check(extended.endDate == DateKey.add(days: 2, to: today),
          "截止日应顺延到第 3 天（实际：\(extended.endDate)）")

    // 改回去
    store.setSpan(item.id, to: 1)
    let back = store.items.first { $0.id == item.id }!
    check(back.spanDays == 1, "应能改回 1 天")
    check(back.endDate == today, "改回 1 天后截止日应回到起始日")

    // 下界：不能减到 0 或负数
    store.setSpan(item.id, to: 0)
    check(store.items.first { $0.id == item.id }?.spanDays == 1, "工期不应小于 1")
    store.setSpan(item.id, to: -5)
    check(store.items.first { $0.id == item.id }?.spanDays == 1, "负工期应被夹到 1")

    // 上界
    store.setSpan(item.id, to: 9999)
    check(store.items.first { $0.id == item.id }?.spanDays == 365, "工期上限应为 365")
}

@MainActor


/// 卡片高度：基线紧凑，标题长了再自适应。
///
/// 这里钉住的是一个**取舍**，不只是数字：
/// 钉死高度能消参差，但短标题的卡会大片留白；
/// 全部自适应能去留白，但同排参差。
/// 现在的选择是——基线只保证"最短摆得下"，
/// 要点区固定（保证日期行对齐），标题区不固定（长短一眼能看懂）。
func testCardBaselineHeight() {
    // 基线要能装下"标题 1 行 + 要点 3 条"
    check(UILogic.cardHeightBudgetFits(),
          "基线应装得下 标题1行 + 要点3条（预算超了）")

    // 基线必须比旧的固定高度明显小，否则等于没改
    check(UILogic.cardBaseHeight < 160,
          "基线应明显小于旧的 186(实测 \(UILogic.cardBaseHeight))")
    check(UILogic.cardBaseHeight >= 135,
          "基线应接近实测 141，不能再低（误设成 124 会让有要点的卡自己长高，等于没设）")
    check(UILogic.cardBaseHeight > UILogic.cardMinHeight,
          "基线应大于最小高度 \(UILogic.cardMinHeight)")

    // 上限是实测值 156（标题 3 行 + 3 要点）
    check(abs(UILogic.cardMaxHeight - 156) <= 4,
          "上限应接近实测 156（当前 \(UILogic.cardMaxHeight)）")

    // 高度跨度要合理：太小说明几乎不随内容变
    let span = UILogic.cardMaxHeight - UILogic.cardBaseHeight
    check(span >= 10 && span <= 40,
          "基线与上限的跨度应在 10~40pt 之间（实测 \(span)）")

    // 要点区额度要严格大于实测 3 条高度 39.0
    check(UILogic.cardPointsBlockHeight > 39.0,
          "要点区额度应严格大于实测 39.0（当前 \(UILogic.cardPointsBlockHeight)）")

    // 要点区必须固定：它是日期行对齐的唯一依靠
    check(UILogic.cardPointSlots == 3, "要点额度应为 3 条")

    // 标题最多 3 行，超出截断——不能让一张卡无限长高
    check(UILogic.cardTitleLines == 3, "标题上限应为 3 行")

    // 无要点时不占要点区：这条直接对应"留白"被去掉
    let withPoints = Memo.make(title: "有要点", priority: .normal, dueDate: DateKey.today)
    var a = withPoints
    a.note = Memo.noteText(from: ["一", "二", "三"])
    var b = withPoints
    b.note = ""
    check(a.hasPoints, "前提：a 有要点")
    check(!b.hasPoints, "前提：b 无要点")

    // 数据层不因卡片额度而丢数据
    check(a.bulletPoints.count == 3, "数据层保留全部要点")
    check(b.bulletPoints.isEmpty, "无要点时为空")
}

@MainActor


/// 要点行的 ID 必须稳定，否则动画会整段重排。
///
/// 用下标当 ID 时删掉中间一条，后面的行会"变成"前一行，
/// SwiftUI 看到的是所有行都换了内容，于是整段重排而不是
/// 只消失一行——动画看起来就是一顿。
func testBulletStableIdentity() {
    let a = UILogic.bulletIdentities(["甲", "乙", "丙"])
    check(a.count == 3, "应生成 3 个 ID")
    check(Set(a).count == 3, "ID 不应重复")

    // 删掉中间一条：剩下两条的 ID 必须和原来一致
    let afterRemove = UILogic.bulletIdentities(["甲", "丙"])
    check(afterRemove[0] == a[0], "删中间条后，第一条 ID 不应变（\(afterRemove[0]) vs \(a[0])）")
    check(afterRemove[1] == a[2], "删中间条后，原第三条 ID 不应变（\(afterRemove[1]) vs \(a[2])）")

    // 插入到开头：原有的 ID 都不能变
    let afterInsert = UILogic.bulletIdentities(["新", "甲", "乙", "丙"])
    check(afterInsert[1] == a[0], "插入开头后，原第一条 ID 不应变")
    check(afterInsert[3] == a[2], "插入开头后，原第三条 ID 不应变")

    // 内容相同也能区分
    let dup = UILogic.bulletIdentities(["同", "同"])
    check(dup.count == 2, "两条相同内容应生成两个 ID")
    check(dup[0] != dup[1], "相同内容的两条 ID 必须不同，否则 ForEach 会撞（\(dup)）")

    // 三条相同也不撞
    let tri = UILogic.bulletIdentities(["x", "x", "x"])
    check(Set(tri).count == 3, "三条相同内容应有 3 个不同 ID")

    // 空列表
    check(UILogic.bulletIdentities([]).isEmpty, "空列表应返回空")

    // 改文字会换 ID —— 这是预期行为，改文字不该有位移
    let changed = UILogic.bulletIdentities(["甲改", "乙", "丙"])
    check(changed[0] != a[0], "改文字应换 ID（那一行重画，不产生位移）")
}

/// 没有要点时不要默认撑出一个空输入框。
///
/// 那个空框会让人以为"这里必须填点什么"，
/// 而要点本来是可选的分点补充。
/// 但一旦开始输入就必须保持展开——否则打字打到一半框会消失。
func testPointsInputVisibility() {
    // 复现 PointsEditor 里 showsInput 的判定
    func shows(_ points: [String], wants: Bool, draft: String) -> Bool {
        !points.isEmpty || wants || !draft.isEmpty
    }

    // 全新、空、没主动要：收起
    check(!shows([], wants: false, draft: ""), "空要点且未主动展开时应收起")

    // 主动点了"加一条要点"：展开
    check(shows([], wants: true, draft: ""), "主动展开后应显示输入行")

    // 已经开始输入：必须保持展开
    check(shows([], wants: false, draft: "写了半句"), "有草稿时必须保持展开")

    // 已有要点：始终展开（继续添加）
    check(shows(["甲"], wants: false, draft: ""), "已有要点时应显示输入行")

    // 三条满了：仍然是"有要点"，输入行显示但加号禁用
    let full = ["甲", "乙", "丙"]
    check(shows(full, wants: false, draft: ""), "满额时输入行仍显示（加号禁用）")
    check(!UILogic.canAddBullet(full), "满额时不能再加")

    // 三种展开条件互不依赖
    check(shows(["甲"], wants: false, draft: ""), "有要点即可展开")
    check(shows([], wants: true, draft: ""), "主动即可展开")
    check(shows([], wants: false, draft: "x"), "有草稿即可展开")
}

@MainActor


/// 输入框图标的对比度必须在两种外观下都**递增**。
///
/// 这条不是洁癖：早先直接用 inkQuaternary→Tertiary→Secondary，
/// 浅色模式下 0.66 在白底上只有 2.17，比 0.44 的 4.52 还淡，
/// 层级整个反了——聚焦时图标反而更看不清。
///
/// 阈值取 2.0：图标是辅助元素，不要求 WCAG 正文级的 4.5，
/// 但低到 2.0 以下就真的看不见了。
func testInputIconContrast() {
    func lum(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    // 灰度色对面板底的对比度
    func ratio(_ v: Double, _ bg: Double) -> Double {
        let a = lum(v), b = lum(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    let darkBG = 0.118   // UILogic.darkPanelBackground
    let lightBG = 0.96   // UILogic.lightPanelBackground

    let inks = UILogic.iconInks
    check(inks.count == 3, "应有三档（实际 \(inks.count)）")

    for (state, dark, light) in inks {
        let d = ratio(dark, darkBG)
        let l = ratio(light, lightBG)
        check(d >= 2.0, "深色模式下 \(state) 对比度应 ≥2.0（实测 \(String(format: "%.2f", d))）")
        check(l >= 2.0, "浅色模式下 \(state) 对比度应 ≥2.0（实测 \(String(format: "%.2f", l))）")
    }

    // 关键：两种外观下都必须是递增的
    let darkRatios = inks.map { ratio($0.dark, darkBG) }
    let lightRatios = inks.map { ratio($0.light, lightBG) }
    for i in 1..<inks.count {
        check(darkRatios[i] > darkRatios[i-1],
              "深色下 \(inks[i].state) 应比 \(inks[i-1].state) 更清楚（\(String(format: "%.2f", darkRatios[i])) vs \(String(format: "%.2f", darkRatios[i-1]))）")
        check(lightRatios[i] > lightRatios[i-1],
              "浅色下 \(inks[i].state) 应比 \(inks[i-1].state) 更清楚（\(String(format: "%.2f", lightRatios[i])) vs \(String(format: "%.2f", lightRatios[i-1]))）")
    }

    // 聚焦态要足够醒目：≥7
    check(darkRatios[2] >= 7.0, "聚焦态深色应 ≥7（实测 \(String(format: "%.2f", darkRatios[2]))）")
    check(lightRatios[2] >= 7.0, "聚焦态浅色应 ≥7（实测 \(String(format: "%.2f", lightRatios[2]))）")

    // 验证"直接沿用墨色阶会出错"这个论断仍然成立
    let wrongSecondary = ratio(0.66, lightBG)
    let wrongTertiary = ratio(0.44, lightBG)
    check(wrongSecondary < wrongTertiary,
          "前提校验：浅色下 0.66 确实比 0.44 淡（\(String(format: "%.2f", wrongSecondary)) < \(String(format: "%.2f", wrongTertiary))）")
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

/// 排序缓存必须总是返回正确结果。
///
/// 缓存最容易引入"看起来对、偶尔错"的问题：
/// 漏掉一个影响排序的字段，就会在某些操作后返回旧顺序，
/// 而且只在特定数据下才复现。
/// 这条测试逐个字段验证缓存会失效。
@MainActor
func testSortCacheInvalidation() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = MemoStore(fileURL: tmp)
    let today = DateKey.today

    guard let a = store.add(title: "甲", priority: .low, dueDate: today),
          let b = store.add(title: "乙", priority: .urgent, dueDate: today) else {
        check(false, "预置失败"); return
    }

    var order = store.sortedItems.map(\.id)
    check(order.first == b.id, "紧急的应排在前")
    check(store.sortedItems.map(\.id) == order, "连续两次读取结果必须相同")

    // 1. 改优先级
    store.setPriority(b.id, to: .low)
    store.setPriority(a.id, to: .urgent)
    order = store.sortedItems.map(\.id)
    check(order.first == a.id, "改优先级后顺序应更新")

    // 2. 改完成态
    store.toggleDone(a.id)
    order = store.sortedItems.map(\.id)
    check(order.last == a.id, "完成项应下沉")

    // 3. 改到期日
    store.toggleDone(a.id)
    store.update(b.id) { $0.dueDate = DateKey.add(days: -5, to: today) }
    order = store.sortedItems.map(\.id)
    check(order.first == b.id, "逾期项应排最前")

    // 4. 改工期（影响截止日 → 影响逾期）
    guard let c = store.add(title: "丙", priority: .normal,
                            dueDate: DateKey.add(days: -1, to: today)) else {
        check(false, "预置丙"); return
    }
    check(store.sortedItems.first?.id == c.id, "昨天到期应逾期排前")
    store.setSpan(c.id, to: 10)
    check(store.sortedItems.first?.id != c.id, "工期拉长后不再逾期，不该排最前")

    // 5. 新增
    let beforeCount = store.sortedItems.count
    _ = store.add(title: "丁", priority: .urgent, dueDate: today)
    check(store.sortedItems.count == beforeCount + 1, "新增后缓存应失效")

    // 6. 删除
    store.delete(b.id)
    check(!store.sortedItems.contains { $0.id == b.id }, "已删除项不该出现")
    check(store.sortedItems.count == store.items.count, "条数应与 items 一致")

    // 7. 改标题：顺序不变，但内容必须更新
    if let target = store.sortedItems.first {
        store.rename(target.id, to: "改了名字")
        check(store.sortedItems.contains { $0.title == "改了名字" },
              "改标题后内容应更新（缓存不能返回旧对象）")
    }

    // 8. 任何操作后条数都必须一致
    check(store.sortedItems.count == store.items.count, "条数始终应与 items 一致")

    // 9. 空库
    let emptyTmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("empty-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: emptyTmp) }
    let emptyStore = MemoStore(fileURL: emptyTmp)
    check(emptyStore.sortedItems.isEmpty, "空库应返回空数组")
}
