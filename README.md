# AWS Platform

macOS 原生 AWS 资源只读浏览工具，基于 SwiftUI 构建。

## 功能

- **EC2 实例浏览** - 查看实例状态、网络、AMI 和标签
- **Lambda 函数浏览** - 查看函数配置和部署包源码
- **S3 存储桶浏览** - 查看 Bucket 安全设置、对象和目录
- **多 Profile 支持** - 快速切换 AWS 配置文件和 Region
- **连接恢复** - 终端登录或配置文件变更后，使用 `Retry Connection` 重新加载并验证

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
│   ├── AWSServiceProvider.swift
│   └── AWSCLICredentialProvider.swift # 自定义配置路径的 SSO 凭据桥接
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

Profile 列表合并 `config` 和 `credentials` 中的名称，同名时使用 `config` 的区域等配置；仅存在于 `credentials` 的 Profile 使用默认区域 `us-east-1`。应用支持进程环境变量 `AWS_CONFIG_FILE` 和 `AWS_SHARED_CREDENTIALS_FILE`，发现配置和建立 AWS 客户端使用相同的路径。由 Finder 启动的进程不会自动继承终端中临时设置的环境变量；需要自定义路径时，可从设置了这些变量的终端运行 `swift run`。

默认配置路径下的 SSO 使用 Soto 的凭据提供器。自定义 `AWS_CONFIG_FILE` 下的 SSO 使用本机 AWS CLI v2 的 `configure export-credentials`；CLI 需安装在 `/opt/homebrew/bin/aws` 或 `/usr/local/bin/aws`（也支持 `/usr/bin/aws`），并支持该命令。应用只在内存管道中解析凭据，不显示或保存命令输出。登录时必须使用相同的环境变量和 Profile，完成后点击 `Retry Connection`。

Region 列表包含 SDK 已知的常用区域以及配置中的区域，也可以通过 Region 旁的编辑按钮输入其他区域代码。区域是否启用、所属分区和服务权限仍由 AWS 决定。

Lambda 列表通过 `GetFunction` 补充状态和标签，最多同时读取 4 个函数。部分函数权限不足或读取失败时，列表仍保留，显示提示；状态筛选不包含状态未知的函数。相关权限至少包括 `lambda:ListFunctions` 和用于补充信息的 `lambda:GetFunction`。

参考：[AWS CLI 凭据导出](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html) 、[AWS CLI 环境变量](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html) 、[Lambda 列表接口字段范围](https://docs.aws.amazon.com/lambda/latest/api/API_ListFunctions.html) 。

## 项目进度

当前阶段、验证记录和待办以 [`ROADMAP.md`](ROADMAP.md) 为准。

## License

MIT
