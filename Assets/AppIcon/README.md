# App Icon

本目录是 App 图标的资产源，供原生 macOS 打包脚本消费，不属于 SwiftPM 的独立资源 bundle。

- `AppIcon.png`：1,024 × 1,024 主图，圆角底座之外保留透明通道。
- `AppIcon.icns`：由主图生成的 16–1,024 像素多尺寸图标，打包到 App 的 `Contents/Resources/`。
- 本文件：设计意图、图像生成提示词及可复用的格式转换入口。

图标以橙色云和浅色资源节点突出云端资源工作台，使用深蓝底座与适度立体层次；视觉规范见根目录 `DESIGN.md`。

在项目根目录重新生成 ICNS：

```bash
./scripts/generate-app-icon.sh
```

脚本只使用 macOS 自带的 `sips` 和 `iconutil`，从已保存的主图生成 10 个标准 `.iconset` 尺寸；临时文件放在 `.tmp/app-icon-generation/`，成功后替换 `AppIcon.icns`。图像设计使用内置 Imagegen 文生图模式生成，再用 `sips` 归一为 1,024 像素主图；提示词可以重新生成风格相近的图像，但不保证像素完全一致。

## Imagegen Prompt

Use case: logo-brand. Asset type: production macOS application icon for AWSPlatform, a desktop AWS resource browsing and management workbench. Create one polished square 1024 x 1024 icon asset, not a presentation or mockup. A large, immediately recognizable warm orange cloud is the dominant silhouette; integrate three bold pale ivory connected resource blocks as a compact cluster within the lower center of that cloud, representing organized cloud services. Place this coherent mark on a deep midnight navy rounded-square ceramic tile with gentle edge bevel, restrained dimensional lighting and a subtle dark gradient. Strong visual hierarchy, rich contrast, precise smooth geometry, generous spacing, professional native macOS icon feel. The main cloud and blocks should remain clearly legible at 32 x 32. The rounded-square tile fills approximately 84 percent of the canvas, centered with even transparent outer margins; no background beyond the tile and a very restrained soft shadow. No text, no letters, no AWS wordmark, no Amazon smile, no screenshots, no decorative particles, no tiny dashboard widgets, no extra symbols, no watermark. Preserve real transparency outside the tile.
