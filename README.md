# BooksHelper

BooksHelper 是 macOS 菜单栏应用。它通过辅助功能读取 Apple Books 当前阅读页，并在阅读窗口右侧显示译文或总结。首次使用时，从菜单栏选择「Enable Books Text Access…」开启辅助功能权限。

在菜单栏的「Translation → Translate To」选择目标语言。默认使用系统翻译。在「Translation → Engine」选择「Ollama」后，可以从同级的「Model」菜单选择已安装的本地模型。BooksHelper 通过 `127.0.0.1:11434` 连接 Ollama，并记住用户选择的模型。

侧栏顶部的「Translate」和「Summary」用于切换当前页的译文和总结。总结使用本机 Ollama，沿用目标语言。Ollama 生成的译文和总结会逐步显示，已完成的结果会保存在内存缓存中。

## 代码结构

- `BooksHelper/Reading` 读取 Books 的辅助功能树，确定段落在单页或双页中的位置。
- `BooksHelper/Sidebar` 跟随阅读窗口，管理侧栏控件、段落排版和替换动画。
- `BooksHelper/Translation` 管理系统翻译、本地 Ollama 请求和结果缓存。
- `BooksHelperTests` 和 `BooksHelperUITests` 分别存放单元测试和界面回归测试。
- `Scripts/test-system-menu-bar.swift` 从 macOS 系统菜单栏验证目标语言切换。

## 构建与测试

项目的 macOS 部署目标为 27.2。用 Xcode 打开 `BooksHelper.xcodeproj`，选择 `BooksHelper` scheme，也可以运行下列命令。

```sh
xcodebuild -project BooksHelper.xcodeproj -scheme BooksHelper \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/books-helper-validation CODE_SIGN_IDENTITY=- \
  -parallel-testing-enabled NO test
```

界面测试使用固定阅读页和模拟译文。测试真实系统菜单栏时，先退出正在运行的 BooksHelper，再从具有辅助功能权限的终端运行下列命令。

```sh
swift Scripts/test-system-menu-bar.swift \
  /tmp/books-helper-validation/Build/Products/Debug/BooksHelper.app
```
