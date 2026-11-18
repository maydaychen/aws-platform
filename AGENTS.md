# 代理执行手册

AWS Platform 是面向 AWS 使用者的原生 macOS 资源与费用浏览工具，采用 SwiftUI、Swift Package 和 Soto，按用户显式选择的 AWS CLI Profile 隔离查询，并支持用户主动发起的 S3 文件传输与外部 EC2 SSM 会话。本文件是代理执行手册，不是项目介绍；产品介绍与使用方式见 `README.md`。

## 项目结构与模块组织

本仓库通过 Swift Package 组织 macOS SwiftUI 应用 `AWSPlatform`。

- `Package.swift`：定义可执行目标、macOS 13 最低版本、Swift 5.9 工具版本和 Soto 依赖。
- `Sources/AWSPlatform/App.swift`：应用入口；`ContentView.swift` 承载主界面框架。
- `Sources/AWSPlatform/Models/`：AWS Profile、EC2、Lambda 和 S3 等轻量领域模型。
- `Sources/AWSPlatform/Services/`：AWS 客户端与服务提供方集成。
- `Sources/AWSPlatform/ViewModels/`：可观察的界面状态。
- `Sources/AWSPlatform/Views/`：按 AWS 服务组织的 SwiftUI 视图及共享框架组件。
- `Tests/AWSPlatformTests/`：配置解析与视图模型单元测试。
- `docs/superpowers/`：设计式样与实施规划记录。
- `ROADMAP.md`：当前进度和验证状态的事实源。

非简单解析逻辑和视图模型状态流转须由现有测试目标覆盖。

## 构建、测试与开发命令

```bash
swift build
```
构建 Swift 包并解析 Soto 依赖。

```bash
swift run
```
从命令行构建并启动 macOS 应用。

```bash
swift test
```
运行包内测试套件。

```bash
open Package.swift
```
在 Xcode 中打开包，进行交互式 SwiftUI 开发并通过 Cmd+R 运行。

## 代码风格与命名约定

遵循标准 Swift API 设计指南：类型使用 `UpperCamelCase`，方法和属性使用 `lowerCamelCase`，模型与视图模型使用含义清晰的名词。SwiftUI 视图文件聚焦界面组合，AWS 调用和异步状态放到服务或视图模型。使用四个空格缩进，优先使用 `let`，服务专属 UI 放在 `Views/<Service>/`。

## 测试指南

`Package.swift` 已定义测试目标 `AWSPlatformTests`；新增测试放入现有 `Tests/AWSPlatformTests/`，无需重复创建目标。文件按被测单元命名，例如 `ConfigReaderTests.swift`，方法以 `test...` 开头并描述行为。优先对解析、模型映射和视图模型状态流转编写单元测试；注入模拟服务提供方，不调用真实 AWS。

## 提交与 Pull Request 规范

已有历史使用简短的 Conventional Commit 或动作摘要；提交示例为 `feat: 增加 EC2 刷新入口`、`fix: 处理 AWS 区域缺失`。

PR 应包含简要说明、验证步骤（适用时运行 `swift build`、`swift test`）、UI 变更截图，以及 AWS 凭据、区域或权限假设说明。

## 安全与配置提示

不得提交 AWS 凭据、生成的本地配置或 Xcode 用户状态。应用使用 `~/.aws/config` 和 `~/.aws/credentials` 中的 AWS CLI Profile；示例必须脱敏，文档和测试使用 Profile 名称而非密钥。

## AWS 查询作用域

- 当前及后续新增的 AWS 数据查询（包括资源、Cost、指标和日志）统一以用户显式选择的当前 Profile 为单位；查询凭据、调用账号和角色由该 Profile 决定。Region 按服务语义使用当前选择或资源实际区域（如 S3 Bucket），区域解析不得改变 Profile 查询作用域；实际可见范围仍受 AWS 服务和该角色权限约束。
- Session 只负责 SSO 登录与授权缓存，不作为数据查询单位；不得因多个 Profile 共用 Session 而自动查询或聚合这些 Profile 的数据。
- 未选择 Profile 时，不进行账号身份验证或 AWS 数据查询，资源列表与详情保持空白；不得回退到默认、上次使用、第一个 Profile 或环境变量指定的 Profile。
- 启动、Session 登录成功、重新登录或切换 Session 均不得自动选择 Profile；只有手动选择 Profile 并验证身份成功后才加载数据。收藏及后续新增入口也必须遵守此规则。
- 切换或清空 Profile 时，清空旧数据并取消旧请求或使其结果失效；查询状态和缓存按 Profile 隔离，区域型查询同时按 Region 隔离，防止跨 Profile 展示数据。
- 凭据续期必须使用新取得的同一组凭据验证账号与稳定主体后才允许业务请求；账号或角色变化时使整个验证代次失效并要求重新验证。正常续期的 STS session 名变化不代表角色变化，凭据内容不得写入日志。

