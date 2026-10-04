# AWS Platform Roadmap

## 当前阶段

只读浏览修复、本地收藏与最近访问、统一样式、按 session 登录、Cost Explorer、CloudWatch Alarms、SNS Topics／配置调用链、告警到 SNS 跳转、EC2／Lambda 指标及 Lambda 日志、AWS Health 当前账号事件、Route 53 Hosted Zones 与 DNS 记录、ELBv2 负载均衡与目标组、独立安全组、统一资源关联及中英文界面切换已完成本地回归与模拟组件渲染检查。已提供面向 macOS 13+ 的 Intel／Apple Silicon Universal 正式 ZIP 和 DMG，完成 Developer ID 签名、Apple 公证、票据装订、Gatekeeper 及 Apple Silicon 离线启动检查；Intel 与 macOS 13 实机运行仍待验收。登录后保持 Profile 为空，只有手动选择 Profile 才加载数据；等待用户进行真实 AWS 账号验收。

源码已按 MIT 许可证公开至 [maydaychen/aws-platform](https://github.com/maydaychen/aws-platform) ，默认分支为 `main`；当前未发布应用二进制 Release。

Health、最近访问、Route 53、ELBv2、安全组与统一资源关联源码已推送至 GitHub `main`；中英文界面与 Lambda 源码预览加固代码尚未推送。上述新增功能尚未包含在已有的 `0.1.0 (1)` 正式分发包中。

## 最近完成

- 2026-10-05 01:04：加固 Lambda 部署包源码预览：HTTPS 流式下载限制 50 MiB，内存逐块读取限制展开 250 MiB、10,000 个条目、累计文本 10 MiB；保留单文本 200,000 字节限制。校验 ZIP 元数据、实际字节与 CRC，拒绝越界／重复路径、符号链接及不支持的格式；仅临时 ZIP 落盘，成功／失败／取消后清理。下载限时 60 秒、读取限时 30 秒，新增取消按钮及双语错误；请求标识隔离同名重试和切换账号后的迟到结果。使用系统 zlib，无新增第三方下载依赖；双语 README 同步限制。本轮仅本地源码，未推送或重新打包。

- 2026-10-04 15:40：新增「跟随系统／简体中文／English」语言偏好及侧栏设置入口；即时切换所有窗口文案，保留 Session／Profile／Region、筛选及资源状态，不触发 AWS 查询。现有页面、帮助、错误及空态使用 1,316 条双语文案，资源名称、ARN、标签、日志及 AWS 说明保留原文；现存异步错误在显示时解析，DNS 部分失败分离资源标识与错误正文。SwiftPM 语言资源及 Universal 打包检查、双语 README 与本地化开发说明同步。本轮仅本地源码，未推送、签名或重新分发。

- 2026-10-04 14:54：按用户授权将 Health、最近访问、Route 53、ELBv2 与统一资源关联的 5 个功能提交推送至 GitHub `main`，功能提交为 `59626f8`；同步源码交付状态。原私有远端及既有未提交 `AGENTS.md` 改动保持不变；未重新打包或发布二进制 Release。
- 2026-10-04 11:33：新增独立 Security Groups 页面，支持所属账号／VPC／标签／入出站规则、搜索筛选、收藏与最近访问；统一关联弹框连接 Route 53 记录、LB、Target Group、EC2 与安全组，名称优先、展开详情、单层 Explore、缓存 Back 及精确 Open。DNS 只匹配显式 Region 的直接 Alias／CNAME，Alias 同时核对 canonical zone；反向扫描需手动触发，最多 4 个 Zone 并发并保留部分失败。区域资源跳转重新核验当前 Profile 身份，全局记录保留资源 Region，按完整复合 ID 置顶展开。中英文 README、读取权限及三张模拟截图已同步。
- 2026-10-04 09:55：新增当前 Profile／账号／Region 的 ALB／NLB／GWLB、Target Groups 和目标健康状态只读浏览；监听器默认动作、ALB 规则／条件／变换／加权转发可展开查看，同范围精确打开目标组及 EC2／Lambda／ALB。EC2 新增手动反查目标组页签，最多 4 个并发，保留多个注册端口及部分失败；IP 不推断实例，Lambda qualifier 保留并说明函数级跳转。完整分页、独立错误、取消／迟到隔离、ARN 收藏／最近访问接入，服务侧栏可滚动；中英文 README、五项权限说明及三张模拟组件截图已同步。
- 2026-10-04 09:17：新增 Route 53 公有／私有 Hosted Zones 只读浏览，按当前已验证 Profile／账号全局加载，不随资源 Region 重查。提供 Overview／Records／Tags、搜索与公私／记录类型筛选、Alias／TTL／完整路由配置、委派 NS 与 VPC 关联；列表和记录完整分页，详情／记录／标签独立失败、手动刷新／取消及迟到结果隔离。Hosted Zone 以 canonical ID 和 `global` 接入收藏／最近访问，打开保留资源 Region 并重新验证账号；修复刷新失败后误选缓存 Zone 的导航路径。中英文 README、权限说明与两张模拟组件截图已同步。
- 2026-10-04 09:01：新增侧栏 Recent 和 `Cmd+Shift+R` 入口，仅记录当前已验证 Profile／账号实际显示详情的 EC2、Lambda、S3 Bucket、CloudWatch 告警和 SNS Topic；按资源及浏览 Region 去重，每个 Profile／账号最多 50 条，重复访问置顶并更新名称与时间。支持本地持久化、搜索、单条删除和当前账号清空确认；跨窗口共享存储但按窗口范围筛选，损坏数据保留并禁用编辑。复用资源导航恢复 Region、重新核验账号，失败保留记录且不改收藏；中英文 README 和两张模拟组件截图已同步。
- 2026-10-04 00:56：新增侧栏 Health 当前账号事件页，按显式选择并验证的 Profile 查询全区域 `ACCOUNT_SPECIFIC` 事件；过滤公共事件，不聚合组织成员。支持搜索、状态／类别／服务／事件区域筛选、最新事件说明、metadata、UTC 时间和受影响资源，完整分页、独立详情错误、手动刷新／取消及迟到结果隔离。资源 Region 不触发重查；API 访问计划和权限不足给出对应提示。中英文 README 和两张模拟组件截图已同步。
- 2026-10-03 23:39：双语 README 和正式打包相关的 3 个提交已推送 GitHub `main`，远端核对为 `8b59836`。按用户授权将本机 AWS CLI 从 Intel 版 `2.19.2` 升级为官方 Universal `2.37.9`，沿用原安装位置和命令入口，解除旧 CLI 的架构阻塞；AWS 配置与凭据保持不变，未执行真实 SSO 登录或 AWS 数据查询。
- 2026-10-03 23:28：根目录 `README.md` 改为完整英文版，原中文正文保留为 `README.zh-CN.md`，两版顶部增加相对路径语言切换链接；功能、权限、费用提示、命令、配置示例和截图保持对应。仅调整项目文档。
- 2026-10-03 17:30：交付 `0.1.0 (1)` 正式 Universal ZIP／DMG，源构建提交为 `89461dd`；新增 `scripts/package-distribution.py`，串联双架构构建、完整许可收集、Developer ID 签名、App／DMG 分别公证及票据装订，生成校验和与分发清单。正式产物位于 `dist/AWSPlatform-0.1.0-universal/`，保留原本地预览包。README 和脚本说明同步打包入口及原生 AWS CLI 前提；未创建 GitHub Release。
- 2026-10-03 16:13：源码已上传至 GitHub 公开仓库 `maydaychen/aws-platform` 的 `main`；新增 MIT LICENSE 和 26 项锁定依赖的许可／NOTICE 索引。修正 README 的公开克隆地址、Swift 6.2+ 构建前提和 Lambda 配置读取权限，说明部署包临时落盘行为；补齐本地 AWS 配置、环境配置、证书及个人 Agent 文件的忽略规则。保留原私有远端；未变更业务代码，未发布应用二进制。
- 2026-10-03 15:02：新增 `scripts/build-universal.sh`，锁定依赖分别构建 arm64／x86_64 Release 并合并为 Universal `.app` 与 ZIP；标准资源布局、Swift 兼容运行库嵌入及构建机绝对 RPATH 清理，检查架构、最低系统、缺库与本地 ad-hoc 签名后交付。保留 `AWSPlatform` 偏好域标识；README 和脚本说明提供命令，`dist/` 加入忽略规则。未使用 Developer ID、执行公证或对外发布。
- 2026-10-03 14:00：新增 EC2／Lambda `Metrics` 页和 Lambda `Logs` 页，手动查询最近 1／6／24 小时；指标按 5 分钟批量读取四项曲线，保留缺口／部分状态，UTC 轴与详情一致，窄屏单列、宽屏双列。日志采用已成功加载的函数配置，默认组直接查询，自定义组完整枚举并精确隔离函数日志流；冻结查询分页、取消、5,000 条／8 MiB 正文上限及不完整提示，不落盘。新增告警动作到同 Profile／账号／Region 的 SNS Topic 精确跳转；切换或清空范围会取消并隔离旧响应。README、权限说明及两张组件示例已同步。
- 2026-10-03 13:19：提升 SNS 调用链卡片层次：服务色图标、轻渐变底色、连续圆角、细边框和柔和阴影；悬停／展开时加强边框与层次。保留名称首屏、点击展开和 Open 流程，身份／区域校验及原始 Endpoint 遮罩不变；增加增强对比度边框和减少动态效果分支，更新默认收起的文档示例。
- 2026-10-03 13:09：简化 SNS 调用链首屏：告警、Topic 和订阅节点默认仅显示名称，整行可展开／收起，详情与 Open 按钮仅在展开后显示。合法 Lambda 节点显示函数名，展开即可跳转，不再要求先 Reveal；原始 Endpoint 仍默认遮罩，覆盖范围说明收入 About this view。展开状态随弹窗关闭或上下文变化重置；README 和默认收起的示例截图已更新。
- 2026-10-03 12:54：SNS Topic 详情新增「调用链查看」弹窗，显示当前 Profile／Region 的 CloudWatch Metric／Composite 告警三类动作 → Topic → 已加载订阅；保留禁用／抑制和订阅确认状态，区分检查失败与无匹配。支持同范围告警、已确认 Lambda 订阅跳转详情，保留 qualifier 并注明函数级详情；Endpoint 默认遮罩，跨账号／Region 和未支持服务不跳转。独立导航不写收藏、不重配全服务，修复关联目标缺失时 Lambda 自动选首项及立即取消仍启动查询的问题。范围明确为配置关系，不是实际消息轨迹；README 和弹窗组件示例已同步。
- 2026-10-03 12:24：新增按当前 Profile／Region 隔离的 SNS 只读模块，提供 Standard／FIFO Topic 搜索与筛选、属性／标签／订阅三组独立读取、配置及策略展示、手动刷新与取消。Topic 和订阅完整分页，保留待确认／已删除／未知状态及合法跨账号订阅 Owner；Endpoint 默认隐藏，显示后才可复制，切换 Topic／身份或刷新时重置。接入 ARN 收藏，未增加消息发布、订阅变更或自动跨账号导航。README 和六张模拟组件示例已同步。
- 2026-10-03 11:46：新增 CloudWatch Metric／Composite Alarm 只读浏览，按当前 Profile 和资源 Region 隔离；首次进入列表才加载，支持搜索、状态／类型筛选、手动刷新和取消。详情展示状态原因、单指标／Math／Insights 配置、Composite 规则及抑制配置、动作目标 ARN；选择告警后独立加载标签和最近 30 天历史。完整分页、ARN 校验、错误脱敏与迟到结果隔离，接入现有 ARN 收藏定位。未增加 SNS 查询／发送、指标数据或告警写入；同时消除 Cost 时间默认闭包的 Sendable 编译警告，查询行为不变。README 和模拟组件截图已同步。
- 2026-10-03 11:16：实现按当前 Profile 经 STS 验证账号查询的 Cost Explorer 面板；所有汇总、日明细及费用区域请求强制 LINKED_ACCOUNT，不自动汇总组织成员。提供本月／上月汇总、日趋势、服务明细、UTC 完整日与独立费用 Region 筛选、8 组内存缓存、手动刷新和取消。完整分页、Decimal 金额／币种校验、错误脱敏与迟到结果隔离；资源 Region 切换保留 AWSClient，不触发费用重复加载。README 和四张模拟组件示例已同步。

## 最近验证

- 2026-10-05 01:04：`swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`（缓存／配置／安全目录显式设在任务临时目录）通过，691 项正式测试零失败、无编译警告。新增 71 项覆盖下载真实／声明限额、HTTPS、错误脱敏、ZIP CRC／路径／条目范围、实际解压中取消和超时、临时目录清理、同名请求隔离及双语错误；竞态修复前 2 项测试稳定产生 5 个断言失败，修复后通过。独立源码与日志复核、arm64／x86_64 的 macOS 13 SDK zlib 头文件检查、双语 README 各 27 个链接、语言资源 plist 及 `git diff --check` 通过。未调用真实 AWS，未验证新版安装包或 Intel／macOS 13 实机。

- 2026-10-04 15:40：严格命令 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，620 项正式测试及 3 项临时渲染共 623 项成功，无编译警告。16 项本地化测试覆盖系统回退、偏好恢复、英文／中文词条与占位符、原始参数、嵌套及多行消息、大写 Health 状态；34 张离线模拟截图覆盖各服务、深浅色、窄宽布局及长文案，同一挂载窗口切换后状态不变且模拟身份验证仍只调用一次。独立源码／日志与关键截图复核通过；将临时关联夹具对齐生产词条后，单项渲染测试再次通过。双语 README 各 27 个引用、11 项打包脚本测试、语言资源 plist、源码／测试 Gitleaks 与 `git diff --check` 通过；临时测试入口移除。未调用真实 AWS，未生成新分发包，原生 Settings 入口／真实多窗口及 Intel／macOS 13 实机仍待验收；既有 Charts anchor 运行时警告保留。

- 2026-10-04 14:54：推送范围 `3d51d19..59626f8` 的 Gitleaks 扫描未发现秘密，`git diff --check` 通过；GitHub `main` 实时回读与功能提交 `59626f8` 一致。业务源码及测试与此前已验证提交一致，本轮仅推送并同步进度文档，未重复运行 Swift 测试或访问真实 AWS。
- 2026-10-04 11:33：严格命令 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，604 项正式测试与 1 项临时渲染测试成功，无编译警告；新增 87 项覆盖安全组完整分页／结构化规则／附加网卡、关系匹配／4 并发及部分失败、Profile／身份／Region 隔离、精确导航、取消与迟到结果。修正同 owner 搜索测试预期；渲染发现 DNS 长卡片自动滚动不稳定，最终采用精确记录置顶展开并移除失败滚动代码，36 项相关正式测试与临时渲染再次通过。42 张模拟组件截图覆盖深浅色、窄宽布局、错误／部分结果及长列表精确记录；已抽查关键图。独立源码与证据复核、Gitleaks、双语 README 引用和 `git diff --check` 通过；临时入口已移除。未调用真实 AWS；真实权限、账号、完整窗口交互、macOS 13 与 Intel 待验收。
- 2026-10-04 09:55：严格命令 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，517 项正式测试与 1 项临时渲染测试全部成功，无编译警告。本次新增 86 项正式测试覆盖 ELB 分页／字段映射／认证白名单／范围与父资源校验、4 并发反查及部分失败、取消与共享请求竞态、精确导航和收藏／历史隔离。109 张离线截图覆盖深浅色、280／420 列表、480／900 详情、176 宽侧栏及错误／空／加载／部分结果；抽查发现并修正端口千位分组后，86 项相关测试与临时渲染重新通过，实例 ID 换行边界同时加固。独立源码审查、Gitleaks 源码／测试扫描、双语 README 引用和 `git diff --check` 通过；临时测试入口已移除。未调用真实 AWS；真实 IAM／分页、完整窗口交互、macOS 13 与 Intel 运行待验收。
- 2026-10-04 09:17：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 严格构建通过，431 项正式测试及 1 项临时渲染测试全部通过，无编译警告。新增 52 项正式测试覆盖三元记录游标／空页／重复与缺失游标／页数保护、Alias 与路由字段、私有 Zone 可选 NS、权限错误脱敏、取消／迟到响应、全局分区端点及 Profile／账号隔离、收藏／历史精确导航与缓存列表失败回归。47 张离线截图覆盖 280／420 列表与 480／900 详情、深浅色、三页签、展开记录、长值、空／错误／加载态；补充实际列表宽度后重新严格渲染通过，临时入口已移除。独立源码审查、Gitleaks 源码／测试扫描、双语 README 引用及 `git diff --check` 通过。未调用真实 AWS；完整窗口交互、真实 IAM／分页、macOS 13 与 Intel 运行仍待验收。
- 2026-10-04 09:01：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 严格构建通过，379 项正式测试及 1 项临时渲染测试全部通过；新增 17 项正式测试覆盖最近访问持久化、去重／上限、Profile／账号隔离、搜索／删除／清空、损坏保护、导航失败及收藏不变。22 张离线组件截图覆盖 280／420 宽度深浅色、搜索、空态和存储异常；统一英文相对时间后重新严格编译、渲染并回读关键截图通过，临时入口已移除。独立源码审查、Gitleaks 源码／测试扫描、双语 README 引用检查和 `git diff --check` 通过。未调用真实 AWS；完整窗口点击、跨窗口操作、真实资源重新打开及 macOS 13／Intel 运行仍待验收。
- 2026-10-04 00:56：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 严格构建通过，362 项正式测试及 1 项临时渲染测试全部通过。新增 50 项正式测试覆盖当前账号／分区校验、公共事件过滤、完整分页、未来事件、失败／取消、空 Profile 零调用、切换 Profile 迟到响应隔离和 Region 不重建全局客户端。修正 catch 属性遮蔽、可选枚举歧义及测试样例 ARN；搜索文案完善后重新严格编译与渲染通过。15 张离线截图覆盖 720／1000 宽度深浅色、空／错误／加载、独立详情失败和完整受影响资源，已抽查关键状态；临时入口已移除。独立源码审查、Gitleaks 源码／测试扫描、双语 README 引用检查和 `git diff --check` 通过。未调用真实 AWS，实际 Support／IAM／分页和 macOS 13／Intel 实机运行仍待验收。
- 2026-10-03 23:39：待推送 3 个提交的 Gitleaks 扫描及 `git diff --check` 通过；GitHub `main` 提交回读一致，两份远端 README 与本地提交内容逐字节相同，语言互链有效。官方 CLI 安装包的 AWS Developer ID Installer 签名和 Gatekeeper 通过，安装器报告升级成功，安装收据为 `2.37.9`；显式 `arch -arm64` 启动返回 `exe/arm64`，双架构检查通过。已有 Hardened Runtime 签名诊断程序中的原生 Process 和实际 `AWSSSOLoginService.run` 执行 `--version` 均成功，合成配置解析通过；安装前后 AWS config／credentials 的内容哈希一致。此验收不包含真实 SSO 授权和 AWS 查询。
- 2026-10-03 23:28：中英文 README 静态审计各检查 14 个本地引用，均无问题；中文正文与原版完全一致，英文版章节层级、全部原有链接／截图目标、代码命令和配置示例（排除翻译注释）逐项比对通过，权限及查询边界人工复核一致。语言切换、打包说明标题锚点和 `git diff --check` 通过；纯文档变更，未重复构建或执行 AWS 查询。
- 2026-10-03 17:30：arm64／x86_64 Release 构建和 11 项离线打包测试通过。独立核验主程序双切片最低系统为 13.0，嵌套 Developer ID 签名、Hardened Runtime、安全时间戳有效；26 项依赖许可附件及补充来源哈希一致。Apple 回读 App／DMG 两次公证均为 Accepted，最终 App／DMG 票据与 Gatekeeper 通过；ZIP 独立解压和 DMG 只读挂载后的应用内容、签名及信任检查一致。解压副本以空 AWS 配置、隔离偏好在 Apple Silicon 上运行 8 秒，未见启动崩溃；README 审计、脚本秘密扫描及 `git diff --check` 通过。未调用真实 AWS，未进行 Intel／macOS 13 实机验收；另定位本机旧 Intel AWS CLI 在缺少 Rosetta 时无法启动，与应用签名无关。
- 2026-10-03 16:13：重新执行 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`，严格构建成功，312 项正式测试零失败。Gitleaks 对全部可达 Git 历史、发布分支和当前发布文件扫描均未发现秘密；逐张检查 9 张文档截图，均为模拟数据。26 个依赖版本／revision 和 42 个 LICENSE／NOTICE 文件链接核对通过，README 静态审计、忽略规则及 `git diff --check` 通过。GitHub API 确认仓库公开、MIT 和 `main`，6 个关键文件 Git blob 与本地一致；无凭据克隆成功，提交与完整文件树一致。独立源码及交付审查未发现阻断源码公开的问题；未连接真实 AWS，未新增 Intel／macOS 13 实机验收。
- 2026-10-03 15:02：arm64／x86_64 Release 构建通过，最终通用产物经独立 `lipo`、`vtool`、`plutil`、严格深层 `codesign` 与 ZIP 完整性核验；主程序两切片最低系统均为 13.0，嵌入的 Swift Span 运行库满足两架构的系统下限，无 Xcode 绝对 RPATH，已移除工具生成的冗余备份。ZIP 解压到独立目录后，以空 AWS 配置在 Apple Silicon 上持续运行 8 秒；包内运行库 `dlopen` 成功，启动日志未加载 Xcode 工具链库。使用当前正式 XCTest 产物运行 312 项测试，全部通过；业务源码未修改。Shell 语法、忽略规则及 `git diff --check` 通过。未调用真实 AWS；当前主机无 Rosetta，未执行 Intel 或 macOS 13 实机验收。
- 2026-10-03 14:00：最终 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，312 项正式测试零失败、无编译警告，覆盖指标定义／分页／缺失与状态、日志共享组隔离／空页续读／上限、取消与完整 Profile 隔离、告警 SNS 导航。1 项临时原生渲染测试通过，72 张 480／900 宽度深浅色截图，抽查指标缺口、UTC 轴、1／2 列、父详情页签、长日志、部分／空／错误／加载／超限及跳转按钮；修复实测横轴误用本地时间并消除该图表 AxisValueLabel 诊断。旧 SNS 不支持断言已按新范围更新，临时渲染入口已移除；独立代码审查无阻断，`git diff --check` 通过。未访问真实 AWS，真实窗口点击、macOS 13 运行时和实际权限／分页仍待验收。
- 2026-10-03 13:19：严格构建及 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，258 项正式测试零失败、无编译警告；1 项离线原生渲染测试通过，生成 36 张截图，已核对 960／1200 宽度的深浅色名称、图标、边框、展开详情及隐私显示状态。增强对比 NSAppearance 截图仅作为外观参考，不等同于 SwiftUI 增强对比分支动态验收；减少动态效果和悬停分支仅做代码核验。临时截图工具的只读环境属性注入错误已修正，最终日志无编译诊断；临时入口移除，`git diff --check` 通过。未访问真实 AWS，真实窗口鼠标／键盘操作和 macOS 13 仍待验收。
- 2026-10-03 13:09：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，258 项正式测试零失败、无编译警告；1 项临时离线原生渲染测试通过，8 种状态在 960／1200 宽度及深浅色生成 32 张截图，已核对默认收起、展开、原始 Endpoint 隐藏／显示及错误布局。临时测试入口已移除，`git diff --check` 通过。改动仅为展示与展开状态；未访问真实 AWS，完整窗口点击、键盘操作和 macOS 13 实机仍待验收。
- 2026-10-03 12:54：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 严格构建无编译警告，258 项正式单测全部通过；新增 43 项覆盖关系精确匹配、范围与 ARN 校验、qualifier／特殊订阅状态、安全错误、迟到结果、按需导航和 Lambda 空选择回归。另 1 项临时原生离线渲染测试通过，7 种状态在 960／1200 宽度及深浅色生成 28 张截图，抽查长名称／ARN、默认遮罩／显示、空态和独立错误。独立审查核对关键代码、日志和截图；临时测试入口已移除，`git diff --check` 通过。未调用真实 AWS，也未进行完整窗口点击或 macOS 13 实机验收。
- 2026-10-03 12:24：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 严格构建无编译警告，215 项正式单测全部通过；新增 37 项覆盖 SNS 服务分页／范围／特殊订阅状态、三组详情独立失败、过期结果隔离、Endpoint 显示状态和收藏兼容／导航。另有 4 项临时离线渲染测试通过，SNS 的 13 种整页状态在 960／1280 与深浅色下生成 52 张截图，加 4 张 Endpoint 显示／展开策略组件图；已抽查三个页签、长 ARN、空态和局部错误，独立审查核对核心代码、日志和关键截图。临时入口已移除，文档结构与 `git diff --check` 通过。未调用真实 AWS，真实 IAM／分页、窗口交互和 macOS 13 仍待验收；原有 Cost Charts 运行时警告继续保留在工程待办。
- 2026-10-03 11:46：最终源码严格构建及 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过，无编译警告，178 项正式单测全部通过；新增 36 项覆盖两类告警映射、分页、账号／Region／分区校验、历史窗口、取消、局部权限失败、切换后过期结果和收藏兼容／定位。另有 3 项临时离线渲染测试通过，生成告警 14 种状态在 960／1280 宽度与深浅色下的 56 张截图，并刷新共享导航下的 Cost／资源组件示例；抽查四个页签、长名称／ARN／规则、空态、错误和加载态。独立审查核对核心代码、测试及关键截图；临时入口已移除，`git diff --check` 通过。未执行真实 AWS 查询或真实窗口交互，IAM 组合、实际分页及 macOS 13 运行时仍待用户验收；原有 Cost Charts 警告仍见工程待办。
- 2026-10-03 11:16：最终源码通过 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`，142 项正式单测和 2 项临时渲染测试共 144 项全部通过，`git diff --check` 通过。新增 38 项正式测试覆盖账号／区域过滤、日期边界、分页／取消／异常金额与币种、错误脱敏、缓存与 Profile／身份／配置隔离、跨 UTC 日月刷新及资源 Region 客户端复用。生成 36 张 Cost 状态／报表截图及 6 张资源／空 Profile 截图，抽查深浅色、960／1280 宽度、长文本、负数退款、无数据、月初、错误、加载及自定义日期；独立审查核对核心代码和关键截图。临时测试入口已移除。未执行真实 AWS 登录／费用 API，账单对照、实际窗口操作和 macOS 13 运行时仍待验收；渲染日志的 Charts anchor 警告见工程待办。

## 已完成

- 应用内中英文与跟随系统设置，偏好本地持久化、现存提示即时切换、日期语言适配及原始 AWS 内容保留；语言切换不重建数据状态或查询 AWS。实现约定见 [本地化说明](docs/localization.md) 。

- 独立 Security Groups 只读页、完整规则／标签／共享 owner 展示、本地搜索与 VPC 筛选、收藏／最近访问；统一关联支持 Route 53 → LB → Target Group → EC2／Lambda／ALB，以及 EC2／LB → 安全组和权限引用。逐层查询、手动反查、缓存返回、部分失败及精确导航均按当前 Profile／身份隔离；DNS 可显式查询一个 Region，打开精确记录时置顶展开。
- ELBv2 ALB／NLB／GWLB、Target Groups、监听器／ALB 规则／加权转发和目标健康状态；关联跳转限定同 Profile／账号／Region，支持 ARN 收藏及最近访问。EC2 手动查询所属实例型目标组，保留注册端口并明确部分失败；认证摘要不包含密钥和额外参数。
- Route 53 当前 Profile／账号的全局公有／私有 Hosted Zones、DNS 记录和标签只读查询；委派 NS、VPC 关联、Alias 与各类路由配置展示，支持 global 收藏和最近访问，不执行 DNS 写入或传播检测。
- 最近访问资源历史，按当前已验证 Profile／账号隔离、每组最多 50 条；仅记录可见详情，支持本地恢复、搜索、删除／清空及重新核验账号后打开保存的资源与 Region。
- AWS Health 只读当前账号事件记录，全区域查询、公共事件过滤、本地筛选、最新说明与受影响资源；按 Profile 隔离，未选不查询，权限和 Support 计划不足明确提示。
- macOS 13+ 的 Intel／Apple Silicon 通用应用构建、资源与 Swift 兼容运行库打包、完整许可收集、Developer ID 签名、Apple 公证及正式 ZIP／DMG 交付；正式打包入口为 `scripts/package-distribution.py`，本地预览入口为 `scripts/build-universal.sh`。
- EC2／Lambda CloudWatch 指标和 Lambda 日志检索，按明确 Profile／Region／资源隔离，手动读取／刷新／取消；共享日志组按函数隔离，分页与显示上限明确提示，查询和正文仅保存在当前页内存中。
- CloudWatch 告警动作中的合法 SNS Topic ARN 可在同 Profile／账号／Region 内打开详情；不自动选其他 Profile、换区域或选择不存在目标的替代资源。
- SNS 配置调用链弹窗：CloudWatch 告警三类动作到 Topic，再到订阅目标；默认仅显示名称，展开后可将同 Profile／账号／Region 的告警及已确认 Lambda 跳转到详情，保留原始 Endpoint 遮罩和 qualifier 说明。
- SNS Standard／FIFO Topic 列表、配置／策略、标签与订阅只读浏览，按 Profile／Region 隔离且按需加载；支持 ARN 收藏、局部权限降级和 Endpoint 默认遮罩。
- CloudWatch Metric／Composite Alarm 列表与四页签详情，按 Profile／Region 隔离；按需加载、手动刷新、配置／标签／近 30 天历史和动作 ARN 只读展示，支持本地收藏。
- Cost Explorer 只读费用面板，按当前 Profile 的 STS 账号隔离；UTC 完整日、独立费用 Region、缓存／手动刷新、取消、完整分页、币种／估算状态与调用开销提示。
- 应用内按具名 session 登录、取消和超时提示；登录后不选 Profile、不加载账号数据。手动选择关联 Profile 后验证并加载资源，支持共享 session 及自定义配置路径。
- 全部页面采用统一搜索框、资源计数、自适应详情卡片及原生深浅色；长详情值可换行与选择复制，环境变量仍默认遮罩。
- 本地资源收藏、搜索与定位；先手动选择匹配 Profile，再恢复收藏 Region 并校验账号。仅保存资源定位元数据，应用窗口共享列表，重启后恢复。
- SwiftUI 三栏界面和 Session、Profile、Region、服务切换；启动仅恢复 session，Profile 始终由用户显式选择；空选项下隐藏全部资源列表与详情。
- EC2 实例列表、分页、搜索、实例状态筛选、Status Check 筛选和 AMI 名称降级加载。
- EC2 七页签详情：Overview、Network、Storage、Security、Status、Metrics、Target Groups。
- EC2 ENI、EBS、Security Group 规则、IMDSv2、实例健康检查和 Scheduled Events 按需加载。
- EC2 状态、磁盘或安全组增强接口失败时局部降级，不清空实例列表或基础详情。
- EC2 切换实例、Profile 或 Region 时取消旧详情请求，并隔离过期结果。
- Lambda 函数列表、状态和 Package Type 组合筛选。
- Lambda 七页签详情：Overview、Configuration、Triggers、Versions、Code、Metrics、Logs；窄详情区域使用原生菜单选择页签。
- Lambda Event Source Mapping、异步调用配置、Function URL、Versions、Aliases、Reserved / Provisioned Concurrency 和 Resource Policy 按需加载。
- Lambda Environment Variable 默认遮罩；部署包保持手动加载，支持文件选择、源码预览和轻量语法高亮。
- Lambda 增强接口失败时局部降级，切换函数、Profile 或 Region 时取消旧详情与代码请求，并隔离过期结果。
- S3 Bucket 列表、四项 Public Access Block 状态、对象分页和前缀浏览。
- 独立读取 `sso-session` 配置节并按关联过滤 Profile；普通凭据与旧式 SSO 位于 `Other profiles`，`services` 等辅助节不作为 Profile。
- 不提供 Lambda Invoke 或其他 AWS 资源写入操作；SSO 登录只由 CLI 管理本机会话缓存。
- 修复 Profile 快速切换时 AWSClient 被覆盖但未关闭的 actor 重入竞态。
- ConfigReader、AWSServiceProvider、Profile、EC2、Lambda、S3、CloudWatch Alarms／指标／日志、SNS／配置关系、Health 事件／详情／状态流、Route 53 全局查询、ELBv2 分页／映射／状态流／目标关系、安全组／统一资源关联与精确导航、收藏／最近访问存储与导航、SSO 登录、自定义凭据桥接及 Cost 日期／服务／状态流、中英文显示与偏好持久化的 620 个单元测试。
- Swift Package 依赖锁文件纳入版本控制。

## 进行中

- 安全组与统一资源关联真实账号／窗口验收：对照当前 Profile 的 SG 规则／共享 owner／附加网卡绑定，验证直接 Alias／CNAME、canonical zone、加权记录与显式 LB 查询 Region；核对手动反查请求范围、实际权限与部分失败。验证 Explore／Back／Open、同名记录按路由标识置顶展开、跨 Region 资源重验身份、全局记录保留 Region，以及切换或清空 Profile／Session 后无旧数据。当前只展示配置关系，不证明实际流量或网络连通。
- ELBv2 真实账号与窗口验收：对照当前 Profile／Region 的 ALB／NLB／GWLB、监听器默认动作／ALB 规则、全部加权目标组与实际注册健康状态；检查五项 Describe 权限局部失败、分页及 EC2 手动扫描部分失败。验证 LB → TG → EC2／Lambda／ALB 精确跳转、IP 不跳实例、目标缺失不选首项、收藏／历史恢复 Region、切换或清空 Profile／Region 后旧数据不可见。首版仅包含 ELBv2，未包含 Classic ELB、Auto Scaling 或流量追踪。
- Route 53 真实账号与窗口验收：对照当前 Profile 的公有／私有 Hosted Zones、NS／VPC／标签、普通和 Alias／复杂路由记录、实际分页及四项 IAM 权限局部失败；确认资源 Region 不触发重查、切换或清空 Profile／session 后无旧数据、global 收藏与最近访问不改变资源 Region，目标删除／账号变化／列表失败时不误选缓存。当前展示配置，不验证实际 DNS 传播，不自动查询关联健康检查、流量策略或 VPC。
- 最近访问真实窗口与账号验收：确认仅当前可见详情计入历史，后台加载不记录；验证切换／清空 Profile、切换 session 及多窗口范围隔离，重启恢复、单条删除与清空确认；重新打开保存的 Region，检查资源删除／无权限／账号变化时保留记录并提示，不自动选 Profile、不写入收藏。
- Health 真实账号验收：与 AWS Health 控制台对照当前 Profile 账号的专属事件、未来计划变更、最新说明和受影响资源；验证 API Support 计划限制、三项读取权限、实际分页、全区域事件与资源 Region 独立，以及清空／切换 Profile 或 session 后旧数据不可见。当前页面展示事件最新状态，不保存事件每次更新的历史流水。
- 指标／日志和告警 SNS 跳转真实账号验收：与控制台对照相同 UTC 时段及 5 分钟聚合；验证指标空／部分／无权限、默认和共享日志组函数隔离、过滤语法、实际分页／取消／显示上限；验证空 Profile 不请求、切换账号／Region／资源／页签清空结果。指标需要 `cloudwatch:GetMetricData`，日志需要 `logs:FilterLogEvents`，共享组额外需要 `logs:DescribeLogStreams`；日志组配置依赖 `lambda:GetFunction`。告警 SNS 动作只跳同范围 Topic，目标删除／无权限应提示而不误选；真实查询可能产生 CloudWatch 使用费用。
- SNS 调用链真实账号验收：三类告警动作／禁用与抑制、上游权限不足、订阅部分失败、节点默认收起／点击展开后 Lambda 跳转、Endpoint 显示／隐藏、别名／版本说明、目标删除／缺权限及同名错误 ARN；确认跨账号／Region 不跳转、切换 Profile／Region／session 关闭弹窗并取消旧导航。当前只覆盖 CloudWatch 配置上游和 SNS 订阅下游。
- SNS 真实账号验收：Standard／FIFO Topic、配置策略和订阅列表、跨账号订阅 Owner、待确认／已删除状态、三项详情权限局部降级、Endpoint 显示／隐藏与切换重置、实际分页与取消；验证空 Profile 不查询，切换 Profile／Region 清除旧详情，SNS 访问不触发 Cost 重查。
- CloudWatch Alarms 真实账号验收：当前 Profile／Region 的 Metric 和 Composite 列表、筛选与刷新、单指标／Math／Insights 配置、30 天历史和标签权限局部降级；验证 ARN 收藏、分页、快速切换／取消、清空 Profile 后不再展示数据，以及切换资源 Region 不触发 Cost 重查。读取 Composite 所需 `DescribeAlarms`／`DescribeAlarmHistory` 必须允许 `Resource: "*"`。
- Cost 真实账号验收：启用 Cost Explorer 并检查读取与账单权限；对照当前账号、相同 UTC 日期／费用 Region／UnblendedCost 的控制台数据，验证管理账号不包含其他成员账号；验证无权限、数据准备中、分页、取消、退款与实际币种；切换资源 Region 不重新查询费用，切换 Profile 后旧数据清空。真实 API 调用由用户验证，可能产生调用费用。
- 使用真实只读 AWS Profile 验证 EC2、Lambda、S3 正常路径和权限不足路径。
- 真实窗口中的拖动分栏、键盘导航、源码横向滚动及 macOS 13／Intel 实机运行验收；模拟组件布局与长文本渲染已检查，通用包已完成 Apple Silicon 启动检查。
- 用户验收重点：先选 session 后点击 SSO 登录，授权成功保持 Profile 为空，手动选 Profile 后才加载；清空 Profile、重新登录、切换 session 后数据清空；取消／拒绝授权及登录中切换 session；终端登录缓存复用；多个 Profile 共用 session 时跨账号／角色切换；`Other profiles` 中仅 credentials 和旧式 SSO；自定义配置路径；快速切换账号／S3 目录；Lambda 部分 GetFunction 无权限。
- 收藏真实账号验收：EC2、Lambda、S3、CloudWatch 告警和 SNS Topic 的添加／取消／搜索、重启恢复；先手动选择匹配 Profile，再定位收藏 Region；空选项不显示收藏，跨 Profile 点击只提示、不自动选择；快速连续打开、Profile 缺失、账号变更、资源删除和权限不足时保留收藏并提示。

## 待办

以下为已讨论、尚未实现的候选功能，暂未排期；实施前再确定范围和顺序。所有 AWS 查询遵循 `AGENTS.md` 的 `AWS Query Scope`，以当前显式选择的 Profile 为单位，未选 Profile 不查询，不自动跨 Profile 聚合。

### 功能候选

- 监控后续：评估 EC2 Auto Scaling 归属和 Lambda X-Ray Trace。
- 权限诊断：在现有登录／网络／配置／权限错误分类及局部降级基础上，补充逐接口检查结果、缺少的读取权限和可操作提示。
- 资源关系后续：按需扫描 S3 Bucket 通知和 Lambda 异步目标，先明确逐资源请求开销、区域及局部失败语义；代码内 Publish 仍不能从配置完整发现。现有 SNS 弹窗已覆盖 CloudWatch 配置上游和订阅下游。
- 资源跳转后续：扩展其他关系的同 Profile 显式跨 Region 跳转，以及打开对应 AWS 控制台页面；不自动选择其他 Profile。统一关联内 DNS 显式 Region 查询与区域资源跳转、全局记录精确定位已实现；SNS 保留原有同范围跳转。
- S3 浏览增强：按需分页、逐层可点击面包屑、文本／JSON／图片内容预览和单对象下载。现有前缀浏览、Root 返回、对象元数据与后台全量翻页保留，不重复列为新增功能。
- 跨 Region 搜索：在同一个当前 Profile 下查询用户选定的多个 Region，展示资源所在区域；评估并发上限、取消、部分区域无权限和请求开销。
- 配置快照：保存与比较资源配置快照，按 Profile 和资源身份隔离；不包含创建 EBS Snapshot 或其他 AWS 资源写入。

### Cost 后续候选

- 后续候选：月末费用预测与预测区间；只读查看已有预算和费用异常。历史不足时提示预测不可用；创建预算、订阅和通知的写入能力不在当前只读范围内。
- 资源级费用：确认服务覆盖、启用条件、时间窗口和费用分摊口径，评估在 EC2／Lambda／S3 详情展示费用；不预先承诺每个资源都能获得完整精确成本。

### 工程待办

- 待确认：离线 Swift Charts 渲染在当前运行环境输出一次 AxisValueLabel anchor 警告；应用使用公开默认轴 API，分别对照标准 X／Y 锚点后警告仍存在，已撤销无效候选。当前截图坐标与数值可读，需结合真实窗口和 macOS 13 验收进一步定位，不将其报告为已修复。
- 为 S3 Bucket 详情的各类 AWS 错误增加更细粒度的模拟测试。
- 验证 S3 大目录全量分页的等待时间和内存占用。
- 应用二进制公开分发：正式签名、公证及许可附件已完成；如需创建 GitHub Release，另行确定版本说明并授权上传。

## 阻塞

- 自动化测试不调用真实 AWS；真实账号、Region 和 IAM 权限组合仍需人工只读验收。
