# 构建脚本

本目录只存放可复用的本地构建与打包脚本；应用代码仍放在 `Sources/`，临时文件放在 `.tmp/`，交付产物放在 `dist/`。

- `build-universal.sh`：本地 ad-hoc 通用包或单架构包构建。
- `build-anonymous-release.sh`：匿名 Universal（`arm64` + `x86_64`）Release DMG／ZIP 打包与结构化匿名校验。
- `anonymous_release_check.py`：逐架构切片检验应用包不含证书 `Authority`、非空 `TeamIdentifier`、Sparkle 或描述文件，核对 `Licenses/manifest.json` 校验和与 `PROVENANCE.json` 嵌入运行库记录，校验 DMG 未签名且通过双架构与隐私扫描门禁。
- `generate-app-icon.sh`：用 macOS 原生 `sips`／`iconutil` 将 PNG 主图转换为多尺寸 ICNS。
- `collect-licenses.py` 与 `licenses/`：按锁定依赖收集完整许可，固定补充许可的来源见 `licenses/README.md`。
- `privacy_scan.py` 与 `export-public-source.py`：工作区构建路径与敏感词扫描，以及无历史干净源码副本导出。
- `tests/`：离线构建参数、许可收集、隐私扫描、公开源码导出与匿名发布校验单元测试。

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
- 验证两个架构、最低系统版本、资源 bundle、`Info.plist` 和本地 ad-hoc 签名后，才替换现有交付产物。
- 输出 `dist/AWSPlatform.app` 和 `dist/AWSPlatform-universal.zip`。解压后可将应用复制到「应用程序」目录。
- Bundle ID 保持为 `AWSPlatform`，与既有 `swift run` 的偏好域一致，延续收藏和 Session 偏好。
- 将 `Assets/AppIcon/AppIcon.icns` 放入 `Contents/Resources` 并在 `Info.plist` 中声明图标；缺少图标时停止构建。修改 PNG 主图后先运行 `./scripts/generate-app-icon.sh`，生成说明见 [App Icon](../Assets/AppIcon/README.md)。

产物使用本地 ad-hoc 签名，没有使用 Developer ID，也没有进行 Apple 公证。此脚本提供本地构建和架构兼容产物，不代表已通过其他 Mac 的 Gatekeeper 或 Intel 实机验收。

可用 `--output-dir DIRECTORY` 将本次构建输出到指定目录，匿名发布脚本使用这个入口隔离暂存产物。

两个构建脚本均接受 `--version VERSION` 和 `--build-number NUMBER`，默认值为 `0.4.3` 和 `28`（`build-universal.sh` 还支持 `--architecture universal|arm64|x86_64`，默认为 `universal`）。版本使用三段数字，build 使用正整数。

## 匿名公开 Release 打包

公开分发不再使用个人 Developer ID 证书或 Sparkle 应用内更新器，改为发布纯本地 ad-hoc 签名的通用安装包。先准备依赖 checkout 供许可收集器读取，再执行打包：

```bash
swift package --force-resolved-versions resolve
export AWSPLATFORM_PRIVACY_PATTERNS_FILE="$HOME/Library/Application Support/AWSPlatform/ReleasePrivacy/private-patterns.json"
./scripts/build-anonymous-release.sh --version 0.4.3 --build-number 28
```

脚本会在 `.tmp/anonymous-release/` 临时目录内构建 Universal `AWSPlatform.app`、嵌入 Swift 兼容运行库并随包附带 26 个已锁定依赖与运行库许可、执行构建路径重映射与 `strip -S`，并在生成与解压 `.zip`、创建并只读挂载 `.dmg` 后分别运行 `anonymous_release_check.py` 与 `privacy_scan.py`。为防止误删或覆盖已有产物，若 `--output-dir` 指向已存在的路径会直接拒绝构建。

全部解包／挂载载荷、归档头与发布说明文件校验通过后，整体原子移入新建的 `.tmp/release/v<版本>/`（不覆盖已有目录）：

- `AWSPlatform-<版本>-universal.dmg` 与 `AWSPlatform-<版本>-universal.zip`（盘内及包内 App 均满足 `Signature=adhoc`、`TeamIdentifier=not set`、无 `Authority=`、无描述文件及 `._*` 元数据，外层 DMG 容器未签名）。
- `SHA256SUMS.txt`：DMG 与 ZIP 的 SHA-256 校验文件。
- `RELEASE_NOTES.md`：包含首次打开 Gatekeeper 放行指南的双语发布说明。

离线检查入口：

```bash
bash -n scripts/build-universal.sh scripts/build-anonymous-release.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
```
