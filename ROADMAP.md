# AWS Platform Roadmap

## 当前阶段

Lambda 一期详情深化完成，进入真实 AWS 只读验收。

## 已完成

- SwiftUI 三栏界面和 Profile、Region、服务切换。
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
- 过滤 AWS 配置中的 `sso-session`、`services` 等非 Profile section。
- 移除应用内 SSO 登录和 Lambda Invoke，保持只读产品边界。
- 修复 Profile 快速切换时 AWSClient 被覆盖但未关闭的 actor 重入竞态。
- ConfigReader、AWSServiceProvider、Profile、EC2、Lambda、S3 的 31 个单元测试。
- Swift Package 依赖锁文件纳入版本控制。

## 进行中

- 使用真实只读 AWS Profile 验证 EC2、Lambda、S3 正常路径和权限不足路径。
- macOS 窗口布局、长文本和源码浏览交互验收。

## 待办

- 为 S3 Bucket 详情的各类 AWS 错误增加更细粒度的模拟测试。
- 补充 S3 请求取消的竞争条件测试。
- 评估 EC2 二期 CloudWatch 指标、Auto Scaling 归属和 Load Balancer Target Health。
- 评估 Lambda 二期 CloudWatch 指标、日志检索和 X-Ray Trace。
- 确定签名、打包和发布方式。

## 阻塞

- 自动化测试不调用真实 AWS；真实账号、Region 和 IAM 权限组合仍需人工只读验收。

## 最近验证

- 2026-07-28：`swift test`，31 个测试通过；新增 Lambda 组合筛选、详情错误隔离、快速切换、分页取消和 Resource Policy 解析测试。
- 2026-07-28：`swift build` 通过；Lambda 五页签详情和列表筛选完成编译验证。
- 2026-07-28：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`，31 个测试通过。
- 2026-07-28：`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过。
- 2026-07-28：未执行 Lambda Invoke 或任何 AWS 写操作。
- 2026-07-27：`swift test`，22 个测试通过；新增 EC2 增强接口降级、组合筛选和快速切换详情隔离测试。
- 2026-07-27：`swift build` 通过；EC2 五页签详情和列表筛选完成编译验证。
- 2026-07-27：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`，22 个测试通过。
- 2026-07-27：`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过。
- 2026-07-27：尝试启动裸 Swift Package 可执行文件做视觉验收；当前 Computer Use 无法识别该窗口且无屏幕捕获权限，仍需人工验收页签布局。
- 2026-07-27：`swift test`，18 个测试通过；覆盖快速 Profile 重配置和旧校验结果隔离。
- 2026-07-27：`swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`，18 个测试通过。
- 2026-07-27：`swift build` 通过。
- 2026-07-27：`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过。
- 2026-07-27：`.build/debug/AWSPlatform` 启动并持续运行；Swift Package 裸可执行文件无法由 UI 自动化定位，窗口视觉验收仍待人工完成。
- 2026-07-27：未执行任何 AWS 写操作。
