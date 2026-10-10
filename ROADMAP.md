# AWS Platform Roadmap

## 当前阶段

App 图标已改为深蓝立体底座、橙色云与浅色资源节点，PNG 主图及 10 个标准尺寸的 ICNS 已接入各架构打包流程。隔离构建的 Apple Silicon 本地预览包 `0.2.0 (5)` 包含新图标，尚未替换本机安装或公开分发；资产与生成说明见 [App Icon](Assets/AppIcon/README.md) 。

Health 组织模式已完成本地源码、离线回归与模拟组件渲染；尚未安装到本机应用或纳入公开分发，真实组织与权限验收待完成，详见最新验证记录。

只读浏览修复、本地收藏与最近访问、统一样式、按 session 登录、Cost Explorer、CloudWatch Alarms、SNS Topics／配置调用链、告警到 SNS 跳转、EC2／Lambda 指标及 Lambda 日志、AWS Health 当前账号／组织事件、Route 53 Hosted Zones 与 DNS 记录、ELBv2 负载均衡与目标组、独立安全组、统一资源关联及中英文界面切换已完成本地回归与模拟组件渲染检查；Lambda 源码预览加固通过离线回归。面向 macOS 13+ 的 `0.2.0 (2)` 已按 Apple Silicon `arm64`／Intel `x86_64` 分别提供正式 ZIP 和 DMG，完成 Developer ID 签名、Apple 公证、票据装订及 Gatekeeper 检查；Apple Silicon 离线启动通过，Intel 与 macOS 13 实机运行仍待验收。登录后保持 Profile 为空，只有手动选择 Profile 才加载数据；用户已确认真实账号日常使用验收通过，记录见「最近验证」。

