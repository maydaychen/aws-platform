# 项目审查五项风险修复

## 范围与既定决策

修复审查确认的五项 P2，保留显式 Profile 与既有读写范围；不升级依赖、不调用真实 AWS、不安装应用、不推送或发布。临时复现与日志在 `.tmp/audit-fixes/`，任务不是 Goal。

主 Agent 维护规则、文档、双语词条、集成验证和提交。所有子任务共享工作区，不得回退其他任务改动，不执行 Git 写入或并行启动 SwiftPM 构建；由主 Agent 统一执行构建／测试。

## 任务 F1：本地下载覆盖

- 目标：消除文件检查与覆盖之间的静默数据丢失，保留覆盖能力。
- 入口与所有权：`Utilities/S3TransferFiles.swift`、`Services/AWSS3TransferService.swift`、`ViewModels/S3TransferViewModel.swift`、`Models/S3Transfer*.swift`、`Views/S3/S3TransferView.swift` 与现有 S3 传输测试；禁止修改 S3ViewModel、其他服务、词条和文档。
- 决策：新建保持排他提交；覆盖使用原子交换，被置换文件必须保留为同目录恢复副本，不能在再次检查后删除；UI 完成状态明确提供副本位置。提交前失败／取消不改变旧目标；交换后不得以临时清理删除恢复文件。不靠增加一次 fingerprint 检查解决竞态，不新增依赖。
- 接口：允许下载返回结构化完成结果，包含恢复位置，更新所有现有消费者与相关模拟下载器；沿用现有状态提示组件，不新增视觉样式。
- 验收：现有下载、容量、ETag、目录绑定、取消保护；新增提交边界并发修改仍有可恢复副本、长文件名、恢复路径冲突／重命名失败、不覆盖新建目标、提示与清理测试。仅任务临时文件。
- 交付：实际改动、建议新增的英文文案和中文翻译、关键测试名及未解决问题。

## 任务 F2：SSM 凭据绑定

- 目标：身份预检和实际连接使用同一组凭据。
- 入口与所有权：`Services/EC2SSMConnectionService.swift`、`Tests/AWSPlatformTests/EC2SSMConnectionTests.swift`；禁止修改其他凭据服务、词条、文档。
- 决策：生成的脚本仅保存定位信息。终端执行时用显式 Profile／路径调用一次 `configure export-credentials --format process`；用系统 plutil 从私有标准输入解析 JSON。之后凭据只存内存，通过 shell 内建 export 传给两个 CLI 子进程；不得通过 env 命令参数传密钥，不使用 eval，不依赖 Python／jq。业务调用不传 Profile，禁用磁盘配置和继承的 AWS 环境，只保留固定区域与端点隔离。解析或 STS 身份不匹配时不得启动 SSM；退出清理脚本。
- 验收：本地假 CLI 在导出后改变 Profile／credential_process 返回角色，两次业务调用仍使用同一组内存凭据；覆盖解析失败／空字段／无效类型、静态与会话凭据、身份错误、终止与清理、特殊字符，确保凭据不在脚本／参数／日志。
- 交付：实际改动、测试证据、文案建议；不打开真实终端或建立会话。

## 任务 F3：CLI 子进程取消／超时

- 目标：凭据导出在子进程忽略 TERM 或后代保留输出管道时仍有有界结束。
- 入口与所有权：`Services/AWSCLICredentialProvider.swift`、可新增专用小型进程执行器与测试、现有 AWSCLICredentialProviderTests；禁止修改 AWSServiceProvider／AWSProfile／ConfigReader、SSM 脚本和词条。
- 决策：凭据继续只经内存管道；保证取消／超时的最终截止、必要的 TERM→KILL、管道关闭及子进程回收，输出有大小上限，不阻塞合作线程池；终止只针对本任务子进程。提供实际子进程测试注入入口，不仅 Runner 替身。错误始终脱敏。后续 F4 将复用此提供器处理 AssumeRole，错误文案改为通用 Profile 凭据说明，列出文案供主 Agent 本地化。
- 验收：成功与非零退出、启动失败、忽略 TERM、孙进程保留 stdout、取消／超时、超量输出均有本地进程测试；不读取真实配置、不调用真实 AWS、不输出模拟或真实密钥。
- 交付：实际改动、测试名和时间边界、日志及清理证明。

## 任务 F4：AssumeRole 配置兼容

