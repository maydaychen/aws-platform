# CodeCommit 只读仓库查询

## 目标与边界

用户授权在现有 AWSPlatform 加入 CodeCommit 查询。第一版提供当前已验证 Profile／Region 的仓库列表、本地搜索、仓库元数据、分支及分支最新提交；支持手动刷新、取消和复制字段。只使用 ListRepositories、GetRepository、ListBranches、GetBranch、GetCommit，不克隆、不推送、不读取源码文件、不修改仓库。沿用现有身份绑定与显式 Profile 规则，不调用真实 AWS、不推送或发布；不是 Goal。

CodeCommit 为独立一级区域服务。复用现有 Soto 依赖中的 SotoCodeCommit product，不增加第三方依赖或升级锁文件。列表和分支完整分页，有界页数／循环令牌检测；空仓库／无匹配／权限失败分开，部分详情失败保留已成功数据。新服务本轮不加入收藏／最近访问，既有保存导航须明确拒绝不支持的 CodeCommit 目标。

## C1：模型、服务与服务回归（backend worker）

- 所有权：新增 `Models/CodeCommitModels.swift`、`Services/AWSCodeCommitService.swift`、`Tests/AWSPlatformTests/AWSCodeCommitServiceTests.swift` 及确有需要的专用 fixtures；禁止修改现有 Provider／Package／VM／UI／词条／文档。
- 模型接口：`CodeCommitRepository: Identifiable, Hashable, Sendable`，`id: String, name: String`；`CodeCommitRepositoryDetail: Equatable, Sendable`，`id, name, arn, accountID: String`，`description, defaultBranch, cloneURLHTTP, cloneURLSSH: String?`，`creationDate, lastModifiedDate: Date?`；`CodeCommitCommit: Equatable, Sendable`，`id: String`，`message, authorName, authorEmail, authorDate, committerName, committerEmail, committerDate: String?`，`parentIDs: [String]`。
- 服务接口：`AWSCodeCommitService(provider:)`；`loadRepositories(scope: MonitoringScope) async throws -> [CodeCommitRepository]`；`loadRepository(scope: MonitoringScope, repositoryName: String) async throws -> CodeCommitRepositoryDetail`；`loadBranches(scope: MonitoringScope, repositoryName: String) async throws -> [String]`；`loadCommit(scope: MonitoringScope, repositoryName: String, branchName: String) async throws -> CodeCommitCommit`。最后一项先 GetBranch 再按该 SHA 调 GetCommit，不能混入另一个分支。请求级 operations 注入，方便用 Soto shapes 离线测试。
- 生产 operations 从 `provider.codeCommitClient(scope:)` 获得身份绑定区域 client（由主 Agent 加入）。验证 scope、仓库名／分支名、返回仓库名／账号／ARN与当前范围，以及返回提交 SHA 与 GetBranch 一致。错误按操作脱敏，不回显任意响应／凭据，文案列表交主 Agent 本地化。
- 验收：两种列表的多页／空页／重复令牌／预算／中途失败／取消，空仓库，局部权限失败、错误脱敏、错误仓库／账号／区域／SHA、分支和提交两次请求绑定。请求只允许上述五项读 API；不运行 SwiftPM（主 Agent 统一执行）。

## C2：状态流与回归（viewmodel worker）

