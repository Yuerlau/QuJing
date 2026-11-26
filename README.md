# 取景 · QuJing

点击 Dock 里的「取景」，拖动框选屏幕的一部分，或双击鼠标下高亮的窗口截取整窗。适用于 macOS 15.2 及以上版本，支持 Apple 芯片和 Intel Mac。

## 安装

从 [GitHub Releases](https://github.com/Yuerlau/QuJing/releases) 下载应用压缩包。解压后把「取景.app」移到「应用程序」文件夹，打开一次，再从 Dock 图标的「选项」中选择「在程序坞中保留」。

首次使用时，在「系统设置 → 隐私与安全性 → 录屏与系统录音」中允许「取景」截取屏幕。发布包使用本机临时签名，尚未经过 Apple 公证。如果 macOS 提示无法验证开发者，也可以按下方步骤自行构建。

## 截图和编辑

- **截取窗口**　将鼠标移到目标窗口，确认高亮边框后双击，PNG 会保存到桌面。
- **截取选区**　按住鼠标拖出选区，松开后使用预览下方的工具栏。

| 工具 | 操作 |
| --- | --- |
| 提取文字 | 识别截图中的文字，可以选择或复制结果。 |
| 翻译 | 将识别出的原文译为简体中文。首次使用某种语言时，系统可能提示下载语言包。 |
| 保存图片 | 把当前预览保存为桌面上的 PNG。也可以按 ⌘S。 |
| 马赛克 | 在要遮挡的位置拖动涂抹，按 ⌘Z 撤销上一次涂抹。 |
| 分享 | 打开 macOS 系统分享面板，分享带有当前马赛克的图片。 |

按 Esc 或在选区外点右键可以取消本次截图。分享面板打开时，第一次按 Esc 收起面板，再按一次取消截图。

## 从源码构建

在 Mac 上安装含 Swift 6.2 或更新版本编译器与 macOS 15.2 或更新版本 SDK 的 Xcode 或 Command Line Tools。在仓库根目录运行：

```sh
./build.sh
open "build/取景.app"
```

脚本生成同时包含 arm64 和 x86_64 的应用。主要代码在 `Sources/`，使用 AppKit、ScreenCaptureKit、Vision 和 Translation。构建直接使用 `Resources/` 里的图标；需要修改图标时，可用 Python 和 Pillow 运行 `scripts/make_icon.py` 生成 iconset，再用 `iconutil` 转换。

## 许可证

[MIT](LICENSE)
