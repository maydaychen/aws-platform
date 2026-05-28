# AWS Platform — macOS 原生资源浏览器

## 概述

一款 macOS 原生桌面应用，通过 AWS SDK 读取账号资源，提供图形化浏览体验。用户通过 `aws sso login` 完成认证后，在应用中选择 Profile，即可查看 EC2、Lambda、S3 等资源的列表与详情。

## 认证方案

用户透过终端自行执行 `aws sso login --profile <name>`，Soto SDK 通过 Profile 配置链路自动解析缓存凭据：

- `~/.aws/config` — 读取 Profile 列表
- Soto `AWSProfileConfiguration` / 默认凭据链 — 自动解析 SSO 缓存凭据
- 切换 Profile 时重新初始化服务客户端

## 技术栈

| 层     | 技术                   |
| ------ | ---------------------- |
| 语言   | Swift 5.9+             |
| UI     | SwiftUI                |
| AWS SDK | Soto (社区 Swift SDK) |
| 包管理 | Swift Package Manager  |
| 最低版本 | macOS 13+ (Ventura)    |

## 组件架构

### View 层

- **ProfileBarView** — 顶部栏，Profile 与 Region 并列选择器
- **ServiceSidebarView** — 左侧竖向 Tab 条（EC2 / Lambda / S3）
- **ResourceListView** — 中间资源列表（二级 Tab，根据选中服务渲染不同列）
- **ResourceDetailView** — 右侧详情面板，选中资源后展示完整信息
- **S3ObjectListView** — S3 Bucket 内文件浏览视图

### ViewModel 层

- **ProfileViewModel** — 读取 Config 中的 Profile 列表、管理当前选中 Profile/Region
- **EC2ViewModel** — 实例列表、选中实例详情
- **LambdaViewModel** — 函数列表、选中函数详情（含源码查看）
- **S3ViewModel** — Bucket 列表、桶内文件遍历

### Service 层

- **AWSServiceProvider** — 封装 Soto 客户端，提供了统一的 Profile → Client 初始化入口
  - `EC2Client`
  - `LambdaClient`
  - `S3Client`

## UI 布局

```
┌─────────────────────────────────────────────────────────────┐
│  🔷 AWS Platform          Profile: [dev-admin ▾]  Region: [us-east-1 ▾] │
├──────┬────────────────────┬──────────────────────────────────┤
│      │                    │                                  │
│  EC2  │  EC2 Instances     │  i-0a1b2c3d4e5f                │
│       │  ────────────────  │  ─────────────────────────────  │
│  Lambda│  i-0a1b2c... 🔘… │  Status      │ Instance Type    │
│       │  i-0f6g7h8... 🔘… │  running     │ t3.medium        │
│  S3   │  i-0l1m2n3... 🔘… │  ─────────────────────────────  │
│       │                    │  Private IP  │ Public IP        │
│       │                    │  10.0.1.15   │ 54.123.45.67     │
│       │                    │  ─────────────────────────────  │
│       │                    │  VPC: vpc-abc123                │
│       │                    │  Subnet: subnet-xyz             │
│       │                    │  AZ: us-east-1a                 │
│       │                    │  AMI: ami-xxx / Amazon Linux 2  │
│       │                    │  Tags: Name, Env, Team          │
├──────┴────────────────────┴──────────────────────────────────┤
│  状态栏 / 信息                                                │
└─────────────────────────────────────────────────────────────┘
```

## Profile & Region 选择

- 启动时读取 `~/.aws/config` 解析所有 Profile
- 下拉选择 Profile 后，默认填充该 Profile 对应的 `region` 配置
- Region 可独立切换，切换时重新初始化对应服务的 Client 并刷新列表
- 切换 Profile 时重置所有列表，重新初始化所有 Client

## 各服务展示字段

### EC2

**列表列：** Name / Instance ID / Type / State / Private IP / Public IP / OS

**详情：** 上述全部 + VPC / Subnet / AZ / Security Groups / AMI ID / AMI Name / Key Pair / Launch Time / Architecture / Tags

**OS 信息获取：** 调用 `DescribeImages` 传入 AMI ID，取 Image Description 或 Image Name 作为 OS 详情展示。

### Lambda

**列表列：** Function Name / Runtime / Last Modified / Memory

**详情：** 上述全部 + ARN / Handler / Role / Code Size / Timeout / Environment Variables / VPC Config / Tags / Code

**Code Tab：** 根据 `GetFunction` 返回的预签名 URL 下载代码 zip，解压后展示文件列表。点击文件可查看源码（支持常见扩展名高亮）。Container Image 类型的函数显示镜像 URI。

### S3

**Bucket 列表：** Bucket Name / Region / Creation Date

**Bucket 详情：** Versioning / Encryption / Public Access Block Settings / Tags

**桶内文件浏览：** 点击 Bucket 进入文件列表，支持前缀/目录向下钻取。每项显示 Key / Size / Last Modified / Storage Class。当前只读查看，不支持上传/下载操作。

## 数据流

1. 启动 → ProfileVM 读取 `~/.aws/config` 填充 Profile 列表
2. 用户选择 Profile + Region → `AWSServiceProvider` 初始化 Soto Client
3. 用户点击服务 Tab → 对应 ViewModel 调用 AWS SDK 拉列表
4. 用户点击列表中资源 → DetailView 展示详情（某些详情字段可能需要额外 API 调用）
5. 切换 Region → 重新初始化 Client，刷新列表
6. 切换 Profile → 重置所有状态，重新走 2

## 错误处理

- 凭据过期 / 未登录：提示用户重新执行 `aws sso login`
- API 调用失败：列表/详情内内行展示错误文字，不影响其他模块
- 无权限：显示具体服务返回的 AccessDenied 信息

## 后续可扩展

- 更多服务（RDS、ECS、IAM、CloudWatch 等）
- 模糊搜索 / 过滤
- 多 Region 同时查看
- 资源关系拓扑图
- 操作能力（启动/停止 EC2、触发 Lambda 等）

## 非目标

- 不处理 SSO 登录流程（用户终端自行完成）
- 不做鉴权/密钥管理
- 不提供资源创建/修改/删除能力
