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
    testSpaceChangeSyncOrb()
    testOrbRevealRespectsToggle()
    testOrbAbsorbRespectsToggle()
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
        ("low",    (0.020,0.541,0.478), (0.157,0.741,0.671)),
    ]
    // 强调色按外观分别取值
    let accentLight: (Double,Double,Double) = (0.427, 0.247, 0.878)
    let accentDark:  (Double,Double,Double) = (0.655, 0.545, 0.980)

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

    // 强调色不能和任何优先级的色相相同——否则界面里
    // "可交互"和"某档优先级"会撞色
    for (name, light, _) in palette {
        let dist = pow(pow(accentLight.0 - light.0, 2)
                     + pow(accentLight.1 - light.1, 2)
                     + pow(accentLight.2 - light.2, 2), 0.5)
        check(dist > 0.5, "强调色与 \(name) 太接近（距离 \(String(format: "%.2f", dist))）")
    }
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
