# AWS CLI 版本检测与更新

## 范围与决定

用户要求检测 AWS CLI 版本，提示可更新并在点击后执行更新。设置新增 AWS CLI 分组，显示实际生效路径、安装来源、本地／可用版本、检查状态、更新阶段和结果。设置首次打开时检查，重复点击去重；仅用户点击更新才运行安装，不在启动或检查时安装工具，不调用真实 AWS 或读取 Profile 凭据。版本子进程显式使用 `/dev/null` 作为 AWS config／credentials 路径，避免 CLI 在解析 `--version` 前加载用户配置或插件；SSO／凭据导出的配置保持原有行为。

沿用 `AWSCLIConfiguration.executable()` 的路径优先级。官方系统 PKG 安装使用 AWS 固定版本 PKG；Homebrew 使用对应前缀的 brew；未知、自定义、冲突或无法验证的安装保留手动安装指引，不自动切换渠道，不卸载、覆盖链接或解除 pin。

官方可用版本来源固定为 `https://awscli.amazonaws.com/v2/version.txt`，Homebrew 来源为 `https://formulae.brew.sh/api/formula/awscli.json`。版本严格数字解析，不接受远端提供的可执行命令或下载地址。官方包地址按已检查的版本构造，验证 Apple 信任及 AWS Installer 团队 `94KV3E626L`；系统管理员授权后再次绑定文件哈希与签名，使用根拥有的私有副本安装，不执行网络下载的脚本。Homebrew 不以 root 运行，升级可能包含必要依赖，界面明确说明。

更新结束重新检测同一实际生效入口及渠道，只有版本达到目标才成功。下载／检查有大小和时间边界，安装开始后不以普通请求取消机制杀安装子进程；关闭设置不丢任务，退出和 Sparkle 重启等待安装完成。更新期间禁止新 S3 传输、应用内 CLI 登录／导出凭据／Connect 移交，活动 CLI 请求或 S3 传输存在时不启动更新；已移交外部终端的会话继续由终端管理。

## 任务与接口

所有参与者保留他人改动，仅修改自己的文件；不运行真实升级，不并行运行 SwiftPM，不自行提交。主线统一维护本地化、文档、App 接线、ViewModel 和最终验证。

- A：`Models/AWSCLIVersion.swift`、`Services/AWSCLIInspector.swift`、`AWSCLIVersionCatalog.swift`、`AWSCLIHTTPClient.swift` 与对应测试；`CredentialProcessRunner.run` 仅增加默认关闭的 `captureStandardError` 选项供 `--version` 复用。`AWSCLIVersion` 提供 `major/minor/patch`、`description`、数字比较和严格 `init?(String)`；`AWSCLIInstallSource` 为 `.officialPackage`、`.homebrew(prefix: URL, executable: URL)`、`.unmanaged`，提供来源显示与可自动更新判断。`AWSCLIInstallation` 保存 `executableURL/resolvedURL/version/source`。`AWSCLIUpdatePhase` 为 downloading/verifyingPackage/installing/verifyingInstallation/refreshingHomebrew。`AWSCLIUpdateError` 使用固定脱敏错误。
- A 的公开服务接口：`AWSCLIInspector().inspect() async throws -> AWSCLIInstallation?`、`AWSCLIVersionCatalog().latest(for: AWSCLIInstallSource) async throws -> AWSCLIVersion`；HTTP 为 `data(from:maximumBytes:)` 和 `download(from:to:maximumBytes:)`，支持注入 URLSessionConfiguration 测试，限制 HTTPS 固定主机／路径、响应大小、超时及重定向。
- B：`Services/AWSCLIInstaller.swift`、`AWSCLIInstallProcess.swift` 与对应模拟测试。接口 `AWSCLIInstaller().update(_ installation: AWSCLIInstallation, to version: AWSCLIVersion, progress: @escaping @Sendable (AWSCLIUpdatePhase) -> Void) async throws`。下载私有暂存、签名／哈希、根拥有私有副本的再次验证、系统授权、Homebrew 指定 formula 更新及进程完成管理；命令全部固定参数或严格转义。错误与原始安装输出分离，不将环境凭据交安装进程。
- C：`Services/AWSCLIOperationGate.swift`、`TransferActivity.swift`、`AppUpdateController.swift`、`AWSSSOLoginService.swift`、`AWSCLICredentialProvider.swift`、`EC2SSMConnectionService.swift`、`S3TransferViewModel.swift` 与相关测试。Gate 是带锁的 Sendable 共享协调器，提供 shared、beginOperation/endOperation、beginUpdate/endUpdate，更新与实际 CLI 请求互斥。TransferActivity 增加独立 cliMaintenanceActive 与 beginCLIMaintenance/finishCLIMaintenance，S3 activeCount 仍只计传输；终止／重启等所有活动完成，新传输在维护期拒绝。
- D：`Views/AWSCLISettingsSection.swift`、`SettingsView.swift` 与原生模拟呈现测试。消费主线 `AWSCLIUpdateViewModel` 的 installation/latestVersion/isChecking/isUpdating/phase/error/status、canCheck/canUpdate、checkIfNeeded/check/update/waitForCurrentTask，不在 View 内执行网络／进程。Settings 新增 cliUpdates 参数，由 App 持有；界面遵循已更新 DESIGN。
- 主线：ViewModel 注入 detect/latest/install 闭包，单个全局更新任务；绑定更新前安装快照、更新租约和操作 Gate，安装后重读入口及目标版本；错误和取消不误报成功。同步语言、使用说明、设计、进度与提交。