源码已按 MIT 许可证公开至 [maydaychen/aws-platform](https://github.com/maydaychen/aws-platform) ，默认分支为 `main`；[v0.2.0 Release](https://github.com/maydaychen/aws-platform/releases/tag/v0.2.0) 提供四个分架构安装包及 `SHA256SUMS.txt`。

当前分发包的源提交为 `d5f9389`，包含 Health、最近访问、Route 53、ELBv2、安全组、统一资源关联、中英文界面与 Lambda 源码预览加固，源码均已推送至 GitHub `main`。原 `0.1.0 (1)` Universal 本地产物保留。

本轮工作台交互改进已完成本地实现与回归：Profile 按配置名称／角色／账号 ID 搜索、紧凑顶部栏、区域地点名称、侧栏统一滚动／整行点击及切换动画修复、EC2 概览字段对齐；完整工程门禁、离线组件渲染与原生鼠标事件检查通过。按用户决定移除验证后的账户名称查询、缓存和权限提示，相关构建与 699 项测试通过。源提交 `c1fad8b` 已构建为 Apple Silicon `arm64` 本机预览版 `0.2.0 (4)`，安装至 `/Applications/AWSPlatform.app` 并确认完成启动、主窗口可见；采用本地 ad-hoc 签名，原 `0.2.0 (3)` 安装保留备份。本轮尚未推送或发布正式安装包，公开分发仍为上述 `v0.2.0`。

S3 单文件上传／下载、列表拖拽上传、逐层可点击面包屑与按需分页已完成本地实现与离线回归：绑定当前已验证 Profile 和 Bucket 实际 Region，支持按钮选文件或从 Finder 拖入一个本地文件到当前前缀；上传前确认目标，同名覆盖需再次确认并使用 ETag 条件写。目录先加载一页，点击「加载更多」追加；搜索仅筛选当前目录已加载项目，续页失败保留列表并可重试。按块传输、进度／取消、失败保留原有本地文件，首版上传上限为 5 GiB。覆盖不会复制原对象元数据／标签／ACL，提示及双语 README 已说明。真实分页、拖拽、写入与异常路径的逐项覆盖保留在专项验收清单；实现时未更新本机 build 4 安装、未推送或发布公开安装包。

## 最近完成

- 2026-10-11 01:36：新增云端资源工作台图标，保留透明边缘、1,024 像素 PNG 主图及多尺寸 ICNS；原生转换入口使用 `sips`／`iconutil`，不新增依赖。各架构打包统一复制图标并设置 `CFBundleIconFile`，签名前比较字节；正式分发源码保护纳入 PNG／ICNS／生成脚本，缺少或错误引用图标时停止。同步设计规范、双语 README 与脚本说明；未安装、公证、推送或发布。

- 2026-10-11 01:20：S3 新增逐层可点击面包屑与按需分页，每次请求最多 1,000 项，不自动读取整个目录；Root 和当前位置固定可见，中间祖先横向滚动。列表显示已加载数量并说明搜索范围；空页可继续、续页失败保留列表／选择和原标记，支持重试／取消，切换范围使旧响应失效。按原始 UTF-8 区分 S3 Key／前缀，避免规范等价 Unicode 名称被误去重或错误恢复选择；上传后刷新从第一页开始。同步双语文案、README 和设计规范，未操作真实 AWS、安装、推送或发布。

- 2026-10-11 01:14：Health 新增当前账号／整个组织显式切换，通过当前已验证 Profile 调用组织级只读接口；支持 AWS 侧 12 位账号 ID 筛选、受影响账号完整分页和按账号读取说明／资源。切换 Profile、查询范围、账号筛选或详情账号时清空相关旧结果并取消／隔离旧请求；组织未启用、权限和 Support 计划不足分别提示。同步双语文案、README 与模拟组件截图；未启用真实 AWS 组织服务、购买计划、安装、推送或发布。

- 2026-10-11 00:39：用户确认已进行真实账号日常使用，未发现问题，验收成功；整体使用验收状态改为通过。保留异常权限、并发覆盖、多窗口及 Intel／macOS 13 等专项清单，不把整体反馈推断为逐项覆盖或新版安装／发布记录。

- 2026-10-10 23:26：新增 S3 对象列表整栏单文件拖拽上传，空目录同样可用；拖入提示显示当前 Bucket／前缀，复用上传／覆盖确认与进度取消，不根据文件夹行改变目标。仅加载本地文件 URL 表示，拒绝多文件、目录／符号链接及非本地地址；异步解析绑定原查询范围，取消／切换后丢弃迟到回调。同步双语提示、README 与设计规范，未操作真实 AWS，未安装／推送／发布。

- 2026-10-10 23:11：新增 S3 单文件上传／下载，提供系统选择／保存窗口、当前前缀上传、目标确认、同名覆盖确认、详情／右键下载、进度与取消；新建 If-None-Match、覆盖 If-Match 防止误覆盖，实际 Region 查询失败不回退。下载使用同目录临时文件和完整成功后提交，空文件、文件变化、权限失败及迟到结果有离线回归；同步双语文案、README、设计与 S3 写入规范。未操作真实 AWS，未安装／推送／发布。

- 2026-10-10 22:25：按用户决定移除验证后才读取的 AWS 账户名称功能：删除 GetAccountInformation 调用、SotoAccount 产品依赖、名称模型／异步任务／持久化及权限提示；启动时仅清理旧名称缓存键，不改变其他偏好。Profile 保持配置名称，次行显示角色及已知账号 ID，保留多词搜索；同步双语 README、文案与设计说明。源提交 `c1fad8b` 已构建、安装并打开本机 `arm64` 预览版 `0.2.0 (4)`，产物及原安装备份保存在 `dist/local-preview-arm64-no-account-name/`；未推送或上传正式分发包。

- 2026-10-10 22:06：将包含八项工作台改进的源提交 `d857b97` 构建为本机 `arm64` Release 预览版 `0.2.0 (3)`，安装至 `/Applications/AWSPlatform.app` 并打开。App／ZIP 与安装清单位于 `dist/local-preview-arm64-d857b97/`，采用本地 ad-hoc 签名；安装前没有既有目标或运行实例，沿用 `AWSPlatform` 偏好域。未推送、执行公证或上传正式分发包。

- 2026-10-10 17:22：完成工作台易用性改进：Profile 弹框按配置名称／角色／账号 ID 多词搜索；Session、登录与 Profile 同行，窄窗口区域组换行；区域显示本地化地点与原始代码。工作区／服务共用滚动容器，菜单整行可点击，导航禁用已复现的 180 毫秒动画；EC2 概览按分组字段行对齐，长名称／ARN 换行。同步设计规范、双语使用说明和模拟 EC2 截图。账户名称功能已取消，当前状态见最新记录。

- 2026-10-08 15:02：发布 [v0.2.0](https://github.com/maydaychen/aws-platform/releases/tag/v0.2.0) ，build 为 `2`、源提交为 `d5f9389`；Apple Silicon `arm64` 与 Intel `x86_64` 各提供独立 ZIP／DMG，附统一 SHA-256 校验文件。两套 App／DMG 均完成 Developer ID 签名、Apple 公证、票据装订、Gatekeeper 及独立产物核验，Apple Silicon 空 AWS 配置启动通过。打包入口支持架构、版本与 build 参数，防止覆盖已有分发包并校验实际切片与源码提交；双语 README 增加架构下载入口，旧 `0.1.0 (1)` 本地产物保留。

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

## 最近验证

- 2026-10-11 01:40：新图标通过 1,024 × 1,024 RGBA／透明四角、32／64／128 像素视觉、ICNS 结构及 10 个标准尺寸检查。24 项离线打包测试、Shell 语法、静态 Harness 三项门禁和四份 README 引用审计通过；新增失败测试覆盖图标缺失、空文件、错误名称与缺引用。隔离构建 `0.2.0 (5)` arm64 本地 App／ZIP，独立复核源／包／解包图标字节、完整解包内容、架构／运行库及 ad-hoc 签名一致，沙箱外 `NSWorkspace` 离屏读取正确显示新图标。证据在 `.tmp/app-icon/`；未安装或启动新包，未验证安装后的 Finder／Dock 缓存、Intel／macOS 13 实机或正式公证发布，未调用真实 AWS。

- 2026-10-11 01:20：S3 隔离快照通过 Harness release 五项门禁和 761 项离线测试，最终合并工作区严格并发／警告视为错误的完整 784 项测试零失败，静态 Harness 门禁通过。新增 25 项覆盖单页／空页、失败重试、重复／循环标记、选择保留、取消／迟到结果、字面路径和 UTF-8 区分；原生鼠标事件验证祖先跳转及加载更多／重试。16 种中英文／深浅色／280 和 420 pt／分页状态渲染通过，窄列表及错误／筛选空态已检查；独立核对源文件与隔离快照一致，无剩余阻断。证据在 `.tmp/s3-browsing/`，未执行真实 AWS，新增浏览功能与 Intel／macOS 13 实机仍待专项验收。

- 2026-10-11 01:14：组织 Health 的新增服务／状态流／本地化与原生渲染回归通过；严格并发与警告视为错误的完整 `swift test` 共 784 项通过，最后的详情布局修订另通过 84 项 Health 相关回归。静态 Harness 的文件规模、diff 与设计 lint 通过，语言资源 plist 合法；模拟截图覆盖英文浅色 760 × 720 与中文深色 1060 × 720。未调用真实 AWS；management／委派管理员权限、组织启用、Support 计划和真实事件一致性仍待专项验收。

- 2026-10-11 00:39：应用真实账号日常使用验收通过，方式为用户本人实际使用并反馈「今天已经用过了，没有问题，验收成功」。具体 App build、服务／操作覆盖及异常场景未逐项提供；此记录来自用户验收，不代表 Agent 本轮执行了 AWS 查询或额外安装／发布。

- 2026-10-10 23:26：S3 拖拽上传通过 Harness release 五项门禁，736 项应用测试零失败；严格并发相关 54 项回归通过，本轮新增 10 项验证文件 URL 特殊字符／编码空字符／取消回调、单文件及 Profile／目录隔离、确认流程与失败重试。4 张中英文／深浅色列表与拖入提示截图已检查，280 pt 最窄宽度下空列表和长路径显示可用；渲染中的拖入态由测试叠加，不代表 Finder 原生命中验收。独立源码核验无剩余阻塞；证据在 `.tmp/s3-drop/`，未执行真实 AWS 传输。

- 2026-10-10 23:11：S3 文件传输最终 Harness release 五项门禁通过，726 项应用测试零失败，其中新增 27 项覆盖条件写、Profile／Region／配置路径隔离、覆盖确认、流式文件变化、下载中断／取消／空文件及本地原文件保护；严格并发相关回归通过，4 张中英文／深浅色上传与覆盖弹窗截图已检查，长 Key 字段可滚动且操作区可见。新增 Provider 测试显式使用隔离 AWS 配置路径；独立源码核验的测试隔离缺口已修正。证据在 `.tmp/s3-transfer/`；真实 AWS 与 Intel／macOS 13 实机尚未验证。

- 2026-10-10 22:25：账户名称移除通过 Harness release 五项门禁，699 项应用测试零失败；将取消功能的 18 项名称用例替换为 7 项 Profile 搜索／身份显示／旧缓存清理回归，原 11 项 SSO 登录与 12 项 Profile 状态及竞态回归保持通过。独立源码核验确认无 Account API、名称模型、SDK 产品依赖和权限提示残留；旧缓存键仅用于精确删除。新 `0.2.0 (4)` Release 构建通过，独立核验切片／最低系统／内嵌库／RPATH、1,370 条双语文案、严格深层签名和 ZIP 解压一致性通过；安装包与构建源全部 33 个节点、14 个文件的路径、类型、权限和 SHA-256 一致。NSWorkspace 确认安装 App 完成启动且未退出，CG 确认可见主窗口 1 个；证据在 `.tmp/remove-account-name/`。未执行真实 AWS 查询，实际界面与账号由用户验收。

- 2026-10-10 22:06：本机 Release 构建通过；独立核验 `arm64` 切片、macOS 13 最低系统、内嵌兼容库及 RPATH、1,371 条双语资源键、App／ZIP 解压包／安装包的严格深层签名。安装包与构建源全部 33 个节点、14 个文件的路径、类型、权限与内容哈希一致。NSWorkspace 确认 `/Applications/AWSPlatform.app` 完成启动且未退出，CGWindowList 确认可见主窗口 1 个；证据保存在 `.tmp/local-install/`。未执行真实 AWS 查询，界面效果由用户验收；Intel／macOS 13 实机及正式分发信任链不在本次本机安装范围。

- 2026-10-10 17:22：工作台改进通过 Harness release 模式五项门禁（构建、全部应用测试、文件规模、差异与设计 lint），新增 18 项 Profile 搜索／账号元数据竞态及缓存边界测试与 1 项区域名称测试；当前共 710 项应用测试。3 项离线原生视图验收覆盖中英文、深浅色、960／1280 宽度、81 个 Profile 搜索、长名称／ARN、短侧栏统一滚动，以及行右侧空白的鼠标点击与无导航动画 transaction；双语文案 1,371 条键一致、无重复，README 本地引用审计与图片检查通过，浏览器预览因 IAB 不可用／Chrome 启动退出未完成。验收使用隔离 UserDefaults／注入 loader 和 NSHostingView，无真实 AWS 调用；实际账号名称权限、真实数据量下的性能、Intel／macOS 13 窗口仍待用户验收。

- 2026-10-08 15:03：`0.2.0 (2)` 分架构发布通过 Harness release／pre-push 五项门禁、691 项应用测试和 23 项打包脚本测试；独立核验两套包的主程序／运行库切片、最低系统、双语资源、锁定依赖许可、签名、App／DMG 的 Apple Accepted 状态、票据及 Gatekeeper，ZIP 解压和 DMG 只读挂载后的 App 内容一致。Apple Silicon ZIP 副本在空 AWS 配置与隔离偏好下持续运行 8 秒；公开 Release 的四个包及校验文件均经匿名下载，字节数和 SHA-256 与本地一致，源提交为 `d5f9389`。未执行真实 AWS 查询，Intel／macOS 13 实机运行仍未验收。

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

## 已完成

- Profile 按配置名称、角色和已知账号 ID 多词搜索；不查询或缓存账户名称。顶部 Session／Profile 同行，区域含地点名，侧栏统一滚动与整行点击、导航立即切换，EC2 概览字段按组对齐。
- 应用内中英文与跟随系统设置，偏好本地持久化、现存提示即时切换、日期语言适配及原始 AWS 内容保留；语言切换不重建数据状态或查询 AWS。实现约定见 [本地化说明](docs/localization.md) 。

- 独立 Security Groups 只读页、完整规则／标签／共享 owner 展示、本地搜索与 VPC 筛选、收藏／最近访问；统一关联支持 Route 53 → LB → Target Group → EC2／Lambda／ALB，以及 EC2／LB → 安全组和权限引用。逐层查询、手动反查、缓存返回、部分失败及精确导航均按当前 Profile／身份隔离；DNS 可显式查询一个 Region，打开精确记录时置顶展开。
- ELBv2 ALB／NLB／GWLB、Target Groups、监听器／ALB 规则／加权转发和目标健康状态；关联跳转限定同 Profile／账号／Region，支持 ARN 收藏及最近访问。EC2 手动查询所属实例型目标组，保留注册端口并明确部分失败；认证摘要不包含密钥和额外参数。
- Route 53 当前 Profile／账号的全局公有／私有 Hosted Zones、DNS 记录和标签只读查询；委派 NS、VPC 关联、Alias 与各类路由配置展示，支持 global 收藏和最近访问，不执行 DNS 写入或传播检测。
- 最近访问资源历史，按当前已验证 Profile／账号隔离、每组最多 50 条；仅记录可见详情，支持本地恢复、搜索、删除／清空及重新核验账号后打开保存的资源与 Region。
- AWS Health 当前账号／整个组织只读事件记录，全区域查询、公共事件过滤、本地筛选、组织账号 ID 筛选、受影响账号列表、按账号读取最新说明与资源；调用方仍为当前已验证 Profile，未选不查询，权限、组织启用和 Support 计划不足明确提示。
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
- S3 Bucket 列表、四项 Public Access Block 状态、对象按需分页与逐层面包屑，已加载数量／搜索范围及续页重试；当前 Profile 的按钮／单文件拖拽上传、对象下载、实际 Region 解析、条件写／覆盖确认、进度／取消及本地文件保护。
- 独立读取 `sso-session` 配置节并按关联过滤 Profile；普通凭据与旧式 SSO 位于 `Other profiles`，`services` 等辅助节不作为 Profile。
- 不提供 Lambda Invoke；S3 文件上传以外的 AWS 资源保持只读，SSO 登录只由 CLI 管理本机会话缓存。
- 修复 Profile 快速切换时 AWSClient 被覆盖但未关闭的 actor 重入竞态。
- ConfigReader、AWSServiceProvider、Profile、EC2、Lambda、S3、CloudWatch Alarms／指标／日志、SNS／配置关系、Health 当前账号／组织事件与状态流、Route 53 全局查询、ELBv2 分页／映射／状态流／目标关系、安全组／统一资源关联与精确导航、收藏／最近访问存储与导航、SSO 登录、自定义凭据桥接及 Cost 日期／服务／状态流、中英文显示与偏好持久化、Lambda 源码预览限制及竞态隔离、Profile 搜索／区域名称与 S3 文件传输／拖拽上传／分页的 784 项离线测试，含原生组件交互与渲染。
- Swift Package 依赖锁文件纳入版本控制。

## 专项验收清单

用户已确认真实账号日常使用验收通过。以下保留为后续针对平台、权限、数据量与失败路径的专项检查清单，不再作为整体使用验收的阻塞；本次反馈未逐项说明这些场景的覆盖情况。

- 工作台易用性真实窗口与账号验收：大量 Profile 的配置名称／账号 ID 搜索与角色区分。用实际资源数据量检查侧栏快速切换、整行点击、短窗口滚动及宽窄窗口顶部／EC2 对齐；当前鼠标与渲染证据来自离线 NSHostingView，不代表真实账号下全部 CPU 卡顿已排除。
- 安全组与统一资源关联真实账号／窗口验收：对照当前 Profile 的 SG 规则／共享 owner／附加网卡绑定，验证直接 Alias／CNAME、canonical zone、加权记录与显式 LB 查询 Region；核对手动反查请求范围、实际权限与部分失败。验证 Explore／Back／Open、同名记录按路由标识置顶展开、跨 Region 资源重验身份、全局记录保留 Region，以及切换或清空 Profile／Session 后无旧数据。当前只展示配置关系，不证明实际流量或网络连通。
- ELBv2 真实账号与窗口验收：对照当前 Profile／Region 的 ALB／NLB／GWLB、监听器默认动作／ALB 规则、全部加权目标组与实际注册健康状态；检查五项 Describe 权限局部失败、分页及 EC2 手动扫描部分失败。验证 LB → TG → EC2／Lambda／ALB 精确跳转、IP 不跳实例、目标缺失不选首项、收藏／历史恢复 Region、切换或清空 Profile／Region 后旧数据不可见。首版仅包含 ELBv2，未包含 Classic ELB、Auto Scaling 或流量追踪。
- Route 53 真实账号与窗口验收：对照当前 Profile 的公有／私有 Hosted Zones、NS／VPC／标签、普通和 Alias／复杂路由记录、实际分页及四项 IAM 权限局部失败；确认资源 Region 不触发重查、切换或清空 Profile／session 后无旧数据、global 收藏与最近访问不改变资源 Region，目标删除／账号变化／列表失败时不误选缓存。当前展示配置，不验证实际 DNS 传播，不自动查询关联健康检查、流量策略或 VPC。
- 最近访问真实窗口与账号验收：确认仅当前可见详情计入历史，后台加载不记录；验证切换／清空 Profile、切换 session 及多窗口范围隔离，重启恢复、单条删除与清空确认；重新打开保存的 Region，检查资源删除／无权限／账号变化时保留记录并提示，不自动选 Profile、不写入收藏。
- Health 真实账号验收：组织模式还需与 management／委派管理员控制台对照受影响账号、账号筛选和按账号说明／资源，验证组织未启用、四项组织读取权限失败、90 天范围，以及切换模式／筛选／详情账号后旧数据失效；不自动启用组织服务。与 AWS Health 控制台对照当前 Profile 账号的专属事件、未来计划变更、最新说明和受影响资源；验证 API Support 计划限制、三项读取权限、实际分页、全区域事件与资源 Region 独立，以及清空／切换 Profile 或 session 后旧数据不可见。当前页面展示事件最新状态，不保存事件每次更新的历史流水。
- 指标／日志和告警 SNS 跳转真实账号验收：与控制台对照相同 UTC 时段及 5 分钟聚合；验证指标空／部分／无权限、默认和共享日志组函数隔离、过滤语法、实际分页／取消／显示上限；验证空 Profile 不请求、切换账号／Region／资源／页签清空结果。指标需要 `cloudwatch:GetMetricData`，日志需要 `logs:FilterLogEvents`，共享组额外需要 `logs:DescribeLogStreams`；日志组配置依赖 `lambda:GetFunction`。告警 SNS 动作只跳同范围 Topic，目标删除／无权限应提示而不误选；真实查询可能产生 CloudWatch 使用费用。
- SNS 调用链真实账号验收：三类告警动作／禁用与抑制、上游权限不足、订阅部分失败、节点默认收起／点击展开后 Lambda 跳转、Endpoint 显示／隐藏、别名／版本说明、目标删除／缺权限及同名错误 ARN；确认跨账号／Region 不跳转、切换 Profile／Region／session 关闭弹窗并取消旧导航。当前只覆盖 CloudWatch 配置上游和 SNS 订阅下游。
- SNS 真实账号验收：Standard／FIFO Topic、配置策略和订阅列表、跨账号订阅 Owner、待确认／已删除状态、三项详情权限局部降级、Endpoint 显示／隐藏与切换重置、实际分页与取消；验证空 Profile 不查询，切换 Profile／Region 清除旧详情，SNS 访问不触发 Cost 重查。
- CloudWatch Alarms 真实账号验收：当前 Profile／Region 的 Metric 和 Composite 列表、筛选与刷新、单指标／Math／Insights 配置、30 天历史和标签权限局部降级；验证 ARN 收藏、分页、快速切换／取消、清空 Profile 后不再展示数据，以及切换资源 Region 不触发 Cost 重查。读取 Composite 所需 `DescribeAlarms`／`DescribeAlarmHistory` 必须允许 `Resource: "*"`。
- Cost 真实账号验收：启用 Cost Explorer 并检查读取与账单权限；对照当前账号、相同 UTC 日期／费用 Region／UnblendedCost 的控制台数据，验证管理账号不包含其他成员账号；验证无权限、数据准备中、分页、取消、退款与实际币种；切换资源 Region 不重新查询费用，切换 Profile 后旧数据清空。真实 API 调用由用户验证，可能产生调用费用。
- 使用真实只读 AWS Profile 验证 EC2、Lambda、S3 浏览正常路径和权限不足路径。
- S3 新增浏览功能真实账号／窗口验收：大目录首屏与手动加载更多、只筛选已加载项目、空显示页继续分页、续页失败／取消后重试、逐层返回与特殊 Key。确认上传后重新加载第一页，新对象位于后续页时可继续查看；快速切换 Bucket／前缀／Profile 后不显示旧页，长路径祖先横向滚动且 Root／当前位置可见。
- S3 文件传输真实窗口与账号验收：由用户从 Finder 拖入单文件到根目录／嵌套目录及空列表，确认目标路径与取消／切换 Profile 后旧拖拽失效；在可测试的 Bucket 内确认上传／同名覆盖及并发冲突、空文件／普通文件下载、IAM／KMS 权限、版本控制与实际 Bucket Region。自动化不执行真实 S3 写入。
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
- S3 内容预览：文本／JSON／图片内容预览；先明确大小、类型、下载费用与敏感内容展示边界。按需分页、逐层可点击面包屑和对象元数据已实现。
- 跨 Region 搜索：在同一个当前 Profile 下查询用户选定的多个 Region，展示资源所在区域；评估并发上限、取消、部分区域无权限和请求开销。
- 配置快照：保存与比较资源配置快照，按 Profile 和资源身份隔离；不包含创建 EBS Snapshot 或其他 AWS 资源写入。

### Cost 后续候选

- 后续候选：月末费用预测与预测区间；只读查看已有预算和费用异常。历史不足时提示预测不可用；创建预算、订阅和通知的写入能力不在当前只读范围内。
- 资源级费用：确认服务覆盖、启用条件、时间窗口和费用分摊口径，评估在 EC2／Lambda／S3 详情展示费用；不预先承诺每个资源都能获得完整精确成本。

### 工程待办

- 待确认：离线 Swift Charts 渲染在当前运行环境输出一次 AxisValueLabel anchor 警告；应用使用公开默认轴 API，分别对照标准 X／Y 锚点后警告仍存在，已撤销无效候选。当前截图坐标与数值可读，需结合真实窗口和 macOS 13 验收进一步定位，不将其报告为已修复。
- 为 S3 Bucket 详情的各类 AWS 错误增加更细粒度的模拟测试。
- 验证 S3 大目录按需分页的首屏等待时间与多次追加后的内存占用。

## 自动化边界

- 自动化测试不调用真实 AWS，S3 写入只由用户主动确认发起；整体日常使用已获用户验收，其他账号／Region／IAM 组合与平台覆盖按专项清单记录。

## 工程与设计治理

- 2026-10-06 16:45：完成 Harness 接入或复核：固定验证器、配置、受控 AGENTS 摘要及四种实际 Git hooks 齐全，严格 `validate --require-hooks` 与 `task` 检查通过；`DESIGN.md` 按当前主题／组件整理并通过固定版本设计 lint（0 个错误，部分色板有未被组件引用的提示）。本轮仅工程规范与文档，无 UI 改动、全量应用构建或发布。
- 2026-10-06 16:45：本地分支均为当前工作历史的祖先，本轮规范提交后统一快进到 `main`；不删除分支，不推送远端，保留已有未提交业务改动与导出文件。
- 后续设计治理缺口：新增视觉硬编码的增量扫描／baseline，以及各实际支持主题的自动验收尚未全面接入；结构 lint 不能替代这些验收。原生运行时没有 primitive 生成链路，生成同步检查不适用。
- 共享检测器尚无本原生工程对应 Profile／Adapter；配置使用已确认的原生构建和测试入口，不声明 XcodeGen 能力。
