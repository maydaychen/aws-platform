# 构建脚本

本目录只存放可复用的本地构建与打包脚本；应用代码仍放在 `Sources/`，临时文件放在 `.tmp/`，交付产物放在 `dist/`。

- `build-universal.sh`：本地 ad-hoc 通用包或单架构包构建。
- `package-distribution.py`：Developer ID 签名、Apple 公证与 ZIP／DMG 分发打包。
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
- 临时打包文件使用 `.tmp/universal-build/` 下的唯一目录，结束时只清理本次目录；SwiftPM 复用项目的 `.build/` 缓存。
- 验证两个架构、最低系统版本、资源 bundle、`Info.plist` 和签名后，才替换现有交付产物。
- 输出 `dist/AWSPlatform.app` 和 `dist/AWSPlatform-universal.zip`。解压后可将应用复制到「应用程序」目录。
- Bundle ID 保持为 `AWSPlatform`，与既有 `swift run` 的偏好域一致，延续收藏和 Session 偏好。

产物使用本地 ad-hoc 签名，没有使用 Developer ID，也没有进行 Apple 公证。此脚本提供本地构建和架构兼容产物，不代表已通过其他 Mac 的 Gatekeeper 或 Intel 实机验收。

可用 `--output-dir DIRECTORY` 将本次构建输出到指定目录，正式打包使用这个入口隔离暂存产物。

两个脚本均接受 `--architecture universal|arm64|x86_64`、`--version VERSION` 和 `--build-number NUMBER`，默认值为 `universal`、`0.2.0` 和 `2`。版本使用三段数字，build 使用正整数。单架构模式仅构建指定架构，将内嵌 Swift 运行库裁为相同架构后重新签名；本地 ZIP 名称相应为 `AWSPlatform-arm64.zip` 或 `AWSPlatform-x86_64.zip`。保留多个本地架构包时使用不同 `--output-dir`，避免共用 `AWSPlatform.app` 输出位置。

## 正式签名与公证

需要 Python 3.9+、可用的 Developer ID Application 证书及匹配私钥、已配置认证的 `asc` CLI，并允许访问 Apple 签名时间戳和公证服务。先确认应用源码已经提交并通过验证；将 `SIGNING_IDENTITY` 设为目标证书的 SHA-1、`DEVELOPMENT_TEAM` 设为对应团队 ID 后执行：

```bash
security find-identity -v -p codesigning
asc notarization list --limit 1 --output table
python3 scripts/package-distribution.py \
  --identity "$SIGNING_IDENTITY" \
  --team-id "$DEVELOPMENT_TEAM" \
  --architecture arm64 --version 0.2.0 --build-number 2
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
