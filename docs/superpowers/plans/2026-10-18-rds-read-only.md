# RDS 只读查询

## 目标与边界

用户授权加入 RDS 查询。第一版提供当前已验证 Profile／身份／Region 的 DB 实例与 DB 集群列表、类型筛选、本地搜索和详情。仅使用 DescribeDBInstances、DescribeDBClusters，消费其自带 tagList，不新增标签／指标／日志／快照请求，不建立数据库连接或执行 SQL，不创建／修改／重启资源。集群显式 includeShared=false，排除 Describe 返回的 Neptune／DocumentDB，引擎未知值仍保留。无真实 AWS、安装、推送或发布；不是 Goal。

RDS 为独立一级区域服务，复用已锁定 SotoRDS product，不引入第三方依赖或更新锁文件。两类列表独立完整分页、独立错误／取消，部分成功保持可见；未验证 Profile 零调用，范围变化与同范围刷新使旧回调失效。无自动资源选择，本轮不增加收藏／最近访问，旧保存导航明确拒绝。

## R1：模型、服务及离线服务测试（backend worker）

- 所有权：新增 `Models/RDSModels.swift`、`Services/AWSRDSService.swift`、`Tests/AWSPlatformTests/AWSRDSServiceTests.swift` 及专用 fixture；禁止修改 Provider／Package／VM／UI／词条／文档。只用现有 SDK；不运行 SwiftPM、不调用 AWS、不 Git 写入。
- 锁定模型：`RDSResourceKind: String, CaseIterable, Identifiable, Sendable`，case instance/cluster，`title` 返回 DB instances/DB clusters，`singularTitle` 返回 DB instance/DB cluster；`RDSClusterMember: Identifiable, Hashable, Sendable`，`identifier:String`、`isWriter:Bool?`、`promotionTier:Int?`，id 为 identifier。
- `RDSDatabase: Identifiable, Hashable, Sendable`，id 为 arn。字段：`arn, identifier:String`、`kind:RDSResourceKind`；`engine, engineVersion, status, instanceClass, clusterIdentifier, endpoint, readerEndpoint, availabilityZone, secondaryAvailabilityZone, storageType, kmsKeyID, vpcID, subnetGroup, engineMode:String?`；`port, allocatedStorageGB, backupRetentionDays:Int?`；`multiAZ, publiclyAccessible, encrypted, deletionProtection:Bool?`；`availabilityZones, subnetIDs, securityGroupIDs:[String]`；`members:[RDSClusterMember]`；`tags:[String:String]?`；`createdAt:Date?`；`serverlessV2MinACU, serverlessV2MaxACU:Double?`。提供显式 init，arn/identifier/kind 必填，其他参数默认 nil 或空集合，便于离线 fixtures。
- 服务接口 `AWSRDSService(provider:)`；`loadInstances(scope:MonitoringScope) async throws -> [RDSDatabase]`；`loadClusters(scope:)` 同返回。请求级注入 `instanceLoader`／`clusterLoader`，分别为 SotoRDS 两个 Describe input→output 的 @Sendable async throws closures。生产通过主 Agent 新增 `provider.rdsClient(scope:)` 获得同一身份绑定 AWSClient。
- 固定 maxRecords=100、集群 includeShared=false；分别消费 marker，1000 页预算，循环／空白 marker 拒绝，空末标记可结束；缺页／重复 ARN 或 identifier（同类型）／缺少必需身份不得返回部分成功。验证 ARN partition、service=rds、Region、account、db:/cluster: 类型及 identifier 一致。先排除 engine=neptune/docdb，其余引擎不做封闭 allowlist。
- 映射只消费返回字段，Bool=nil 保持未知；creating 无端点有效，tags=nil 与空字典可区分，重复 tag key 拒绝。集群无 VPC/subnet IDs 时保持 nil/空，不从成员臆推；engineMode 原样保留，Serverless v2 容量仅显示实际配置。元数据和关联 ID 不触发跨服务查询。错误用 `RDSError` 或 `AWSRDSService.RequestError` 安全 LocalizedError 分类，不回显原始 SDK/响应文本，列出全部 key 交 root 本地化。
- 验收：多页／空中间页／循环 marker／页数预算／续页失败／取消；两类相同 identifier 不碰撞；错账号／Region／partition／类型／identifier 拒绝；Neptune/DocumentDB 排除、未知未来引擎保留、缺端点／可选 Bool／TagList／成员／Serverless v2 和局部错误；不真实 AWS。

## R2：状态流及回归（viewmodel worker）

