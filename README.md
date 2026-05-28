# AWS Platform

macOS 原生 AWS 资源管理工具，基于 SwiftUI 构建。

## 功能

- **EC2 实例管理** - 查看、监控 EC2 实例状态
- **Lambda 函数管理** - 浏览 Lambda 函数，查看代码和配置
- **S3 存储桶管理** - 浏览存储桶和对象，查看文件详情
- **多 Profile 支持** - 快速切换 AWS 配置文件

## 技术栈

- Swift 5.9+ / SwiftUI
- macOS 13+
- [Soto](https://github.com/soto-project/soto) - AWS SDK for Swift

## 快速开始

### 前置条件

- macOS 13.0+
- Xcode 15.0+ 或 Swift 5.9+
- 已配置 AWS CLI (`~/.aws/config` 和 `~/.aws/credentials`)

### 构建运行

```bash
# 克隆仓库
git clone https://www.maydaychenhome.top:18779/maydaychen-mac/aws-platform.git
cd aws-platform

# 构建
swift build

# 运行
swift run
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
│   └── ConfigReader.swift
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
```

## AWS 配置

确保 `~/.aws/config` 文件格式正确：

```ini
[profile default]
region = us-east-1
output = json

[profile my-profile]
region = ap-northeast-1
output = json
```

## License

MIT
