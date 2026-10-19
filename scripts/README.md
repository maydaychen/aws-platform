# 构建脚本

本目录只存放可复用的本地构建与打包脚本；应用代码仍放在 `Sources/`，临时文件放在 `.tmp/`，交付产物放在 `dist/`。

- `build-universal.sh`：本地 ad-hoc 通用包或单架构包构建。
- `generate-app-icon.sh`：用 macOS 原生 `sips`／`iconutil` 将 PNG 主图转换为多尺寸 ICNS。
- `package-distribution.py`：Developer ID 签名、Apple 公证与 ZIP／DMG 分发打包。
- `update_support.py`／`verify-update-signature.swift`：嵌入 Sparkle、逐层签名以及只用公钥验证最终 ZIP。
- `generate-update-feed.py`：验证公开附件后生成 ARM／Intel 更新清单，不执行上传或推送。
- `collect-licenses.py` 与 `licenses/`：按锁定依赖收集完整许可，固定补充许可的来源见 `licenses/README.md`。
- `tests/`：不调用签名或 Apple 接口的打包保护逻辑测试。

## Universal macOS 应用

在已安装并选择提供 Swift 6.2+ 的完整 Xcode 工具链的 Mac 上执行：

```bash
./scripts/build-universal.sh
```

脚本根据自身位置定位项目，也可以从其他目录通过脚本的完整路径运行。它分别构建 `arm64` 和 `x86_64` 的 Release 可执行文件，合并为支持 Apple Silicon 与 Intel 的 Universal 应用，最低系统版本为 macOS 13。

- 依赖版本由 `Package.resolved` 锁定；缺少该文件或需要重新解析版本时停止，不更新依赖。
- 优先使用 SwiftPM 的 `swiftbuild` 引擎，旧工具链使用 `xcode` 引擎；两者生成的资源访问器支持标准的 `Contents/Resources` 布局。
- 使用 `swift-stdlib-tool` 将所需 Swift 兼容运行库嵌入 `Contents/Frameworks`，验证库的两种架构与 macOS 13 兼容性，并移除可执行文件中的构建机绝对库搜索路径。
- 临时打包文件使用 `.tmp/universal-build/` 下的唯一目录，结束时只清理本次目录；SwiftPM 使用该目录内独立的新 scratch，不复用项目的 `.build/` 构建产物。
- 验证两个架构、最低系统版本、资源 bundle、`Info.plist` 和签名后，才替换现有交付产物。
- 输出 `dist/AWSPlatform.app` 和 `dist/AWSPlatform-universal.zip`。解压后可将应用复制到「应用程序」目录。
- Bundle ID 保持为 `AWSPlatform`，与既有 `swift run` 的偏好域一致，延续收藏和 Session 偏好。
- 将 `Assets/AppIcon/AppIcon.icns` 放入 `Contents/Resources` 并在 `Info.plist` 中声明图标；缺少图标时停止构建。修改 PNG 主图后先运行 `./scripts/generate-app-icon.sh`，生成说明见 [App Icon](../Assets/AppIcon/README.md) 。

产物使用本地 ad-hoc 签名，没有使用 Developer ID，也没有进行 Apple 公证。此脚本提供本地构建和架构兼容产物，不代表已通过其他 Mac 的 Gatekeeper 或 Intel 实机验收。

可用 `--output-dir DIRECTORY` 将本次构建输出到指定目录，正式打包使用这个入口隔离暂存产物。

两个脚本均接受 `--architecture universal|arm64|x86_64`、`--version VERSION` 和 `--build-number NUMBER`，默认值为 `universal`、`0.4.1` 和 `18`。版本使用三段数字，build 使用正整数。单架构模式仅构建指定架构，将内嵌 Swift 运行库裁为相同架构后重新签名；本地 ZIP 名称相应为 `AWSPlatform-arm64.zip` 或 `AWSPlatform-x86_64.zip`。保留多个本地架构包时使用不同 `--output-dir`，避免共用 `AWSPlatform.app` 输出位置。

## 正式签名与公证

需要 Python 3.9+、可用的 Developer ID Application 证书及匹配私钥、已配置认证的 `asc` CLI，并允许访问 Apple 签名时间戳和公证服务。先确认应用源码已经提交并通过验证；将 `SIGNING_IDENTITY` 设为目标证书的 SHA-1、`DEVELOPMENT_TEAM` 设为对应团队 ID 后执行：

```bash
security find-identity -v -p codesigning
asc notarization list --limit 1 --output table
python3 scripts/package-distribution.py \
  --identity "$SIGNING_IDENTITY" \
  --team-id "$DEVELOPMENT_TEAM" \
  --architecture arm64 --version 0.4.1 --build-number 18
```

Intel 版本使用同一命令并将 `--architecture arm64` 改为 `--architecture x86_64`。两个正式目录和 ZIP／DMG 文件名均标明架构；Universal 模式仍可单独使用。

执行命令会向 Apple 提交公证。签名身份和认证保留在本机，脚本不存储私钥或 Token，也不创建 GitHub Release。

脚本在 `.tmp/distribution/` 的独立目录构建指定架构应用、收集随包许可证，依次签名内嵌运行库和 App，使用 Hardened Runtime 和安全时间戳。App 公证为 `Accepted` 后附加并验证票据，再生成最终 ZIP；随后制作包含「应用程序」快捷入口的 DMG，对 DMG 签名、公证、附加票据。只有签名、票据和 Gatekeeper 检查全部通过，才移动到 `dist/AWSPlatform-<版本>-<架构>/`，其中包含：