## 验证

- 版本：数字比较、v1／未知格式、缺失工具、多路径／渠道识别、Homebrew receipt／前缀及官方 receipt／二进制信任；只读检测不更新包或查询账号。
- 网络：固定主机、错误／重定向／过大／超时／取消、非 2.x.y 版本、Homebrew 名称不匹配；不从远端内容执行代码。
- 更新：重复点击、安装路径改变、错误签名／团队／哈希、授权取消、安装失败／未达目标、同入口成功、关闭设置仍持续；管理员密码只进系统对话框。
- 协调：活跃 SSO／导出请求和 S3 阻止更新，更新期间新请求被拒绝，结束／失败释放租约，退出／Sparkle 只继续一次，S3 数量和文案不混淆。
- UI：中英／深浅色、长路径／错误与更新阶段、真实原生按钮仅触发注入计数器；不操作用户剪贴板、真实安装器、Homebrew 升级或 AWS。
- 严格构建、定向与最终全量离线测试、双语／设计／差异门禁和独立代码／证据复核。实际 CLI 升级与管理员授权不作为自动化测试执行。

## 当前状态

CLI 设置精简最初随固定提交 `0913f4b` 的本机预览 `0.4.1 (23)` 完成验收，严格构建及 39 项定向回归通过。后续设置页语言与应用更新两处常驻说明已随源提交 `ffe4a02` 的本机 `0.4.1 (24)` 移除，主线与独立实际 AX／截图核验通过，当前页面已留在设置；最新安装记录见 `ROADMAP.md`。检测／安装／任务门禁未修改，旧版备份保留；未执行真实 CLI 升级或 AWS 查询。

## 验证结果