- 目标：支持 config 声明目标角色／source_profile，credentials 只保存源 Profile 的标准布局。
- 入口与所有权：`Models/AWSProfile.swift`、`Utilities/ConfigReader.swift`、`Services/AWSServiceProvider.swift`、相关配置／Provider 测试；禁止修改 AWSCLICredentialProvider、SSM 脚本、文档和词条。
- 依赖与决策：模型增加默认 nil 的 roleARN（及确有需要的配置元数据），ConfigReader 正确解析，不改变旧初始化消费者。角色 Profile 使用 F3 的 AWSCLICredentialProvider，经 CLI 一次导出临时凭据，再沿用 IdentityBoundCredentialProvider；其他静态 Profile 不变，无依赖升级或配置文件写入。工厂选择须可由模拟 exporter 验证，不能只验证注入 credentialFactory 的旧测试。
- 验收：标准 source-only 布局、default source、旧静态／SSO 自定义路径与同名配置、角色变化影响配置身份、缺失／失败均离线覆盖；禁止真实 STS。
- 交付：实际改动、接口说明和测试证据，注明与 F3 的衔接。

## 任务 F5：Bucket 列表分页（主 Agent）

- 所有权：`ViewModels/S3ViewModel.swift`、Bucket 模型的 Sendable 声明及专用 Bucket 列表测试，可新增小型纯分页服务。
- 决策：显式 maxBuckets，消费 continuationToken，保持取消、代次与 Profile 作用域，重复令牌／重复数据／中途失败不返回半份成功列表；不按当前 Region 过滤全账号 Bucket。
- 验收：首屏为空但有 token、多页、重复 token、后续页失败、取消、旧范围迟到结果和已有 Bucket 列表回归。

## 集成验收与交付

所有权边界内的源文件由主 Agent 最小复核；统一运行相关失败路径回归、严格并发／警告视为错误的完整 Swift 测试、必要 build、双语目录检查和 Harness task。规则变更执行可用结构／配置校验；遵循 500 行警告／1000 行失败。独立审查关键修复，问题修复后再测试。更新 README／ROADMAP 的当前行为与验证结果，主动创建聚焦本次修复的中文 commit；本机仍保留原预览安装。

## 当前状态

已完成源码修复与离线验收，尚未安装或分发。

- F1：原子交换并永久保留实际被置换文件，完成结果携带恢复位置；新增 8 项文件边界回归及 VM 状态回归。恢复名冲突测试额外发现并修复构造失败时的误清理；`ownsTemporary` 使清理权限仅属于成功创建的文件，重复清理不删后续同名文件。
- F2：一次导出 JSON，经系统 plutil 的 stdin 校验；业务调用取消 Profile／磁盘配置解析，以 shell 内建 export 传同组凭据。独立生产脚本测试 23 场景通过，Package 测试同步覆盖。
- F3：非阻塞内存管道，默认 64 KiB 输出限制、30 秒截止；TERM 宽限 1 秒，KILL 后最多再等待 1 秒，只清理直接子进程。新增 9 项实际进程测试，孙进程持有 stdout 也不能使调用挂起。
- F4：角色元数据参与配置身份，CLI 工厂支持标准 config/source-only credentials。独立复核补齐目标 partition／account／roleName 校验，IAM path 和 STS session 后缀按服务语义处理；15 项模型／配置／Provider 回归覆盖真实工厂选择。初轮跨分区 Region 与隔离 HOME 夹具不一致已修正，生产 scope 校验保持。
- F5：每页 1,000 个 Bucket，最多 1,000 页；消费不透明 token，处理空页、重复名称、循环与预算、失败、取消；完整列表仍受 VM 代次隔离。
- 集成：定向 106 项、全量 908 项严格应用测试、严格构建、40 项打包测试、Harness task 和配置结构校验通过；1,500 条双语词条一致。恢复路径 280 pt 中英／深浅色原生截图已检查。独立审查结论为通过，无剩余阻塞缺陷。
- 验证日志：`.tmp/audit-fixes/targeted-tests-final.log`、`full-tests-final.log`、`build.log`、`packaging-tests.log`、`harness.log` 与各 F1–F4 子目录；截图在其 `screenshots/`。
- 边界：全部使用本地临时文件、假 CLI 和模拟服务；未调用真实 AWS、打开真实终端、打包安装、推送或发布，原本机预览继续保留。