- 所有权：新增 `ViewModels/RDSViewModel.swift`、`Tests/AWSPlatformTests/RDSViewModelTests.swift`，必要时把专用 fixture 拆入 `RDSViewModelFixture.swift`；禁止修改 R1／Provider／Package／UI／词条／文档。其他 Agent 同库工作，不回滚他人内容；不 SwiftPM、不 AWS、不 Git 写入。
- 接口：`init(provider:)`；注入 `instanceLoader`／`clusterLoader`，均 `(MonitoringScope) async throws -> [RDSDatabase]`；`scope:MonitoringScope?`；`instances,clusters,databases,filteredDatabases:[RDSDatabase]`；`selectedDatabase:RDSDatabase?`；`searchText:String`、`kindFilter:RDSResourceKind?`（nil 全部）可绑定；`isInstancesLoading,isClustersLoading,isLoading:Bool`；`instanceError,clusterError,error:String?`（error 汇总非空局部错误）。方法 `configure(scope:MonitoringScope?)`、`loadIfNeeded()`、`refresh()`、`cancelLoading()`、`reset()`、`waitForLoading() async`。
- configure 仅绑定／清理，不发请求；有效 scope 仍由可见页 loadIfNeeded 触发。两类各 task 与错误，独立完成并显示；refresh 清旧列表／选择并保留旧 ARN 作为恢复目标，两类返回后仅恢复完全相同 ARN，不自动选第一项；用户中途手选后迟到另一类型不得改回旧选择。刷新失败仍保留另一类型成功，取消只失效在飞请求并给对应取消提示，保留已成功的同范围列表和选择。scope/reset 清空所有数据／筛选，旧成功与旧错误均不能回填。
- 搜索按 identifier/engine/ARN/端点本地完成，kind filter 不请求 API；选中项必须在当前已加载列表中，实例与集群同名按 ARN 区分。无有效 scope 零请求；无 scope/无数据/无匹配/权限失败/取消不混为空成功。只透传两种安全错误类型，其他错误使用操作级兜底，不回显任意描述。
- 验收：无 scope/invalid scope 零调用；独立成功与一类权限失败、双失败、无资源／本地搜索和类型过滤；同名两类；刷新恢复和手选优先；切换 Profile/Region/role/paths、同 scope 刷新、取消的迟到成功／失败；不自动选择资源。

## R3：接入、视图、集成／渲染与文档（主 Agent）

维护 Package、Provider scoped factory、AWSService／ContentView／FavoriteNavigation；ContentView 控制在 1000 行以下，不重构其他服务。新 UI 置 `Views/RDS/`，复用 ListToolbar、DetailFieldRows、DetailSectionTitle、NoticeBanner、EmptyStateView、ResourceListFooter；原生类型 Picker、可复制长 ARN／端点、缺省值／可选 Bool 显示未知，RDS 原始状态／引擎保留。详情按概览、端点／网络、存储／保护、集群成员、标签分组。集群仅有 subnet group 名时不声称有 VPC/subnet 明细；engineMode=provisioned 不推断排除 Serverless v2。

补 Provider scope／standalone／保存导航集成回归，280 pt 列表／480 pt 详情中英与深浅色原生离屏渲染，长字段和 partial errors。同步 DESIGN、双语 README／词条、ROADMAP 和当前实施状态。只执行离线构建／测试，不安装或操作真实 AWS。

## R4：独立只读验收

核对真实 diff 与证据：仅两个读 API、明确当前 Profile/身份/Region、includeShared=false、返回身份、完整分页、非 RDS 引擎处理、未知与 Serverless 语义、两类局部失败、刷新／取消／范围代次隔离与原生布局。只读，不构建、不 Git 写入、不 AWS／安装；证据写 `.tmp/rds-query/verification/`。主 Agent 最小复核后统一严格构建／测试、Harness／本地化与最终提交。

## 当前状态

2026-10-18 13:28：R1/R2/R3 已完成，R4 源码和截图独立复核未发现阻断项。最终严格并发／警告视为错误的全量 `swift test` 1,040 项、`swift build`、Harness task 三项静态门禁通过；新增 52 项离线回归。两语言各 1,612 个唯一且匹配的 key、占位符与 plist 检查通过，66 条 RDS 文案校验通过；ContentView 为 977 行，13 个文件规模警告无硬上限失败。

9 张原生离屏截图覆盖中英／深浅色、280 pt 列表／480 pt 详情、长 ARN／端点／成员／标签、Serverless v2 容量、nil 未知值及局部／双权限失败。首轮构建的 `Double?.map(String.init)` 歧义通过最小片段定位并改为明确转换，随后 3 项定向渲染和全量回归通过；本地化静态检查发现并修正一处 Unicode key 转义，最终截图与词条检查通过。

源与验证日志、截图及独立复核保存在 `.tmp/rds-query/`。仅完成源码交付，未调用真实 AWS、安装、推送、发布或修改更新源；当前本机仍为不含 RDS 的 `0.3.1 (15)`。真实账号权限／服务行为、完整窗口手动交互及 Intel／macOS 13 实机仍待专项验收。
