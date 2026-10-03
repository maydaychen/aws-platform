# AWS Platform

macOS 原生 AWS 资源只读浏览工具，基于 SwiftUI 构建。

## 功能

- **EC2 实例浏览** - 查看实例状态、网络、AMI 和标签
- **Lambda 函数浏览** - 查看函数配置和部署包源码
- **S3 存储桶浏览** - 查看 Bucket 安全设置、对象和目录
- **Session 与 Profile 分开选择** - 按 session 登录，再手动选择关联的 Profile 和 Region；未选 Profile 时资源区域保持空白
- **SSO 登录** - 应用内点击 `SSO Login`，由浏览器完成 session 授权；也支持复用终端登录缓存
- **资源收藏** - 本地保存 EC2 实例、Lambda 函数和 S3 Bucket，搜索并在当前 Profile 内恢复收藏时的 Region
- **原生桌面布局** - 紧凑服务导航、带计数的资源列表、自适应详情网格，以及跟随系统的深浅色界面

应用不提供资源创建、修改、删除或 Lambda 调用能力。

以下是使用模拟资源渲染的应用组件示例：

![浅色 EC2 概览](docs/ui-overview-light.png)

![深色 Lambda 代码页](docs/ui-code-dark.png)

## 技术栈

- Swift 5.9+ / SwiftUI
- macOS 13+
- [Soto](https://github.com/soto-project/soto) - AWS SDK for Swift

## 快速开始

### 前置条件

- macOS 13.0+
- Xcode 15.0+ 或 Swift 5.9+
- 已配置 AWS CLI (`~/.aws/config` 和 `~/.aws/credentials`)
- 使用 SSO 时，先配置具名 `sso-session` 并安装 AWS CLI v2；可在应用内点击 `SSO Login` 或在终端执行 `aws sso login --sso-session <name>`。浏览资源还需配置引用该 session 的 Profile

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

### 资源收藏

在资源详情顶部点击 `Add Favorite` 收藏，再次点击 `Remove Favorite` 取消。侧栏 `Favorites`（快捷键 `Cmd+Shift+F`）集中展示收藏，可按资源名称、ID、服务、Profile、账号或 Region 搜索；点击条目打开资源，点击星标或使用右键菜单移除收藏。

先手动选择 Profile，收藏列表才会显示。打开收藏时，应用要求当前 Profile 与收藏一致，再恢复保存的 Region、校验账号并定位资源；不会通过收藏自动选择其他 Profile。Profile 不一致或缺失、账号不匹配、资源已删除或访问失败时会显示提示，收藏仍会保留。S3 收藏保存的是收藏时的浏览 Region，Bucket 实际位置由现有加载流程另行解析。

收藏通过本机 UserDefaults 保存，重启后恢复，同一应用进程的多个窗口共享收藏列表。保存内容仅包含 Profile 名称、账号 ID、Region、服务、资源 ID 和显示名称；不保存凭据、资源详情或环境变量，不进行云端同步。相同资源在不同 Profile、账号或浏览 Region 下分别保存。

### 应用内 SSO 登录

1. 在 `SSO Session` 中选择已配置的 session，点击 `SSO Login`。应用后台调用本机 `aws sso login --sso-session <name>`，由 AWS CLI 打开默认浏览器完成授权；不会打开终端窗口，也不需要预先选择 Profile。
2. 登录成功后，Profile 保持 `Select profile`，资源列表与详情保持空白，不发送账号身份验证或资源查询请求。
3. 手动选择关联该 session 的 Profile 后，应用才验证身份并加载该 Profile 对应账号、角色和 Region 的资源。切换 session、重新登录或将 Profile 改回 `Select profile`，都会清空当前选择和资源展示。

应用只记住上次选择的具名 session；每次启动都需要重新手动选择 Profile。有效的 AWS CLI 登录缓存可以直接复用，不必每次点击登录。即使一个 session 只有一个 Profile，也不会自动选中；只有 session、尚未配置任何关联 Profile 时，也可以登录。

普通凭据和未使用 `sso_session` 的旧式 SSO Profile 位于 `Other profiles`，仍需手动选择。旧式 SSO 使用终端命令 `aws sso login --profile <name>` 登录，再选择该 Profile 或点击 `Retry Connection`。网络、权限或配置错误显示为连接失败，不会一律标记为未登录。

等待期间可点击 `Cancel Login`；切换 session 或关闭视图也会取消本次等待，Profile 和 Region 在登录期间不可修改。登录最长等待 5 分钟，取消和超时会终止本次启动的 CLI 子进程，不关闭浏览器，也不执行登出或删除已有会话。取消不能撤销浏览器中已经完成的授权。

CLI 必须位于 `/opt/homebrew/bin/aws`、`/usr/local/bin/aws` 或 `/usr/bin/aws`。未安装时应用会给出提示；若浏览器未打开，可取消后在终端登录，再手动选择 Profile。登录和读取凭据使用相同配置路径；登录子进程不继承 `AWS_PROFILE`、`AWS_DEFAULT_PROFILE`，避免终端的预选账号干扰 session 登录。应用不显示、记录或保存登录命令的原始输出，登录缓存由 AWS CLI 管理。

以下为模拟登录成功、尚未选择 Profile 的组件状态：

![Session 登录后保持空白](docs/ui-sso-login.png)

## 项目结构

```
Sources/AWSPlatform/
├── App.swift                    # 应用入口
├── ContentView.swift            # 主视图
├── Models/                      # 数据模型
│   ├── AWSProfile.swift
│   ├── AWSSOSession.swift
│   ├── AWSService.swift
│   ├── ResourceFavorite.swift
│   ├── EC2Instance.swift
│   ├── LambdaFunction.swift
│   └── S3Bucket.swift
├── Services/                    # AWS 服务层
│   ├── AWSServiceProvider.swift
│   ├── AWSCLICredentialProvider.swift # 自定义配置路径的 SSO 凭据桥接
│   └── AWSSSOLoginService.swift  # CLI 登录进程及共享调用配置
├── Utilities/                   # 工具类
│   ├── ConfigReader.swift
│   └── UserFacingError.swift
├── ViewModels/                  # 视图模型
│   ├── EC2ViewModel.swift
│   ├── FavoriteNavigation.swift
│   ├── FavoritesViewModel.swift
│   ├── LambdaViewModel.swift
│   ├── ProfileViewModel.swift
│   └── S3ViewModel.swift
└── Views/                       # 界面视图
    ├── EC2/
    ├── Lambda/
    ├── S3/
    ├── FavoritesListView.swift
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

AWS CLI 的 `[sso-session ...]` 显示在独立的 `SSO Session` 选择器中，不会混入 Profile；`[services ...]` 等辅助配置节不会显示为可选 Profile。

Profile 列表合并 `config` 和 `credentials` 中的名称，同名时使用 `config` 的区域等配置；仅存在于 `credentials` 的 Profile 使用默认区域 `us-east-1`。应用支持进程环境变量 `AWS_CONFIG_FILE` 和 `AWS_SHARED_CREDENTIALS_FILE`，发现配置和建立 AWS 客户端使用相同的路径。由 Finder 启动的进程不会自动继承终端中临时设置的环境变量；需要自定义路径时，可从设置了这些变量的终端运行 `swift run`。

默认配置路径下的 SSO 使用 Soto 的凭据提供器。自定义 `AWS_CONFIG_FILE` 下的 SSO 使用本机 AWS CLI v2 的 `configure export-credentials`；CLI 需安装在 `/opt/homebrew/bin/aws` 或 `/usr/local/bin/aws`（也支持 `/usr/bin/aws`），并支持该命令。应用只在内存管道中解析凭据，不显示或保存命令输出。应用内登录自动传入相同的配置路径；若在终端登录，必须使用相同的配置路径和 session，完成后手动选择 Profile；已选 Profile 可点击 `Retry Connection`。

支持多个 Profile 共用一个具名 SSO session，例如：

```ini
[profile development]
sso_session = company
sso_account_id = 111122223333
sso_role_name = DeveloperAccess
region = eu-west-1

[profile production]
sso_session = company
sso_account_id = 444455556666
sso_role_name = ReadOnlyAccess
region = ap-southeast-1

[sso-session company]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

将示例替换为实际配置后，执行 `aws sso login --sso-session company` 即可登录共用的 `company` session；应用中选中 `company` 后，Profile 列表包含 `development` 和 `production`，仍需手动选择其一。在会话有效且具备对应账号／角色权限时，两个 Profile 可复用登录状态。每个 Profile 独立决定账号、角色和资源 Region；`sso_region` 是身份中心区域。标准格式中一个 Profile 引用一个 session，不同 session 需要分别登录；应用不会自动枚举或创建其他账号的 Profile。配置方式见 [AWS CLI SSO 官方文档](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) 。

Region 列表包含 SDK 已知的常用区域以及配置中的区域，也可以通过 Region 旁的编辑按钮输入其他区域代码。区域是否启用、所属分区和服务权限仍由 AWS 决定。

Lambda 列表通过 `GetFunction` 补充状态和标签，最多同时读取 4 个函数。部分函数权限不足或读取失败时，列表仍保留，显示提示；状态筛选不包含状态未知的函数。相关权限至少包括 `lambda:ListFunctions` 和用于补充信息的 `lambda:GetFunction`。

参考：[AWS CLI 凭据导出](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html) 、[AWS CLI 环境变量](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html) 、[Lambda 列表接口字段范围](https://docs.aws.amazon.com/lambda/latest/api/API_ListFunctions.html) 。

## 项目进度

当前阶段、验证记录和待办以 [`ROADMAP.md`](ROADMAP.md) 为准。

## License

MIT