- 最终 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`：1,559 项正式离线测试，零失败，较前批增加 82 项。最终严格主程序构建通过；验证前后 360 个源码／测试／Package 文件 SHA-256 相同。证据为 `.tmp/aws-cli-update/full-test.log`、`build-final.log` 与 `verified-source.json`。
- 144 项定向回归通过；4 项原生 NSHostingView 测试生成 23 张中英／深浅色、长路径、渠道、错误、阶段和滚动图，模拟真实点击验证更新去重。主线与独立复核查看代表图。SwiftUI Form 的虚拟 Text／Link 不暴露为 NSView 值，初版断言已按实际截图 OCR 核对完整可见文案；未改生产显示来绕过测试。
- 补强空配置后的只读临时探针 1 项通过，实际生产 Inspector／Catalog 识别官方 `2.37.9`、可用 `2.38.5`，日志 `read-only-probe.log`；探针只调用版本／receipt／签名和公开元数据，无账号凭据与业务 API，临时入口已移除，不计入离线总数。
- 安装器与下载测试使用注入 Downloader／Runner、URLProtocol 和私有临时文件。离线进程烟测覆盖有界输出、取消后等待实际结束、FD 身份、shell 语法、AppleScript 仅编译、假包验证／清理；管理员侧副本复制有大小边界。未调用真实授权、installer 或 brew 更新。
- 双语各 1,921 个唯一键、占位符／plist、Harness task（369 个维护文件，12 个既有规模警告）和独立源码／证据复核通过。保留既有 NSTableView 重入及两条 RDS 几何运行时诊断，不将严格编译通过表述为没有任何运行时诊断。
- 上述源码验收阶段未更换本机应用；后续本机安装已完成。实际 CLI 升级、管理员授权、PKG／Homebrew 完整更新、Intel／macOS 13 实机、推送及公开发布不在本次安装验收内。

## 设置精简（已完成并安装）

- 用户要求正常状态只显示版本、安装来源与「检查／更新」两个按钮；路径、可用版本独立行、正常检查状态和常驻长页脚已移除。目标版本与渠道说明转为按钮帮助，错误、更新进度和无法自动更新的恢复指引仅在相应状态显示。
- 两按钮始终保留并沿用原有 `canCheck`／`canUpdate` 与动作；没有改动 ViewModel、安装器、版本查询、权限或任务门禁。同步 `DESIGN.md`、双语 README／词条并移除退役展示词条，中英各 1,922 唯一键一致。
- 2026-10-24 23:23：严格主程序构建、最终 39 项设置／更新 VM／双语定向回归、40 项打包测试及 Harness task 通过，365 个跟踪源码／资源／测试／Package 文件在测试前后哈希一致。早期验证总数 366 另含一项已忽略的 Finder 元数据，不计入源码，`verified-source.json` 已区分。23 张原生模拟图中代表性的双语／明暗／错误／更新态已由主线和独立核验目视确认，没有实际升级 CLI。
- 2026-10-24 23:35：固定源提交 `0913f4b444981d6cd77c178942913473f3e0e275` 的 444 文件隔离源码在 Release 构建前后内容／权限一致；App／ZIP／安装的 185 子条目、深层 ad-hoc 签名、最低 macOS 13、1922 双语键／资源、RPATH／运行依赖与更新配置通过主线和独立核验。ZIP SHA-256 为 `363f92a125319c0ac7dc3a4a61801795f071c09130063704eb84278c143dedbc`，产物及清单位于 `dist/local-preview-arm64-cli-compact-0913f4b/`；原 `22` 完整备份在其中 `previous-installations/20261024-233213/AWSPlatform.app`，匹配安装前独立基线，CLI 哈希未变。
- 2026-10-24 23:53：初次启动 `23` 曾等待 Documents 系统授权；用户处理弹窗后，同 PID `47565` 恢复正常，未重启或修改权限。主线先确认主窗口响应且 Profile 为空，再打开设置；主线与独立实际 AX／截图均显示 `0.4.1 (23)`，CLI 区域只有版本 `2.37.9`、AWS 官方安装包、检查／更新按钮，没有路径、目标版本独立行、常驻状态或长页脚，`2.38.5` 只在按钮帮助中。CLI 文件哈希仍与安装前一致，未点击实际更新、登录或选择 Profile。最终记录为 `.tmp/aws-cli-compact/verification/independent-runtime23-responsive.json`，初次等待记录保留在 `diagnosis/`；当前可见、响应的正面证据取代此前待验收状态。
- 验证边界：英文按钮保留原生模拟点击、阶段／禁用和防重复测试；中文按钮的精确词条及主线／独立截图目视共同验收。隐藏 Form 的 NSView 辅助功能遍历只暴露版本与来源，新增按钮 AX 检查已撤回；中文短词整图 OCR 的误识别已通过只读原图行区域放大复核，不为此次可逆布局新增 OCR 系统或改生产控件。原有版本／来源 AX、冗余信息负向检查、错误与指南 OCR 和全部截图保留；初轮失败与诊断日志保留在 `.tmp/aws-cli-compact/`。

## 官方依据

- [AWS macOS 安装与更新](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) 和 [官方安装脚本](https://awscli.amazonaws.com/v2/install.sh) ：固定版本 PKG、Apple 签名与 AWS Installer 团队检查、系统安装方式。脚本仅作为源码证据，不执行下载的脚本。
- [AWS CLI 2.37.9 启动源码](https://github.com/aws/aws-cli/blob/2.37.9/awscli/clidriver.py#L117-L132) 与 [Session.full_config](https://github.com/aws/aws-cli/blob/2.37.9/awscli/botocore/session.py#L384-L417) ：版本参数解析前会读取配置与插件，需要独立空配置。
- [Homebrew awscli formula](https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/a/awscli.rb) 、[Python virtualenv helper](https://github.com/Homebrew/brew/blob/HEAD/Library/Homebrew/language/python.rb) 、[Formula API](https://formulae.brew.sh/docs/api/) 和 [upgrade 命令](https://docs.brew.sh/Manpage#upgrade-options-installed_formula-installed_cask-) ：识别 keg receipt 与 `libexec/bin/aws`，按相同 Homebrew 前缀更新指定 formula。

## 后续本机预览安装（已完成）

- 2026-10-24 11:10：从固定提交 `85778a9c9303f2b2a55d8dab019a4ade5e8683c4` 构建并安装 `arm64` 本机预览 `0.4.1 (22)`。444 个冻结文件构建前后内容／权限一致；最终严格全量 1,566 项测试、严格构建和 40 项打包测试通过。App／ZIP／安装的 185 个子条目、深层 ad-hoc 签名、最低 macOS 13、运行库、双语各 1,924 键及更新策略通过主线与独立核验。本轮未作 Developer ID 签名、公证或公开分发。
- `22` 的 ZIP SHA-256 为 `4e685c28f6b935c33359fef2f7cb114339ef676b88b17e9eaad83266c95d91f0`。来源／安装清单和核验证据保存在 `dist/local-preview-arm64-cli-startup-85778a9/`；旧 `21` 完整备份在该目录的 `previous-installations/20261024-110230/AWSPlatform.app`，独立匹配安装前基线，原 `20` 及更早备份保留。
- 初次启动 `22` 时同一进程曾等待 AWS 配置符号链接目标所在的 Documents 访问授权。精确 PID 与当前应用主体的 TCC 记录显示北京时间 `11:02:37` 请求提示、`11:04:49` 允许；随后同进程恢复，855 个主线程样本均在正常事件循环。主线与独立核验实际主窗口／设置 AX 和截图可见、响应正常，没有为此再次修改源码或重打包；未操作系统授权按钮。
- 实际点击设置后，CLI 分组显示当前 `2.37.9`、AWS 官方安装包、`/usr/local/bin/aws`／`/usr/local/aws-cli/aws`、可用 `2.38.5` 及检查／更新按钮，页面已留给用户查看。CLI 二进制路径／SHA-256 与安装前一致；没有点击更新、SSO 登录或选择 Profile，没有执行 AWS 查询。真实管理员更新、Homebrew 升级、Intel／macOS 13 实机继续保留专项验收。
- `22` 的配置元数据预检并不覆盖所有 I/O 等待：首次系统授权已经实核会延迟窗口，且文件状态可能变化。后续异步配置读取与线程级禁止自动 materialization 的候选依据见 [Apple TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files) ，本轮不继续扩展实现。只读研究／无内容读取探针和最终权限／事件循环证据保存在 `.tmp/aws-cli-preview-install/22/research/` 与 `diagnosis/`。

以下为本次安装过程中保留的前序记录，不代表当前窗口状态：

- 2026-10-24 10:50：按用户授权从固定 `8ca881b` 的 444 文件隔离源码构建 ARM 预览 `0.4.1 (21)`，40 项打包测试、源内容／权限、App／ZIP／安装内容与深层签名通过。旧 `20` 完整备份在 `dist/local-preview-arm64-cli-8ca881b/previous-installations/20261024-103618/AWSPlatform.app`，独立基线一致，AWS CLI 文件哈希未变。
- `21` 的进程存活未作为启动验收：系统仅看到 0×0 窗口且 AX 无响应。1 秒采样 838／838 主线程样本停在配置读取的 `open`；当时默认 config 的符号链接目标带 `SF_DATALESS`。该元数据不单独证明等待的完整成因；后续 `22` 的精确权限记录确认其等待 Documents 授权。诊断仅记录元数据和函数栈，没有读取配置内容或主动发起下载；屏幕／辅助功能权限均允许。证据在 `.tmp/aws-cli-preview-install/`。
- 配置保护统一使用 `stat` 检查，云占位／非普通文件返回固定错误，正常符号链接保留；`O_NONBLOCK`＋描述符再次检查避免 stat 后被替换为 FIFO。加载失败清空旧 Profile／Session／验证范围，恢复后仍需手选 Profile。新增 6 项读取／VM 回归与 1 项双语回归，80 项定向测试通过，已纳入 `22`。
- 本轮只对本次启动且尚未显示可操作窗口的阻塞进程 `84024` 发送 `SIGTERM`；没有结束其他应用、改 AWS 配置或运行 CLI 更新。保留 `20` 与 `21` 包作为前序证据，最终交付为 `22`。
