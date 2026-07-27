# AWS Platform

macOS 原生 AWS 资源只读浏览工具，基于 SwiftUI 构建。

## 功能

- **EC2 实例浏览** - 查看实例状态、网络、AMI 和标签
- **Lambda 函数浏览** - 查看函数配置和部署包源码
- **S3 存储桶浏览** - 查看 Bucket 安全设置、对象和目录
- **多 Profile 支持** - 快速切换 AWS 配置文件和 Region

应用不提供资源创建、修改、删除或 Lambda 调用能力。

## 技术栈

- Swift 5.9+ / SwiftUI
- macOS 13+
- [Soto](https://github.com/soto-project/soto) - AWS SDK for Swift

## 快速开始

### 前置条件

- macOS 13.0+
- Xcode 15.0+ 或 Swift 5.9+
- 已配置 AWS CLI (`~/.aws/config` 和 `~/.aws/credentials`)
- 使用 SSO 时，已在终端执行 `aws sso login --profile <name>`

### 构建运行

```bash
# 克隆仓库
git clone https://www.maydaychenhome.top:18779/maydaychen-mac/aws-platform.git
cd aws-platform

# 构建
swift build

# 运行
swift run

# 测试
swift test
```

### Xcode

```bash
open Package.swift
```

在 Xcode 中直接 Cmd+R 运行。

## 项目结构

```
Sources/AWSPlatform/
├── App.swift                    # 应用入口
├── ContentView.swift            # 主视图
├── Models/                      # 数据模型
│   ├── AWSProfile.swift
│   ├── EC2Instance.swift
│   ├── LambdaFunction.swift
│   └── S3Bucket.swift
├── Services/                    # AWS 服务层
│   └── AWSServiceProvider.swift
├── Utilities/                   # 工具类
│   ├── ConfigReader.swift
│   └── UserFacingError.swift
├── ViewModels/                  # 视图模型
│   ├── EC2ViewModel.swift
│   ├── LambdaViewModel.swift
│   ├── ProfileViewModel.swift
│   └── S3ViewModel.swift
└── Views/                       # 界面视图
    ├── EC2/
    ├── Lambda/
    ├── S3/
    ├── ProfileBarView.swift
    ├── ServiceSidebarView.swift
    └── SharedViews.swift

Tests/AWSPlatformTests/           # 配置解析和 ViewModel 单元测试
```

## AWS 配置

确保 `~/.aws/config` 文件格式正确：

```ini
[default]
region = us-east-1
output = json

[profile my-profile]
region = ap-northeast-1
output = json
```

AWS CLI 的 `[sso-session ...]`、`[services ...]` 等辅助配置节不会显示为可选 Profile。

## 项目进度

当前阶段、验证记录和待办以 [`ROADMAP.md`](ROADMAP.md) 为准。

## License

MIT
