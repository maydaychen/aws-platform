# AWS Platform Roadmap

## 当前阶段

只读浏览修复、本地收藏、统一样式和按 session 登录已完成本地回归与模拟组件渲染检查。登录后保持 Profile 为空，只有手动选择 Profile 才加载数据；等待用户进行真实 AWS 账号验收。

## 最近完成

- 2026-10-03 10:13：将前期推荐但尚未实现的功能及 Cost 分期候选合并到待办，区分已有能力与新增范围；仅记录后续计划，未启动功能开发。
- 2026-10-03 10:09：将后续 AWS 查询统一以显式选择的 Profile 为单位的长期约束写入 `AGENTS.md` 的 `AWS Query Scope`；涵盖 Session 登录边界、未选不查询、禁止自动跨 Profile 聚合，以及切换时的请求与缓存隔离。仅更新项目规范，未修改运行代码。
- 2026-10-03 10:02：SSO 登录与账号选择分离：独立选择 session 并调用 `aws sso login --sso-session`，登录成功、启动、重新登录和切换 session 都不自动选择 Profile。Profile 列表按 session 过滤，空选项不验证身份、不查询或显示资源；普通／旧式 Profile 保留在 `Other profiles`。收藏只在手动选中匹配 Profile 后定位。保留取消、5 分钟超时、错误分类及自定义路径，登录子进程隔离环境 Profile；修复即时登录失败提示被延迟界面更新清除的问题。README 和三张模拟组件截图已同步。
- 2026-10-03 03:00：统一配置栏、紧凑服务导航、收藏及资源列表、详情网格、标签与环境变量分组、空态和警告样式；改善长名称／ARN／路径、深浅色代码阅读和图标可访问标签。补齐资源行选择标识；S3 对象空态限制在列表内，保留搜索／刷新入口。两张模拟组件截图由 README 提供入口。
- 2026-10-03 02:33：增加 EC2、Lambda、S3 Bucket 本地收藏、搜索、取消收藏和侧栏快捷入口；按 Profile、账号、浏览 Region、服务和资源 ID 隔离，定位资源前校验账号。不可用收藏保留并提示，损坏存储保留原始数据且禁用编辑。补充 EC2 列表请求代次校验，阻止旧请求错误清空新收藏目标列表。
- 2026-10-03 01:10：修复 S3 列表、详情和对象请求的过期结果／错误回填；补全 Lambda 列表状态与标签并限制补充请求并发为 4；增加连接重试与凭据客户端重建；合并 config／credentials Profile 并支持自定义路径；扩展 Region 选择与手动输入。自定义配置路径的 SSO 使用本机 AWS CLI v2 凭据桥接，输出仅在内存中解析。
- 2026-09-29 16:40：刷新等待态移入列表工具栏并短暂淡化，刷新期间保留资源行；详情文本按资源身份交接，保留详情页状态，Profile／Region 切换重置展示作用域，支持系统减少动态效果。请求和权限逻辑未变。

## 最近验证

