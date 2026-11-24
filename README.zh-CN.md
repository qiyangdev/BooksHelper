# BooksHelper

[English](README.md)

BooksHelper 是一款 macOS 菜单栏应用。它在 Apple Books 阅读窗口旁显示译文或简短总结，跟随你翻页，并使用你选择的目标语言。

## 使用要求

- macOS 27.2 或更高版本。
- 辅助功能权限，用于读取 Apple Books 当前页的文本和排版位置。
- 总结和 Ollama 翻译需要运行中的 Ollama 服务和已安装的文本模型。BooksHelper 通过 `127.0.0.1:11434` 连接本机 Ollama。

## 安装

签名并公证的构建计划通过 GitHub Releases 发布。目前可以用 Xcode 打开 `BooksHelper.xcodeproj`，选择 `BooksHelper` scheme，在本机运行。

## 使用方法

1. 从 BooksHelper 的菜单栏图标选择「Enable Books Text Access…」，在系统设置的「隐私与安全性 → 辅助功能」中启用 BooksHelper。
2. 在 Apple Books 里打开一本书。侧栏会出现在阅读窗口旁，并随翻页更新。
3. 在菜单栏的「Translation → Translate To」选择目标语言。用侧栏顶部的「Translate」或「Summary」切换视图。

BooksHelper 默认使用 macOS 系统翻译。若要用本机模型翻译，在「Translation → Engine」选择「Ollama」，再到「Translation → Model」选择模型。总结使用本机 Ollama，沿用相同的目标语言设置。

使用 Ollama 时，译文和总结会边生成边显示。翻译过程中，尚未被译文覆盖的原文会留在原位。已完成的结果保存在内存缓存中，回翻时可以直接显示。

## 代码结构

- `BooksHelper/Reading` 读取当前页，并确定各段落的位置。
- `BooksHelper/Sidebar` 管理侧栏、文本排版和动画。
- `BooksHelper/Translation` 处理系统翻译、Ollama 请求和结果缓存。
- `BooksHelperTests` 和 `BooksHelperUITests` 分别存放单元测试和界面测试。
- `Scripts/test-system-menu-bar.swift` 验证 macOS 菜单栏中的语言切换。

## 运行测试

可以在 Xcode 中使用 `BooksHelper` scheme，或在仓库根目录运行以下命令。

```sh
xcodebuild -project BooksHelper.xcodeproj -scheme BooksHelper \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/books-helper-validation CODE_SIGN_IDENTITY=- \
  -parallel-testing-enabled NO test
```

界面测试使用示例阅读页和模拟译文。要测试真实的 macOS 菜单栏，先退出正在运行的 BooksHelper，再从具有辅助功能权限的终端运行以下命令。

```sh
swift Scripts/test-system-menu-bar.swift \
  /tmp/books-helper-validation/Build/Products/Debug/BooksHelper.app
```
