# Repository Guidelines

## Project Structure & Module Organization

This repository is a Swift Package for a macOS SwiftUI app, `AWSPlatform`.

- `Package.swift` defines the executable target, macOS 13 minimum, Swift 5.9 tools, and Soto dependencies.
- `Sources/AWSPlatform/App.swift` is the app entry point; `ContentView.swift` hosts the main shell.
- `Sources/AWSPlatform/Models/` contains lightweight domain models for AWS profiles, EC2, Lambda, and S3.
- `Sources/AWSPlatform/Services/` owns AWS client/provider integration.
- `Sources/AWSPlatform/ViewModels/` contains observable UI state.
- `Sources/AWSPlatform/Views/` contains SwiftUI views, grouped by AWS service plus shared shell components.
- `Tests/AWSPlatformTests/` contains config parsing and view model unit tests.
- `docs/superpowers/` contains design specs and implementation planning notes.
- `ROADMAP.md` is the source of truth for current progress and validation status.

Keep non-trivial parsing and view model state transitions covered by the existing test target.

## Build, Test, and Development Commands

```bash
swift build
```
Builds the Swift package and resolves Soto dependencies.

```bash
swift run
```
Builds and launches the macOS app from the command line.

```bash
swift test
```
Runs the package test suite.

```bash
open Package.swift
```
Opens the package in Xcode for interactive SwiftUI development and Cmd+R runs.

## Coding Style & Naming Conventions

Use standard Swift API Design Guidelines: types in `UpperCamelCase`, methods and properties in `lowerCamelCase`, and clear nouns for models/view models. Keep SwiftUI view files focused on composition; move AWS calls and async state into services or view models. Use 4-space indentation, prefer `let` over `var`, and keep service-specific UI inside `Views/<Service>/`.

## Testing Guidelines

When adding tests, create a `Tests/AWSPlatformTests/` target in `Package.swift`. Name test files after the unit under test, such as `ConfigReaderTests.swift`, and use behavior-focused `test...` method names. Prefer unit tests for parsing, model mapping, and view model state transitions. Avoid live AWS calls; inject mock service providers.

## Commit & Pull Request Guidelines

Recent history uses concise messages with either Conventional Commit style (`docs: add README.md...`) or a short imperative summary (`Initial commit: ...`). Continue with messages like `feat: add EC2 refresh action` or `fix: handle missing AWS region`.

Pull requests should include a short description, verification steps (`swift build`, `swift test` when available), screenshots for UI changes, and notes for AWS credential, region, or permission assumptions.

## Security & Configuration Tips

Do not commit AWS credentials, generated local config, or Xcode user state. The app expects AWS CLI profiles in `~/.aws/config` and `~/.aws/credentials`; keep examples sanitized and use profile names rather than secrets in docs and tests.

## AWS Query Scope

- 当前及后续新增的 AWS 数据查询（包括资源、Cost、指标和日志）统一以用户显式选择的当前 Profile 为单位；查询凭据、调用账号和角色由该 Profile 决定。Region 按服务语义使用当前选择或资源实际区域（如 S3 Bucket），区域解析不得改变 Profile 查询作用域；实际可见范围仍受 AWS 服务和该角色权限约束。
- Session 只负责 SSO 登录与授权缓存，不作为数据查询单位；不得因多个 Profile 共用 Session 而自动查询或聚合这些 Profile 的数据。
- 未选择 Profile 时，不进行账号身份验证或 AWS 数据查询，资源列表与详情保持空白；不得回退到默认、上次使用、第一个 Profile 或环境变量指定的 Profile。
- 启动、Session 登录成功、重新登录或切换 Session 均不得自动选择 Profile；只有手动选择 Profile 并验证身份成功后才加载数据。收藏及后续新增入口也必须遵守此规则。
- 切换或清空 Profile 时，清空旧数据并取消旧请求或使其结果失效；查询状态和缓存按 Profile 隔离，区域型查询同时按 Region 隔离，防止跨 Profile 展示数据。
- 凭据续期必须使用新取得的同一组凭据验证账号与稳定主体后才允许业务请求；账号或角色变化时使整个验证代次失效并要求重新验证。正常续期的 STS session 名变化不代表角色变化，凭据内容不得写入日志。

## S3 File Transfers