- 2026-10-03 10:13：核对待办与此前功能建议、当前已完成清单及 Profile 查询约束的一致性，检查 Markdown 结构和 `git diff --check` 通过；仅文档变更，未运行 Swift 测试或 AWS 查询。
- 2026-10-03 10:09：检查 `AGENTS.md` 新增规则的 Markdown 结构、关键约束及与现有 Session／Profile 流程的一致性，`git diff --check` 通过；本次仅文档变更，未重复运行 Swift 测试。
- 2026-10-03 10:02：最终正式测试集 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 构建成功，104 项测试全部通过，`git diff --check` 通过。覆盖独立 session 解析／登录、空 Profile 不调用身份校验、显式选择、取消及过期结果、配置重载、收藏不自动选 Profile、登录环境隔离及即时失败提示。另有 2 项临时渲染测试通过，生成 8 种流程状态在 960／1280 宽度与深浅色下的 32 张截图及 2 张资源示例；已抽查关键空态、等待、选中、切换状态和资源示例，临时测试入口已移除。独立检查核对关键代码、测试日志及组件截图；未执行真实 AWS 登录或请求，浏览器授权完整链路、实际窗口交互与 macOS 13 运行时仍待验收。
- 2026-10-03 09:18：正式测试集 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 构建成功，87 项测试通过，`git diff --check` 通过。新增 18 项测试覆盖参数与环境隔离、失败输出保护、进程退出／取消／超时及强制清理、重复登录、迟到结果、身份重验和错误分类。另以临时离线渲染测试生成 6 种状态在 960／1280 宽度和深浅色下的 24 张截图，已检查登录栏布局，临时测试入口已移除。没有执行真实 AWS 登录或资源请求，浏览器授权、自动重连的真实账号完整链路及 macOS 13 运行时待验收。
- 2026-10-03 03:10：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 构建成功，69 项测试通过。新增 3 项配置测试覆盖 Profile 独立账号／角色／资源 Region 和辅助节过滤；对照 AWS 官方文档与锁定的 Soto 源码，确认按 Profile 解析关联 session、按 session 名称查找缓存。未执行真实 SSO 登录、凭据导出或资源请求，共享会话的真实账号切换仍待验收。
- 2026-10-03 03:01：正式测试集 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 构建成功，66 项测试通过，`git diff --check` 通过。临时离线渲染入口另行通过，生成 20 种页面／状态在 960×600、1280×800 和深浅色下的 80 张首屏截图及滚动位置截图；已核对所有服务页签、收藏、长字段、环境变量遮罩、代码、容器镜像、二进制文件、空态及错误／警告布局。临时测试入口已移除；未调用真实 AWS，截图是模拟组件组合，不代表完整应用交互或 macOS 13 实机验收。
- 2026-10-03 02:35：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 构建成功，66 项测试通过；新增 14 项收藏存储／导航测试和 1 项先失败后修复的 EC2 迟到错误回归。覆盖持久化、去重、损坏数据保护、搜索、账号隔离、资源定位及失效收藏保留。模拟数据的独立收藏组件完成浅色／深色离线渲染检查，文字与星标可辨；`git diff --check` 通过。未调用真实 AWS，未验收完整窗口交互或 macOS 13 运行时。
- 2026-10-03 01:10：先以两个失败回归复现 S3 重置后旧数据回填、旧错误清空新数据；最终 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 构建成功，51 项测试通过，较原有增加 20 项。覆盖迟到成功／失败、目录切换、加载状态归属、Lambda 状态缺失与权限降级、连接重试、配置路径、Region 恢复及凭据输出隔离。`git diff --check` 通过；未连接真实 AWS，未运行实际 CLI 凭据导出，未验证窗口渲染。
- 2026-09-29 16:40：最终代码 `swift test` 构建成功，31 项模拟服务单元测试通过；`git diff --check` 通过。未调用真实 AWS 服务，macOS 13 运行时、窗口视觉及真实账号切换仍需后续验收。

## 已完成

- 应用内按具名 session 登录、取消和超时提示；登录后不选 Profile、不加载账号数据。手动选择关联 Profile 后验证并加载资源，支持共享 session 及自定义配置路径。
- 全部页面采用统一搜索框、资源计数、自适应详情卡片及原生深浅色；长详情值可换行与选择复制，环境变量仍默认遮罩。
- 本地资源收藏、搜索与定位；先手动选择匹配 Profile，再恢复收藏 Region 并校验账号。仅保存资源定位元数据，应用窗口共享列表，重启后恢复。
- SwiftUI 三栏界面和 Session、Profile、Region、服务切换；启动仅恢复 session，Profile 始终由用户显式选择；空选项下隐藏全部资源列表与详情。
- EC2 实例列表、分页、搜索、实例状态筛选、Status Check 筛选和 AMI 名称降级加载。
- EC2 五页签详情：Overview、Network、Storage、Security、Status。
- EC2 ENI、EBS、Security Group 规则、IMDSv2、实例健康检查和 Scheduled Events 按需加载。
- EC2 状态、磁盘或安全组增强接口失败时局部降级，不清空实例列表或基础详情。
- EC2 切换实例、Profile 或 Region 时取消旧详情请求，并隔离过期结果。
- Lambda 函数列表、状态和 Package Type 组合筛选。
- Lambda 五页签详情：Overview、Configuration、Triggers、Versions、Code。
- Lambda Event Source Mapping、异步调用配置、Function URL、Versions、Aliases、Reserved / Provisioned Concurrency 和 Resource Policy 按需加载。
- Lambda Environment Variable 默认遮罩；部署包保持手动加载，支持文件选择、源码预览和轻量语法高亮。
- Lambda 增强接口失败时局部降级，切换函数、Profile 或 Region 时取消旧详情与代码请求，并隔离过期结果。
- S3 Bucket 列表、四项 Public Access Block 状态、对象分页和前缀浏览。
- 独立读取 `sso-session` 配置节并按关联过滤 Profile；普通凭据与旧式 SSO 位于 `Other profiles`，`services` 等辅助节不作为 Profile。
- 不提供 Lambda Invoke 或其他 AWS 资源写入操作；SSO 登录只由 CLI 管理本机会话缓存。
- 修复 Profile 快速切换时 AWSClient 被覆盖但未关闭的 actor 重入竞态。
- ConfigReader、AWSServiceProvider、Profile、EC2、Lambda、S3、收藏存储／导航、SSO 登录和自定义凭据桥接的 104 个单元测试。
- Swift Package 依赖锁文件纳入版本控制。

