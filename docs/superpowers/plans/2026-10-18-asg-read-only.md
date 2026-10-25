# ASG 只读查询

## 目标与边界

- 在 EC2 分组内增加 Auto Scaling 入口，浏览当前显式选择且已验证 Profile／身份／Region 的实例组；本地搜索，无自动资源选择。
- 显示容量数值／计量类型与普通成员数、AZ／子网、启动配置／模板和混合实例摘要、负载均衡关联、健康检查、暂停进程、成员及标签。
- 手动选择组后独立读取扩缩容策略摘要和近六周活动；两者单独呈现加载、失败、取消与空结果。活动必须返回精确匹配的组 ARN，缺失身份字段时失败，避免同名旧组污染；其他可选元数据保持未知。
- 只允许 DescribeAutoScalingGroups、DescribePolicies、DescribeScalingActivities；不读取凭据文件、不调用真实 AWS、不执行资源变更，不查询指标、Warm Pool 成员或启动模板明细。
- 源码交付与本地提交；本轮不打包安装、推送、发布或修改更新源。

## 已确定接口

- 文件按现有 Models／Services／ViewModels／Views/AutoScaling 目录组织；只复用已锁定 Soto 中的 SotoAutoScaling 产品，不升级依赖。
- 模型命名 ASGGroup、ASGMember、ASGPolicy、ASGActivity，至少以组／策略 ARN 和活动 ID 稳定标识；显式 initializer，非身份字段可选或有空数组缺省。
- AWSAutoScalingService 提供 loadGroups(scope:)、loadPolicies(scope:group:)、loadActivities(scope:group:)；组参数为 ASGGroup，返回对应模型数组，支持原始 Soto 请求 closure 注入。
- AutoScalingViewModel 提供 init(provider:) 和 groupLoader／policyLoader／activityLoader 注入；scope、groups、filteredGroups、selectedGroup、policies、activities、searchText、isLoading／isPoliciesLoading／isActivitiesLoading、error／policiesError／activitiesError；configure(scope:)、loadIfNeeded()、refresh()、refreshDetails()、cancelLoading()、reset()、waitForLoading()／waitForDetails()。
- 各分页 maxRecords=100，1000 页保护上限、循环／空白 token 检测；失败不返回半份成功数据。组身份匹配分区／服务／Region／账号／名称，详情校验所选组关系。
- AutoScalingError 的 invalidScope／invalidResponse／incompletePagination 与服务 RequestError 提供固定安全文案；禁止把原始错误内容直接显示或记录。
- 组与详情分别采用 generation 防止迟到成功／失败回填；范围变化立即清空，取消保留同范围已完成结果，刷新仅按完全相同 ARN 恢复选择，手选优先。
- 数值不自动解释为台数，可选字段不补假值；启动模板保留 $Latest／$Default，组 status 不当健康状态，成员不含 Warm Pool。

## 任务与责任

1. 后端：只修改新建 Models/AutoScalingModels.swift、Services/AWSAutoScalingService.swift、Tests 中对应 service 测试／fixture；研究原始 SDK 字段并实现映射、身份／分页校验、安全错误。不得改 provider、Package、VM、UI、文档、Git 或运行 SwiftPM。
2. 状态：只修改新建 ViewModels/AutoScalingViewModel.swift 与对应 VM 测试／fixture；依赖上述接口，实现搜索、选择按需详情、独立失败、取消／刷新及范围隔离。不得改 model、service、UI、集成文件、Git 或运行 SwiftPM。
3. 主 Agent：Package／provider／AWSService／EC2 导航、ContentView 接线（保持小于 1000 行）、UI／双语词条、集成／原生离屏截图测试、设计与使用文档、统一构建／测试、精确暂存提交。
4. 独立发布验证 Agent：只读审查源码、测试／截图／日志和范围边界，核对最终产物证据，不操作 Git、AWS、安装或发布。

所有 worker 共享工作区，不得覆盖或回退他人改动；接口变更先与主 Agent 协调。交付实际文件、测试覆盖、已知限制和未解决问题，主 Agent 复核证据后验收。

## 验证与验收

- 服务模拟覆盖有效／无效身份、其他账号／区域、同名重建活动、完整／空页、循环／预算、重复 ID、后页失败、取消、未知／缺省字段和容量计量语义。
- VM 模拟覆盖无 Profile 不请求、手动选择、独立详情失败、切换组／Profile／角色／Region／路径、取消／刷新及迟到响应、无自动选择、精确 ARN 恢复和手选优先。
- 严格并发与 warnings-as-errors 构建／全量测试，Harness task、双语 plutil／词条覆盖、diff 和敏感信息检查；原生离屏检查中英文、深浅色、窄列表／详情、长字段与错误状态。
- 离线测试与截图不等于真实 AWS IAM／SSO／数据或实际窗口交互验收，交付如实说明；本机已安装版本仍以 ROADMAP 为准。

## 状态

- 2026-10-18 19:47：源码实现与离线验收完成。严格并发／warnings-as-errors 全量测试 1,107 项（新增 67 项 ASG）和主程序构建通过；Harness task、1,708 条双语键／plist／117 条 ASG 静态文案检查通过。13 张窄分栏中英／深浅色原生截图完成主 Agent 与独立检查。
- 独立审查统一了活动缺失组 ARN 的失败语义；合法空白名称／标签保持原文，空标签值与未返回区分；首轮中文导航词条失败已修正并全量通过。证据位于 `.tmp/asg-query/`。
- 本轮不调用真实 AWS、不安装或正式分发；当前本机 `0.3.1 (15)` 尚未包含 RDS／ASG，实际账号与交互验收保留后续进行。
