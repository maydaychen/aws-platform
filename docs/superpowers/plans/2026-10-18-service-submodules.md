# 已有服务子模块与资源导航补齐

## 授权、目标与边界

- 用户授权上轮列出的全部 7 项：RDS 指标、RDS 事件、通用 CloudWatch 日志浏览、RDS 快照、CodeCommit 目录／文件／提交差异／PR、S3 历史版本、ASG 启动模板版本／实例刷新记录；另含 RDS／ASG／CodeCommit 收藏／最近访问及 ASG 成员到 EC2 的跳转。
- 保持当前显式已验证 Profile／账号／稳定角色／配置路径范围；区域型按当前 Region，S3 按已验证 Bucket 实际 Region。无 Profile 不请求，切换范围清空并使迟到成功／失败／确认／分页失效。
- 只读查询，不启用版本控制／监控／日志导出，不创建／恢复快照，不修改 PR／容量／启动模板，不执行仓库内容，不调用真实 AWS。S3 既有主动传输行为不变，新历史版本仅查看。
- 本轮交付源码、离线验证、费用说明和本地提交；不打包安装、推送、发布或修改更新源。
- 计费查询手动触发，无自动轮询；GetMetricData 延续现有实现，S3 LIST 按页，CodeCommit 访问可能产生用户／请求／KMS 费用。普通日志读取不调用 StartQuery／Live Tail。费用事实以当前官方来源为准，文档区分查询与既有资源费用。

## 统一实现决策

- 不升级依赖、不引入新依赖；按现有服务／模型／VM／原生视图层组织，每文件小于 1000 行，优先小于 500 行。
- 新服务复用 provider 的身份绑定 AWSClient。root 提供 cloudWatchClient(scope:)／cloudWatchLogsClient(scope:) 的严格范围重载，既有方法保留；其他复用现有 rds／codeCommit／autoScaling／ec2／s3 scoped factory。
- 默认详情仍为概览；新子模块通过原生 Tab／Picker 或显式查看入口打开。指标、日志事件、版本列表和源码／差异查询均显式手动加载；元数据目录可在选择资源后按需加载。
- 完整列表使用循环 token／1000 页保护，失败不能冒充完整结果；日志与对象版本允许逐页加载并明确仅搜索已加载项目。分页游标绑定完整 scope／所选资源／筛选／时间窗，重复或错游标拒绝。
- 身份字段校验当前分区／服务／账号／Region／资源关系；Optional 元数据不补假值、空值与未返回区分。错误固定安全文案，不透传原始错误。AWS 原文保留但不执行、不导出秘密或记录内容。
- 仓库文件和 diff 固定 commit SHA，UTF-8／二进制明确区分，预览字节／行数有界，不下载或执行。GetDifferences 展示变更文件及有界前后内容，不创建／修改／合并 PR。仓库路径、S3 Key／分页 marker 与日志流身份按 UTF-8 字节比较，保留 Unicode 规范等价但实际不同的云端名称。
- RDS 实例和集群分别使用适用指标、事件 SourceType 和对应快照 API；快照仅当前账号所有，显式排除 shared／public，不承诺恢复已验证。
- ASG 模板查询只绑定组中已返回的模板引用，模板版本别名保持原意；不展开 UserData，不解析执行启动脚本，不发起刷新。成员跳转复用既有受范围保护的 ELBResourceReference → EC2 导航。

## 子任务、所有权与接口

1. **RDS worker**：拥有新 RDSInsights models／service／VM／views／tests，现有 RDSDatabaseDetailView.swift、ResourceMetrics.swift、AWSMetricsService.swift。接口 RDSInsightsViewModel.init(provider:)、configure(scope:database:)、reset()；手动 loadEvents()/loadSnapshots()。详情 init(vm:insightsVM:metricsVM:) 后两个参数可选缺省 nil，保持旧测试；Metrics 复用 ResourceMetricsView/ResourceMetricsViewModel，新增 RDS target 并按引擎／实例／集群适配。不得改 provider／ContentView／全局词条／文档／Git 或运行 SwiftPM。
2. **Logs／S3 worker**：拥有新 CloudWatchLogsBrowser models／service／VM／views／tests、新 S3Versions models／service／VM／views／tests，以及 S3ObjectListView.swift 局部历史入口。接口 CloudWatchLogsBrowserViewModel.init(provider:)、configure(scope:)、loadIfNeeded()、reset()，列表／详情 CloudWatchLogGroupListView(vm:)／CloudWatchLogGroupDetailView(vm:)；日志读取手动，includeLinkedAccounts=false。S3VersionsViewModel.init(provider:) 由 root 创建并可选注入 S3ObjectListView(vm:transferVM:bucketName:transferContext:versionsVM:)，子视图从已有传输上下文绑定 Owner／实际 Region／完整 Key；仅 ListObjectVersions；实际 Region 未知时，先在同一已验证范围内使用带 ExpectedBucketOwner 的 GetBucketLocation 解析区域。精确 Key 过滤／双 marker／版本及删除标记，encodingType=url 的 Key／Prefix／key marker 单次解码，version marker 原样保留，不增加下载或恢复。不得改旧 AWSLogsService／S3Transfer 服务、root 集成文件／词条／文档／Git 或运行 SwiftPM。
3. **CodeCommit worker**：拥有新 CodeCommitBrowser models／service／VM／views／tests 与 CodeCommitRepositoryDetailView.swift。接口 CodeCommitBrowserViewModel.init(provider:)、configure(scope:repository:...)、reset()；详情可选 browserVM 缺省 nil。保留当前元数据／分支头，新增显式目录／文件、固定 SHA 差异、PR 只读页。所有路径为云端标识，不作本地路径、不执行内容。不得改旧 CodeCommitViewModel 的公共行为、favorites／ContentView／词条／文档／Git 或运行 SwiftPM。
4. **ASG worker**：拥有新 AutoScalingInsights models／service／VM／views／tests，以及 AutoScalingGroupDetailView.swift／AutoScalingGroupFieldsView.swift 局部修改。接口 AutoScalingInsightsViewModel.init(provider:)、configure(scope:group:)、reset()；手动加载模板版本与实例刷新。详情可选 insightsVM 缺省 nil，onOpen: (ELBResourceReference)->Void 缺省空；成员构造当前 scope 的 EC2 reference。不得改旧 AutoScalingViewModel 行为／root 集成文件／词条／文档／Git 或运行 SwiftPM。
5. **root**：provider scope 重载、CloudWatch 日志导航／分组、ContentView 接线与最小职责抽取、收藏／最近与跳转、既有导航测试适配、全局中英词条／设计／README／ROADMAP／费用文档、统一构建／测试／截图、精确提交。
   - **本地化 worker（5a）**：仅拥有 en.lproj/Localizable.strings 与 zh-Hans.lproj/Localizable.strings，汇总四组提供的 key 和新源码静态文案，补齐唯一匹配键、占位符和中文排版；不改源代码／测试／文档，不运行 SwiftPM。root 在其冻结后复核及统一验收。
   - **公共回归 worker（5b）**：仅新增 MetadataSavedNavigationTests.swift／SubmoduleProviderScopeTests.swift，并在 ServiceSidebarPresentationTests.swift 补 CloudWatch 分组的原生验证／截图；覆盖收藏恢复、身份／配置路径边界和分组持久化。不得改生产代码／词条／其他测试，不运行 SwiftPM。
