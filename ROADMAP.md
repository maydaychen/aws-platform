# AWS Platform Roadmap

## 当前阶段

MVP 稳定与真实 AWS 只读验收。

## 已完成

- SwiftUI 三栏界面和 Profile、Region、服务切换。
- EC2 实例列表、详情、分页、搜索和 AMI 名称降级加载。
- Lambda 函数列表、详情、部署包文件选择、源码预览和轻量语法高亮。
- S3 Bucket 列表、四项 Public Access Block 状态、对象分页和前缀浏览。
- 过滤 AWS 配置中的 `sso-session`、`services` 等非 Profile section。
- 移除应用内 SSO 登录和 Lambda Invoke，保持只读产品边界。
- ConfigReader、Profile、EC2、Lambda、S3 的 16 个单元测试。
- Swift Package 依赖锁文件纳入版本控制。

## 进行中

- 使用真实只读 AWS Profile 验证 EC2、Lambda、S3 正常路径和权限不足路径。
- macOS 窗口布局、长文本和源码浏览交互验收。

## 待办

- 为 S3 Bucket 详情的各类 AWS 错误增加更细粒度的模拟测试。
- 补充 Profile 快速切换和请求取消的竞争条件测试。
- 确定签名、打包和发布方式。

## 阻塞

- 自动化测试不调用真实 AWS；真实账号、Region 和 IAM 权限组合仍需人工只读验收。

## 最近验证

- 2026-07-27：`swift test`，16 个测试通过。
- 2026-07-27：`swift build` 通过。
- 2026-07-27：`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过。
- 2026-07-27：`.build/debug/AWSPlatform` 启动并持续运行；Swift Package 裸可执行文件无法由 UI 自动化定位，窗口视觉验收仍待人工完成。
- 2026-07-27：未执行任何 AWS 写操作。