## 进行中

- 使用真实只读 AWS Profile 验证 EC2、Lambda、S3 正常路径和权限不足路径。
- 真实窗口中的拖动分栏、键盘导航、源码横向滚动及 macOS 13 运行时验收；模拟组件布局与长文本渲染已检查。
- 用户验收重点：先选 session 后点击 SSO 登录，授权成功保持 Profile 为空，手动选 Profile 后才加载；清空 Profile、重新登录、切换 session 后数据清空；取消／拒绝授权及登录中切换 session；终端登录缓存复用；多个 Profile 共用 session 时跨账号／角色切换；`Other profiles` 中仅 credentials 和旧式 SSO；自定义配置路径；快速切换账号／S3 目录；Lambda 部分 GetFunction 无权限。
- 收藏真实账号验收：三个服务的添加／取消／搜索、重启恢复；先手动选择匹配 Profile，再定位收藏 Region；空选项不显示收藏，跨 Profile 点击只提示、不自动选择；快速连续打开、Profile 缺失、账号变更、资源删除和权限不足时保留收藏并提示。

## 待办

以下为已讨论、尚未实现的候选功能，暂未排期；实施前再确定范围和顺序。所有 AWS 查询遵循 `AGENTS.md` 的 `AWS Query Scope`，以当前显式选择的 Profile 为单位，未选 Profile 不查询，不自动跨 Profile 聚合。

### 功能候选

- 最近访问：本地记录访问过的资源，按 Profile 隔离；打开记录前要求已手动选择匹配 Profile，沿用收藏的账号校验与失效提示。
- 指标与日志：EC2／Lambda 的 CloudWatch 指标、Lambda 日志检索；保留后续评估 EC2 Auto Scaling 归属、Load Balancer Target Health 和 Lambda X-Ray Trace。
- 权限诊断：在现有登录／网络／配置／权限错误分类及局部降级基础上，补充逐接口检查结果、缺少的读取权限和可操作提示。
- 资源跳转：应用内关联资源导航，以及打开对应 AWS 控制台页面；不因跳转自动选择其他 Profile。
- S3 浏览增强：按需分页、逐层可点击面包屑、文本／JSON／图片内容预览和单对象下载。现有前缀浏览、Root 返回、对象元数据与后台全量翻页保留，不重复列为新增功能。
- 跨 Region 搜索：在同一个当前 Profile 下查询用户选定的多个 Region，展示资源所在区域；评估并发上限、取消、部分区域无权限和请求开销。
- 配置快照：保存与比较资源配置快照，按 Profile 和资源身份隔离；不包含创建 EBS Snapshot 或其他 AWS 资源写入。

### Cost 候选

- 基础费用面板：本月累计、上月费用、日趋势及按服务费用明细；独立费用 Region 筛选、缓存和手动刷新，展示数据日期、币种、成本口径与估算状态。
- 接入与范围：实施前确认 Cost Explorer 启用状态、读取权限、调用开销及数据延迟；区分未启用、权限不足、数据准备中和空结果。明确展示当前 Profile 的查询身份与实际账号可见范围，账号筛选依据权限提供，不把付款账号的组织费用误标为单一成员账号费用。
- 后续候选：月末费用预测与预测区间；只读查看已有预算和费用异常。历史不足时提示预测不可用；创建预算、订阅和通知的写入能力不在当前只读范围内。
- 资源级费用：基础面板完成后，再确认服务覆盖、启用条件、时间窗口和费用分摊口径，评估在 EC2／Lambda／S3 详情展示费用；不预先承诺每个资源都能获得完整精确成本。

### 工程待办

- 为 S3 Bucket 详情的各类 AWS 错误增加更细粒度的模拟测试。
- 验证 S3 大目录全量分页的等待时间和内存占用。
- 确定签名、打包和发布方式。

## 阻塞

- 自动化测试不调用真实 AWS；真实账号、Region 和 IAM 权限组合仍需人工只读验收。