- S3 允许用户主动发起当前已验证 Profile 的单文件上传与下载；EC2 另允许下述用户主动发起的外部 SSM 会话，其他服务继续只读。不调用对象删除、ACL／标签写入或 Bucket 配置写入接口；覆盖上传不复制原对象的元数据、标签及 ACL，必须在确认提示中说明。
- 传输绑定 Profile、STS 账号／角色、配置路径与 Bucket 实际 Region，未选或未验证 Profile 时禁用入口；切换、清空或重新验证范围时取消旧任务并使旧回调／确认弹窗失效。取消不能撤销已由 AWS 接收的写入，不自动回滚远端对象。
- 上传前显示 Profile／账号、Bucket、完整 Key 和本地文件，由用户确认后执行。新建使用条件写防止意外覆盖；覆盖需再次明确确认，并绑定已检查对象的 ETag，不以先检查再无条件上传替代并发保护。文件内容不整段载入内存。
- 上传确认绑定流式准备的私有文件副本与 SHA-256，S3 请求携带相同校验值；副本准备失败、确认取消及传输结束后清理本地副本。下载绑定所选对象的 ETag／大小，检查磁盘容量并在写入前限制累计字节；保存和清理操作绑定已打开的父目录，不随路径替换重定向。S3 浏览与传输都携带当前已验证账号的 Bucket owner 条件。
- 下载由用户选择本地目标，使用同目录临时文件，完整成功后提交；新文件使用排他提交。覆盖现有本地文件时原子交换并保留被替换文件为同目录恢复副本，完成提示提供位置；检查与提交之间的并发编辑不得被静默丢弃。提交前失败或取消清理临时文件并保留原文件，交换后的恢复副本不得按临时文件删除。云端 Key 不直接作为本地路径拼接。
- 自动化验证只使用模拟传输和任务临时文件；不得为测试向真实 S3 写入、覆盖或删除数据。

## EC2 SSM Connections

- 仅用户点击当前运行实例的 Connect 后，通过系统对 `.command` 的默认关联程序启动外部 SSM 会话；不内置终端、不自动连接、不修改实例、IAM 或 SSM 配置。
- 连接绑定当前已验证 Profile、账号／角色、Region、AWS 配置路径和实例 ID；从显式 Profile 解析一次凭据，使用同一组内存凭据核对身份并发起连接，业务调用不得重新解析 Profile 或受继承凭据／配置影响。凭据不写入脚本、磁盘、命令行参数或日志。未选／未验证 Profile 或旧实例范围失效时禁用入口；移交终端后会话由终端管理，切换应用范围不终止已移交会话。
- 生成的私有一次性脚本只保存定位信息，不写入凭据；执行结束或移交失败时清理。自动化测试注入启动器与本地 CLI 替身，不调用真实 AWS 或建立远程会话。

## Update Distribution Trust

- Sparkle 框架与发布助手只从固定官方包校验值验证过的私有暂存目录消费；不得直接执行或重新签名普通构建缓存中的助手／框架。组件版本、校验值与依赖锁文件保持一致，校验失败先停止再进入签名步骤。
- 更新包与 Feed 都必须使用专用 Ed25519 公钥验证，Feed 变动后重新签名，安装前先验证归档再解压；签名不证明服务器始终提供最新内容。测试不访问真实签名密钥，密钥丢失时保留手动安装的恢复路径。

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

<!-- HARNESS_VERIFICATION_START -->

## Harness 验证

- 验证事实源：`.harness/verification.json`。
- 固定入口：`scripts/verify-before-push.sh`。
- Profiles：待确认。
- Adapters：无。
- 文件规模门禁：超过 500 行警告，超过 1000 行失败。
- `.` 检查：source-file-lines, swift-package-build, swift-package-test, git-diff-check, design-spec-lint。

<!-- HARNESS_VERIFICATION_END -->

## 设计规范与验证入口

- 根目录 `DESIGN.md` 是可复用视觉规范；现有 SwiftUI 主题／组件入口：`Sources/AWSPlatform/ContentView.swift`、`Sources/AWSPlatform/Views`、`Sources/AWSPlatform/App.swift`。foundation 由主题入口维护，公共组件与功能目录消费语义样式。
- 生成 primitive token 不适用：现有原生组件已有消费者，本轮不新增无消费者的 CSS／JSON 产物。
- 运行 `python3 scripts/harness/verify.py --mode task` 执行静态门禁；设计结构由固定版本 `@google/design.md@0.4.0` lint 检查，需要 Node.js／npm，缓存只在 `.tmp/design-md/`。
- 系统动态语义颜色／字体，以及 0、1 pt 细描边、百分比、图表坐标属于结构例外；新增自定义视觉值先更新 `DESIGN.md` 并归入主题／公共组件。设计硬编码 baseline、增量扫描和全部主题自动验收尚未接入，缺口见 `ROADMAP.md`；结构 lint 不等于完整设计治理验收。
- 当前共享检测器没有对应的 SwiftPM macOS Profile／Adapter；配置保留空检测结果，通过已确认的原生构建／测试命令提供实际门禁，不按 XcodeGen 工程初始化。