## S3 文件传输

- S3 允许用户主动发起当前已验证 Profile 的单文件上传与下载；EC2 另允许下述用户主动发起的外部 SSM 会话，其他服务继续只读。不调用对象删除、ACL／标签写入或 Bucket 配置写入接口；覆盖上传不复制原对象的元数据、标签及 ACL，必须在确认提示中说明。
- 传输绑定 Profile、STS 账号／角色、配置路径与 Bucket 实际 Region，未选或未验证 Profile 时禁用入口；切换、清空或重新验证范围时取消旧任务并使旧回调／确认弹窗失效。取消不能撤销已由 AWS 接收的写入，不自动回滚远端对象。
- 上传前显示 Profile／账号、Bucket、完整 Key 和本地文件，由用户确认后执行。新建使用条件写防止意外覆盖；覆盖需再次明确确认，并绑定已检查对象的 ETag，不以先检查再无条件上传替代并发保护。文件内容不整段载入内存。
- 上传确认绑定流式准备的私有文件副本与 SHA-256，S3 请求携带相同校验值；副本准备失败、确认取消及传输结束后清理本地副本。下载绑定所选对象的 ETag／大小，检查磁盘容量并在写入前限制累计字节；保存和清理操作绑定已打开的父目录，不随路径替换重定向。S3 浏览与传输都携带当前已验证账号的 Bucket owner 条件。
- 下载由用户选择本地目标，使用同目录临时文件，完整成功后提交；新文件使用排他提交。覆盖现有本地文件时原子交换并保留被替换文件为同目录恢复副本，完成提示提供位置；检查与提交之间的并发编辑不得被静默丢弃。提交前失败或取消清理临时文件并保留原文件，交换后的恢复副本不得按临时文件删除。云端 Key 不直接作为本地路径拼接。
- 自动化验证只使用模拟传输和任务临时文件；不得为测试向真实 S3 写入、覆盖或删除数据。

## EC2 SSM 连接

- 仅用户点击当前运行实例的 Connect 后，通过系统对 `.command` 的默认关联程序启动外部 SSM 会话；不内置终端、不自动连接、不修改实例、IAM 或 SSM 配置。
- 连接绑定当前已验证 Profile、账号／角色、Region、AWS 配置路径和实例 ID；从显式 Profile 解析一次凭据，使用同一组内存凭据核对身份并发起连接，业务调用不得重新解析 Profile 或受继承凭据／配置影响。凭据不写入脚本、磁盘、命令行参数或日志。未选／未验证 Profile 或旧实例范围失效时禁用入口；移交终端后会话由终端管理，切换应用范围不终止已移交会话。
- 生成的私有一次性脚本只保存定位信息，不写入凭据；执行结束或移交失败时清理。自动化测试注入启动器与本地 CLI 替身，不调用真实 AWS 或建立远程会话。

## 匿名分发信任边界

- 发布安装包统一使用 Universal（`arm64` + `x86_64`）本地 Ad-hoc 签名构建，不嵌入个人 Developer ID 证书或非空 `TeamIdentifier`，也不集成依赖团队签名校验的应用内更新框架。
- 打包前须通过 `collect-licenses.py` 随包收集已锁定依赖的完整第三方许可，并通过构建路径重映射、调试符号剥离、`privacy_scan.py`（配合外置私有词表）及 `anonymous_release_check.py` 结构化匿名断言。
- 自动化测试只运行离线校验逻辑，不访问真实签名身份、钥匙串私有配置或远端发布接口。

<!-- CODEGRAPH_START -->
## CodeGraph

仓库根目录存在 `.codegraph/` 时，理解或定位代码必须先使用 CodeGraph，再使用文本检索或直接读取源码：

- **MCP 工具**（可用时）：`codegraph_explore` 通常一次调用即可返回相关符号的原始源码及其调用路径，包括文本检索难以追踪的动态分派。查询中指定文件或符号，可读取当前带行号的源码；工具已列出但尚未加载时，按名称搜索并加载。
- **Shell 命令**：`codegraph explore "<symbol names or question>"` 返回相同信息。

不存在 `.codegraph/` 时跳过 CodeGraph；是否建立索引由用户决定。
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