6. **独立 verifier**：只读审查源码／费用证据／最终日志／截图，确认本地源码与安装／真实 AWS 边界，输出报告和 SHA-256 manifest；不 Git 写入、不构建／测试、无 AWS／安装／发布。

所有 worker 共享工作区，不回退或覆盖其他任务；接口变更先通知 root，原有测试保持兼容。交付实际修改、接口、测试覆盖、词条清单和未解决问题，root 复核后验收。

## 验收与检查点

- P1：API／计费／现有接口核对、所有权和 UI 范围确定，已完成。
- P2：四个独立子模块完成，注入模拟测试覆盖空／无权限／未知字段、身份错配、分页／预算／后页失败、取消与跨范围／资源迟到响应；root 集成和双语完成。
- P3：严格并发＋warnings-as-errors 构建与全量测试、Harness task、词条／plist／占位符、差异／秘密检查；原生离屏验收中英／深浅色、窄分栏／长字段／空／局部失败及费用提示。
- P4：独立审查闭环、README／ROADMAP／费用说明与计划完成记录，精确本地提交，工作区无无关改动。真实 AWS 和实际窗口手动验收不由离线证据替代。


## 实施与验收记录

- 2026-10-18 22:48：P1／P2 实现完成。7 项子模块、CloudWatch 分组、收藏／最近访问与 ASG 成员导航均已接入，未升级或新增依赖。保持显式 Profile 和同组验证凭据，S3 位置未知时只读解析实际 Region；所有新增数据 API 为读取接口。
- 独立审查发现并闭环：ASG 详情未配置导致入口隐藏，仓库清空／离开未取消请求，合法名称过严限制，以及 Swift String 规范等价比较混淆不同云端名称。新路径／Key／stream／游标以 UTF-8 字节绑定；S3 历史视图额外存储前缀字节身份，使实际挂载的双向 Unicode 切换回归通过。S3 编码响应只解码 Key／Prefix／key marker 一次，版本 marker 保留原值，兼容首响应空 XML marker。
- P3 离线验证：最终 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 全量 1,329 项、相同严格参数 `swift build` 均退出 0；Harness task 三项静态门禁、双语 1,877 条唯一键／占位符与 plist 检查通过。日志、截图和独立核验记录保存在 `.tmp/service-submodules/`。
- 原生验证：ASG 从未配置的 VM 挂载真实详情，原生鼠标点击两个入口后请求计数分别为 `[1, 0]` 和 `[1, 1]`，保留 0 次自动查询及取消／迟到回调断言。测试宿主没有生成 SwiftUI 按钮 AX 语义节点，最终使用本测试窗口的公开 NSApplication 事件队列驱动真实控件，未直接调用加载方法替代点击。
- 正式离屏图共 40 张；另外 4 张 ASG／CALayer 诊断图仅作排障证据。两语事件／版本截图使用独立 VM，并在实际捕获前断言数据，避免前窗口的延迟 onDisappear 清理下一窗口。RDS 三张详情图存在原生 Tab 字形捕获缺口，CALayer 对照也不完整，因此未采用；实际 NSTabView／NSSegmentedControl 的本地化标签、选中索引和可用状态断言通过。挂载阶段两条负宽度几何警告与完整 Tab 外观保留本机验收，不据离屏结果臆断生产故障或伪造字形。
- P4 交付范围为源码、双语文档、当前官方收费边界与本地提交。未安装／推送／发布／修改更新源，未查询真实 AWS；当前本机仍为 0.3.1（15）。真实 AWS 权限、完整窗口手动交互、Intel／macOS 13 实机未由离线证据替代。