- 所有权：新增 `ViewModels/CodeCommitViewModel.swift`、`Tests/AWSPlatformTests/CodeCommitViewModelTests.swift`；禁止修改 C1、Provider／Package、UI／词条／文档。使用 C1 以上模型与服务接口，依赖未落盘时可先写文件，不自行改接口。
- 对 UI 接口：`repositories: [CodeCommitRepository]`、`selectedRepository: CodeCommitRepository?`、`repositoryDetail: CodeCommitRepositoryDetail?`、`branches: [String]`、`selectedBranch: String?`、`commit: CodeCommitCommit?`、`searchText: String`、`filteredRepositories`；`isLoading, isRepositoryLoading, isBranchesLoading, isCommitLoading: Bool`，`error, repositoryError, branchesError, commitError: String?`；只读 `scope: MonitoringScope?`。
- 方法：`init(provider:)` 用 service closures 包装；另提供注入 initializer（四种 loader 参数分别对应 C1 方法，scope必须显式传入）；`configure(scope:)` 仅绑定／重置；`loadIfNeeded()`、`refresh()`、`cancelLoading()`、`reset()`、`refreshRepository()`、`refreshCommit()`；`selectedRepository`／`selectedBranch` 变更触发对应详情读取。默认分支仅使用 API 返回且存在于分支列表中的名称，不硬编码 main/master，用户已手动选分支时不被迟到默认值改回。
- 保持列表／元数据／分支／提交各自错误与加载状态。元数据和分支独立读取，分支权限失败不隐藏元数据。刷新保留同仓库／同分支选择；切换 Profile／Region、仓库、分支或取消使旧代次失效并清除旧详情。未绑定有效 scope 不调用 loader。无仓库／无分支保持明确空状态。
- 验收：无 scope 零调用、正常搜索与默认分支、空仓库零提交请求、列表与详情／分支局部失败、刷新恢复、取消、相同仓库／分支跨 scope 和同 scope 刷新迟到回调、不自动选择Profile。取消仍沿用清空详情的语义；选中仓库时，已清空的元数据／分支都显示取消提示，不能误报「没有分支」，覆盖仅提交请求尚在加载的情况。不运行 SwiftPM。

## C3：接入、视图和文档（主 Agent）

维护 Package／Provider 的 scoped client、AWSService／ContentView／FavoriteNavigation 集成，双语词条、原生列表／详情和设计规范。保持 ContentView 少于 1000 行；新 UI 分文件放入 `Views/CodeCommit/`。使用现有 ListToolbar、DetailFieldRows、DetailSectionTitle、语义颜色与字号，保留长 ARN／SHA／URL 复制和换行；Git 时间戳保持原文，不伪装成已解析 Date。错误、空仓库、空分支和无匹配分别提示。

## C4：独立只读验收

审查 C1/C2/C3 的真实 diff 与必要证据，重点 query scope、代次／取消、分页完整性、空仓库／局部权限、返回资源身份和只读 API 范围。不修改生产代码、不构建、不Git写入、不调用AWS。证据目录 `.tmp/codecommit-query/verification/`。主 Agent最小复核结果后统一严格构建／测试、双语／Harness、必要窄宽／中英文／深浅色原生渲染，更新 README／ROADMAP 并提交本次内聚改动。

## 当前状态

2026-10-18 07:56：C1/C2/C3 已完成，C4 最终源码／截图独立复核无阻断项。最终严格并发／警告视为错误的全量 `swift test` 988 项、`swift build`、Harness task 三项静态门禁与双语 plist 校验通过。新增 51 项回归；两个语言各 1,560 个唯一匹配 key，56 条 CodeCommit 文案校验通过；ContentView 为 952 行。13 个文件规模警告无硬上限失败。

9 张离屏原生截图覆盖 280 pt 列表、480 pt 详情、中英／深浅色、长仓库／ARN／地址／分支／提交、局部权限与空分支，主 Agent 和独立验收检查通过。截图夹具显式绘制背景与显示原生控件，修正初轮透明背景造成的捕获缺口。实施中补齐两种提交 ID 缺失错误分类，以及仅提交加载时取消清详情却误报无分支的回归。

源码验证日志、词条检查和截图保存在 `.tmp/codecommit-query/`。2026-10-18 13:10 按用户追加授权，已从固定提交 `27ccb68` 的 312 文件隔离快照完成 `arm64` Release 构建，安装并打开本机预览 `0.3.1 (15)`；App／ZIP／源码与安装清单位于 `dist/local-preview-arm64-codecommit-27ccb68/`，旧 `0.3.1 (14)` 原样备份至其 `previous-installations/20261018-131006/AWSPlatform.app`。安装副本与构建包一致，原生 API 确认启动完成且 8 秒后仍有可见窗口。过程和独立核验在 `.tmp/codecommit-preview-install/`；未主动选择 Profile、执行真实 AWS 查询、推送、发布或修改更新源。真实账号权限／服务行为、实际窗口手动交互及 Intel／macOS 13 实机仍待专项验收。
