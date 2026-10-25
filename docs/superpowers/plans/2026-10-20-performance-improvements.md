# AWS Platform 按需详情与列表性能改进

## 授权与目标

用户授权实施已提出的五项优化：EC2／Lambda 详情按页签查询，列表先显示基础数据再补状态／标签，限制 Lambda 源码缓存总量，复用源码高亮，以及大列表分页合并／筛选优化。基线提交为 `7a65d9a`；本轮不查询真实 AWS，不安装、推送或发布，不增加依赖，不创建 Goal。

可验证目标：概览不请求未打开的详情组；基础列表不等待辅助信息；同范围重复进入不重复请求；源码只保留当前函数；高亮相同文件不重复解析；S3 追加页不重排全部历史项；筛选结果在同一视图求值中复用。仅报告离线请求计数、模拟等待和固定工作负载的测量，不把它们解释为真实 AWS 延迟或整机收益。

## 已定边界与接口

- 延续 macOS 13、现有 SwiftUI 控件和视觉值；加载中、真正空结果、局部失败分别表达，不把尚未读取的数据当正常或空结果。所有新文案交由主 Agent 统一补齐中英文资源。
- 保留既有 VM 的注入入口与显式刷新语义。生产配置新增分组 loader；分组状态独立于基础详情，不以空数组判断是否加载。页签重复访问复用结果，失败／取消只通过明确刷新或重试再次调用。
- EC2 基础详情保留实例网络信息与 T 系列 CPU Credit；Storage 才查卷，Security 才查安全组，Status 才查完整状态详情。已有 Metrics／Target Groups 保持独立手动查询。
- Lambda 基础详情保留 `GetFunction` 提供的配置和日志组。Configuration 额外查 policy；Triggers 查 mappings／异步配置／URL；Versions 查版本／别名／预置并发。Code 下载、Metrics 和日志查询保持原有主动触发边界。
- 基础数据先显示，再有界补充。Lambda 状态／标签在补全期间明确提示筛选和搜索的已加载范围，未知状态不得显示为正常；EC2 AMI 与全列表健康状态独立补充，不能恢复到点击实例才查健康状态。辅助更新按稳定 ID 保留用户选择。
- Profile／Region／资源／刷新代次变化时取消相关任务并拒绝迟到成功或失败；A→B→A、同名资源跨范围与基础加载中切页均纳入回归。详情组只合并本组字段，不能覆盖其他已加载组。
- 源码仅保留当前函数；保留单文件和单部署包限制，重新查看已释放源码需手动加载。高亮结果只缓存当前文件，以路径、内容和外观正确失效；耗时词法扫描移出主 actor，保留可选择复制、Unicode 和长行。
- S3 保留 UTF-8 字节身份、folder marker 优先、新元数据覆盖、手动分页与选择保留；不改变 AWS 请求数量和传输行为。既有系统 List 保留，先复用同一次求值的筛选快照，不引入额外搜索框架。
- 单文件不得超过 1,000 行。与本轮直接相关的 AWS fetch／mapping 可以拆入服务 helper，避免扩大 VM；禁止顺手改造其他模块。

## 并行工作与所有权

### P1：Lambda 列表、详情分组、源码释放

所有权：`LambdaViewModel.swift`、`LambdaFunctionDetail.swift`、`Views/Lambda/LambdaDetailView.swift`、`LambdaListView.swift`，必要的新 Lambda loader／section 文件，以及对应新测试和直接受影响的既有 Lambda 状态测试。禁止修改 `LambdaCodeView.swift`、语言资源、EC2／S3、项目文档。

验收：基础列表在摘要被 gate 阻塞时已可见且可选；概览的其他组计数为零；分组首次一次、回访不重复、错误独立、刷新可重试；旧范围与旧资源结果无效；选函数不会被摘要补充跳回第一项；切换函数只保留当前源码。提交实际改动、测试与所需新文案，不运行 SwiftPM 或提交 Git。

### P2：EC2 列表与详情分组

所有权：`EC2ViewModel.swift`、`EC2InstanceDetail.swift`、`Views/EC2/EC2DetailView.swift`、`EC2ListView.swift`，必要的新 EC2 loader／section 文件及对应测试。禁止修改 Lambda／S3、高亮、语言资源、项目文档。

验收：AMI 被 gate 阻塞时实例已显示且健康查询已开始；健康覆盖全部列表；基础详情不查卷／安全组／状态详情，CPU Credit 仍可用；各组独立失败、重试与代次隔离；旧详情不能覆盖新列表健康结果。提交实际改动与测试，不运行 SwiftPM 或提交 Git。

### P3：S3 增量合并与列表筛选快照

所有权：`S3ObjectListing.swift`、`S3ViewModel.swift`、`Views/S3/S3ObjectListView.swift`、`S3BucketListView.swift`、`S3BrowserNavigation.swift` 及直接相关 S3 测试。禁止修改 Lambda／EC2、高亮、语言资源、项目文档。

验收：结果与基线算法在顺序、重复项、folder marker、Unicode 字节身份和元数据覆盖上等价；追加时保留选择与迟到响应保护；不在主 actor 重排整个历史列表；同次视图筛选复用。保持 `S3ObjectListing.merge` 可测试入口，主 Agent 用固定 1／10／50 页工作负载对照基线。提交实际改动与测试，不运行 SwiftPM 或提交 Git。

### P4：源码高亮复用

