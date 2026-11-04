import Foundation

// 用 RunLoop 驱动主线程，@MainActor 任务才能真正执行（信号量会死锁）
var finished = false
Task { @MainActor in
    runTests()
    finished = true
}
let deadline = Date().addingTimeInterval(30)
while !finished && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
exit(failures == 0 && finished ? 0 : 1)
