# 构建脚本

本目录只存放可复用的本地构建与打包脚本；应用代码仍放在 `Sources/`，临时文件放在 `.tmp/`，交付产物放在 `dist/`。

## Universal macOS 应用

在已安装并选择 Xcode 工具链的 Mac 上执行：

```bash
./scripts/build-universal.sh
```

脚本根据自身位置定位项目，也可以从其他目录通过脚本的完整路径运行。它分别构建 `arm64` 和 `x86_64` 的 Release 可执行文件，合并为支持 Apple Silicon 与 Intel 的 Universal 应用，最低系统版本为 macOS 13。

- 依赖版本由 `Package.resolved` 锁定；缺少该文件或需要重新解析版本时停止，不更新依赖。
- 优先使用 SwiftPM 的 `swiftbuild` 引擎，旧工具链使用 `xcode` 引擎；两者生成的资源访问器支持标准的 `Contents/Resources` 布局。
- 使用 `swift-stdlib-tool` 将所需 Swift 兼容运行库嵌入 `Contents/Frameworks`，验证库的两种架构与 macOS 13 兼容性，并移除可执行文件中的构建机绝对库搜索路径。
- 临时打包文件使用 `.tmp/universal-build/` 下的唯一目录，结束时只清理本次目录；SwiftPM 复用项目的 `.build/` 缓存。
- 验证两个架构、最低系统版本、资源 bundle、`Info.plist` 和签名后，才替换现有交付产物。
- 输出 `dist/AWSPlatform.app` 和 `dist/AWSPlatform-universal.zip`。解压后可将应用复制到「应用程序」目录。
- Bundle ID 保持为 `AWSPlatform`，与既有 `swift run` 的偏好域一致，延续收藏和 Session 偏好。

产物使用本地 ad-hoc 签名，没有使用 Developer ID，也没有进行 Apple 公证。此脚本提供本地构建和架构兼容产物，不代表已通过其他 Mac 的 Gatekeeper 或 Intel 实机验收。