所有权：`Views/Lambda/LambdaCodeView.swift`、必要的新纯高亮器／当前预览状态文件、对应高亮测试。禁止修改 `LambdaViewModel`、`LambdaDetailView`、语言资源、EC2／S3、项目文档。

验收：同文件重复界面更新不重新解析；文件、内容、外观或函数改变后正确更新；后台旧结果不能覆盖新文件，取消不回填；文本、Unicode、换行和复制能力不变。静态正则复用，缓存有界，不保留之前函数源码。提交测试与可用于测量的解析入口，不运行 SwiftPM 或提交 Git。

### P0：主 Agent 集成与独立核验

所有权：计划／设计／双语 README／ROADMAP、语言资源、独立性能工作负载测试与跨模块集成。负责基线算法证据、统一编译、定向和全量测试、原生模拟交互验证、独立审查、精确暂存和中文本地提交。所有 worker 共享目录，不得回滚他人改动；跨所有权修改先协调。

## 验证顺序与交付

1. 固定基线源文件、模拟数据和请求计数断言，记录目录 `.tmp/performance-improvements-20261020/`。
2. 并行完成 P1–P4，主 Agent 统一运行严格 SwiftPM 定向测试；失败由 debugger 窄范围定位，避免并发构建锁。
3. 使用 gate 测量首屏先于辅助信息返回的行为，核对概览请求预算；使用固定 S3 页数、源码大小与重复预览场景记录前后计算／留存数据，不设置易抖动的墙钟失败阈值。
4. 执行严格 `swift test` 全量、`swift build`、Harness 静态门禁、语言资源和 diff 检查；原生交互使用模拟模型，独立审查重点核对范围与异步代次。
5. 更新当前状态和测量边界，提交已验证源码／测试／文档。交付实现结果、证据和未验证范围；本机安装与正式分发保持独立状态。

## 状态

- P1–P4：已完成；生产分组查询接线、范围代次保护及局部失败处理经独立源码审查。
- P0：已完成集成验证与项目文档同步，交付为本地源码；未安装、推送或发布。

## 验证与测量结果

- 2026-10-20 01:00：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 全量 1,408 项通过，比基线增加 63 项；同参数严格 `swift build` 通过。Harness task 的文件规模、diff 与设计 lint 通过，12 个规模警告，无 1,000 行硬上限失败；双语 plist、唯一键／键集回归与新增文案翻译测试通过。
- 生产 Lambda 分组通过独立的聚合器逐接口保留成功内容；权限失败组件有提示和重试，不把失败显示为 0 或真正空结果。直接聚合器、VM 联动、EC2 健康修订和 S3 后台合并均有回归。
- 原生离屏 NSHostingView 中验证实际页签 target/action：概览附加组调用为 0，首次访问各组为 1，回访不增加；检查 32 张英文／中文、浅色／深色模拟截图。加载／失败状态的 16 组标题 AX 坐标均距顶部 16 pt，修复前约 293／303 pt。窄英文 Lambda 菜单未暴露可定位的 AppKit／AX 控件节点，其位置通过截图复核；宽页签交互仍有真实原生断言。
- 实际源码视图的 Unicode／多行内容、横向滚动通过；离屏 SwiftUI 未暴露可选择的 NSTextView，交互式选择复制保留真实窗口验收。未改变既有 `textSelection` 设置。
- 高亮改用平衡 Text 拼接树。隔离的真实源码复现中，原线性树在 2,000 行／66,000 字节 resolve 时 SIGSEGV；修复后该样本及 10,000 行／330,000 字节的组件压力样本 resolve／释放成功，大样本加入全量回归。组件压力样本不改变生产单文件 200,000 字节预览限制。

以下计时来自同一台 arm64、macOS 27.0.1、Swift 6.4 的 Debug 离线工作负载，每项取 3 次中位数；旧算法固定为 `7a65d9a`，对应测试为 `PerformanceWorkloadTests`。S3 每行比较一次追加 1,000 项的合并计算，包含新页排序；不是累计读取全部页或 AWS 请求时间。

| 工作负载 | 基线 | 当前 |
| --- | ---: | ---: |
| S3 空列表追加 1,000 项 | 20.983 ms | 20.698 ms |
| S3 已有 9,000 项追加 1,000 项 | 193.820 ms | 21.143 ms |
| S3 已有 49,000 项追加 1,000 项 | 1,153.995 ms | 22.381 ms |
| 3,300 字节源码重复构建／update 10 次 | 6.194 ms，解析 10 次 | 0.790 ms，解析 1 次 |
| 20 个函数各含约 100 KiB 源码的逻辑 UTF-8 留存 | 2,048,190 字节 | 102,410 字节 |

首批 S3 合并基本持平，大目录续页改善；高亮共同对照使用双方均可安全 resolve 的 100 行源码，计时只包含构建／update，不包含 SwiftUI 布局或绘制。源码留存为模型字符串 payload 计数，基线模拟逐函数保留，当前路径使用实际 VM；不是物理内存或 RSS。未测量真实 AWS 延迟、整机峰值、安装包和 Intel／macOS 13 实机。

过程证据位于 `.tmp/performance-improvements-20261020/`：`baseline/manifest.json`、`full-tests.log`、`strict-build.log`、`harness-task-final.log`、`results.json`、`isolation-repro/text-tree-{before,after}-results.json` 和 `screenshots/`。复现可运行上述全量命令，或仅筛选 `PerformanceWorkloadTests`／`PerformancePresentationTests`／`LambdaCodeHighlighterTests`；全程使用模拟资源，不调用真实 AWS。
