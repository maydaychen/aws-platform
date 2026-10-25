# 发布隐私

当前开发仓库从脱敏后的初始提交继续开发，已接管原 `aws-platform` 项目路径。原仓库及其旧 Git 历史、缓存和旧安装包已按授权删除；当前源码、资源、测试、依赖锁文件和许可证完整保留。最新脱敏验证包保留在忽略目录中，本机私有扫描配置位于项目外，两者均不纳入提交。

日常开发直接使用当前仓库，无需在两份项目之间同步。面向公开发布的源码与安装包仍分别验证；修改提交身份不会清理既有提交，导出器也不会复制当前 `.git`。

## 提交身份

仅在项目仓库配置 `git config --local user.name` 和 `git config --local user.email`，使用昵称及 GitHub 提供的 `noreply` 地址；不改变其他项目的身份。GitHub 账号的邮箱隐私与阻止邮箱暴露开关仍是账号级设置，与本地 Git 配置分开管理。设置页提供的准确地址与归属规则见 [GitHub 邮箱文档](https://docs.github.com/en/account-and-profile/reference/email-addresses-reference) 。

GitHub 公开昵称可保留在提交身份、项目自有版权署名和更新链接中。隐私清理针对私人姓名、公司邮箱、私有地址及本机绝对路径，不将公开昵称判作泄漏；`noreply` 不隐藏 GitHub 用户名。

## 源码副本

先提交并验证当前源码，然后导出到不存在的目录：

```bash
python3 scripts/export-public-source.py --output-dir dist/public-source
```

导出器固定当前 HEAD，拒绝脏工作区、危险路径、符号链接和私密／生成目录；逐文件校验归档字节与 Git blob、保留执行位及许可证，并在导出前后核对源提交。仅在隐私扫描通过后发布新目录，既有目标不覆盖。旁边的私有 manifest 记录源提交与文件数量，不包含原始提交对象。

输出没有 `.git`、分支／标签、未跟踪文件、审计日志或本机配置。若需要另建发布用仓库，在导出的副本中单独 `git init`，明确配置昵称与 `noreply` 后建立初始提交；日常开发仓库无需重新初始化。导出脚本不自动创建远端、推送或发布 Release。

## 构建路径

`scripts/build-universal.sh` 将实际项目根目录及其 canonical 路径映射为 `/build/aws-platform`。Swift 使用 file/debug prefix map，Clang C/C++ 使用 file/debug prefix map，覆盖依赖中的文件宏字符串；链接后的主程序再用 `strip -S` 移除仍含绝对对象／AST 路径的 STABS 调试记录，保留运行时代码、常量与符号。仅移除调试符号不足以清除普通字符串里的路径，因此两步均保留。每次打包使用新的 SwiftPM scratch，第三方依赖也重新编译，原工作区路径不应进入 App 主程序。

## 隐私扫描

```bash
python3 scripts/privacy_scan.py path/to/staged-source-or-app
```

默认检查私有 home 路径和非示例邮箱，扫描普通文件中的 UTF-8、UTF-16 及二进制字符串，拒绝不可读文件、特殊文件、逃逸符号链接及扫描中变化的文件。保留示例域名、GitHub `noreply` 地址和明确许可证文件中的第三方邮箱署名。二进制中的 BoringSSL 邮箱仅按已核验的完整版权标记保留，不放开整个域名；额外禁止词与 home 路径仍检查这些内容。报告只输出相对文件与规则，不回显命中内容。

姓名、企业域名、自托管地址等非结构化信息使用本机额外禁止词，不将真实值写进项目源码或测试：

```bash
export AWSPLATFORM_PRIVACY_PATTERNS_FILE="$HOME/Library/Application Support/AWSPlatform/ReleasePrivacy/private-patterns.json"
python3 scripts/privacy_scan.py path/to/staged-source-or-app
python3 scripts/export-public-source.py --output-dir dist/public-source
```

配置是项目外的 JSON 字符串数组，所在目录权限为 0700、文件为 0600；不在仓库、临时审计材料或安装包中保存副本。可通过 `--patterns-file` 显式传入，命令行优先于环境变量。未配置时仍执行通用检查；已配置但文件不可读、格式错误或过大时停止。CI／其他机器需单独提供同样的私有配置，自动扫描不等于能够识别所有姓名、公司内容或截图文字。

构建与审计日志只保存相对路径或 `~`，不记录私有匹配词；核验完成后清理本次生成的私人路径缓存和临时旧安装副本。对外分享使用通过门禁的源码导出或 App／ZIP，不直接压缩整个开发目录。

本地打包在 ad-hoc 签名前检查 App，并解压新 ZIP 再扫描。正式打包在 Developer ID 签名及公证前检查包含许可证的 App，签名后复扫，并检查最终 ZIP 的展开内容和 DMG 中只读挂载的 App；失败保留旧产物，不继续发布目标目录。

## 保留的身份与范围

Developer ID 证书中的个人或组织身份和第三方许可证署名属于公开归属，不通过删除签名或修改版权声明隐藏。普通路径／邮箱扫描不能承诺完全匿名。个人证书身份调整需按 [Apple 规则](https://developer.apple.com/help/account/membership/updating-your-account-information/) 办理。

本次本地迁移删除了原项目目录，但不会改变已安装的应用或其他人的克隆、下载。隐私流程不覆盖 GitHub 个人页、搜索缓存及外部托管。重新发布、签名／公证上传和本机安装各自单独执行。