- `AWSPlatform.app`、版本化且标明架构的 ZIP 和 DMG。
- `SHA256SUMS.txt`：ZIP 和 DMG 的 SHA-256。
- `distribution.json`：版本、源码提交、团队、公证 ID 和校验值。

版本和 build 传给 `build-universal.sh` 并核对生成的 `Info.plist`；再次核对主程序及内嵌运行库的实际架构。源码、打包脚本与许可输入必须已经提交，构建前后保持同一提交；本机无关文档改动不纳入包内。构建前拒绝已存在的同名正式产物目录；失败时保留暂存目录，旧产物不受影响。提交超时或返回未知结果时，先查询 Apple 公证历史与状态，避免重复提交；不能把签名成功或上传成功视为公证通过。

完成后仍需对 ZIP 独立解压、DMG 只读挂载及包内应用启动做验收；真实 AWS 登录和 Intel／macOS 13 实机运行单独验证。

离线检查入口：

```bash
bash -n scripts/build-universal.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
```

## 应用更新与发布清单

更新器锁定 Sparkle 2.10.0 及其上游 revision／归档 SHA-256。框架复制、重新签名和工具执行前，`update_support.py` 下载官方归档到权限为 `0700` 的私有目录，校验固定 SHA-256 后才解包；不用共享 `.build/artifacts` 中的框架或签名工具。校验后的原始组件／工具保持只读，只有 App 内副本在重新签名前恢复标准 `755`／`644` 权限，符号链接保持原样。正式构建使用独立 SwiftPM scratch 目录。升级 Sparkle 时必须同时审查版本、revision 与上游校验和。构建脚本将其 framework 和 Installer／Downloader XPC、Autoupdate、Updater.app 一并嵌入，保持官方组件的 Universal 架构；单架构包的主程序和 Swift 兼容库仍只有目标切片。所有组件核对目标架构和 macOS 13 兼容性，正式打包依次签内部组件、framework、主 App，Downloader 保留原有 entitlements，不使用 `codesign --deep` 施加签名。

仓库 `updates/public-ed25519-key.txt` 只有 Ed25519 公钥。配套私钥位于本机登录钥匙串的专用 account `aws-platform-updates`；脚本不导出私钥，签名前核对钥匙串公钥与仓库一致，缺少或不匹配即停止，不能重新生成密钥替代现有信任关系。所有公钥读取和签名工具均通过上述已校验归档执行。

正式打包在 App 公证／装订、最终 ZIP 生成后使用 `sign_update` 签该 ZIP，并以 CryptoKit 仅凭公钥再次验签。`distribution.json` 的 `sparkle` 包含对应公钥、架构清单地址、Ed25519 签名和字节数；最终 ZIP 不得再次压缩或修改。自动检查默认关闭，可在设置开启；自动下载／安装禁用，安装由用户确认，并通过实际 S3 任务租约和 AppKit 终止回调等待传输完成。

先完成两个架构的签名、公证与独立核验，再上传 Release 附件。确认附件可匿名下载后执行以下命令生成本地候选清单，版本与 build 应采用本次发布的实际值：

```bash
python3 scripts/generate-update-feed.py dist/AWSPlatform-0.4.1-arm64 \
  --output .tmp/update-feed/appcast-arm64.xml
python3 scripts/generate-update-feed.py dist/AWSPlatform-0.4.1-x86_64 \
  --output .tmp/update-feed/appcast-x86_64.xml
```

脚本只接受单架构、已公证的包，校验清单、最终 ZIP 哈希／字节数、公钥签名、解包 App 与全部更新组件的 Developer ID 签名、票据及 Gatekeeper，再下载 GitHub 上的实际附件比对。新 build 必须递增，语义版本不能倒退；候选 XML 再由同一专用密钥签名，通过独立公钥验签后才原子替换输出；任何失败都保留原清单。审查候选后，将它们放入 `updates/`，通过明确授权的提交／推送发布。脚本不创建 Release、不上传、不推送；清单始终后于附件发布。

应用按正在运行的编译切片选择 ARM／Intel HTTPS 清单，Intel App 在 Rosetta 下仍走 Intel 源；Universal App 按实际运行切片更新为对应架构包。应用启用 `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction`，并将 `SUSignedFeedFailureExpirationInterval` 设为 `0`，不允许签名失败后自动放宽检查。仓库 `updates/` 已包含 `0.4.0 (17)` 的两份 Ed25519 签名清单，并保留 `0.3.1 (9)` 历史记录；修改后必须重新签名，发布时保留完整签名字节。签名不证明清单新鲜度，也不能防止服务端停止提供更新；签名私钥丢失时，必须手动安装经审查的新公钥版本，不通过未签名清单恢复。公开 `v0.3.0` 及更早版本不含更新器，用户需先手动安装 `v0.3.1`，随后新版本才可在应用内升级。Sparkle 标准窗口遵循系统语言，应用自己的更新菜单和设置遵循应用语言偏好。

首次使用 `sign_update` 时，macOS 可能要求在系统弹窗授权其访问专用签名密钥；密码只在本机系统弹窗输入，不能交给 Agent、写入脚本或通过导出私钥绕过授权。自动化验收仅使用隔离偏好、模拟 S3 任务和本地包，不能为测试进行真实 S3 写入。

传输保护覆盖单个应用进程中的所有窗口。Sparkle 2.10.0 的安装 agent 只监测找到的第一个应用进程，因此更新前应先关闭其他独立启动的实例；直接执行多个 App 二进制、崩溃和强制退出不提供相同保护。SDK 正常退出使用 `NSRunningApplication.terminate()` 并等待实际退出，不能用“自动更新关闭”替代 AppKit 终止保护；用户手动下载后稍后退出安装也需保留该保护。
