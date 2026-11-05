# mac-kit

一个 macOS 菜单栏小工具：**用全局快捷键打开（或切换到）不同的 App**。

- 纯 Swift + AppKit / SwiftUI，编译产物约 200 KB
- 常驻菜单栏，平时不占 Dock（`LSUIElement`）；打开设置窗口时临时显示 Dock 图标
- 用 Carbon `RegisterEventHotKey` 注册全局热键，**不需要辅助功能（Accessibility）权限**
- 图标与设置窗口都按 macOS 26/27 的 Liquid Glass 风格重新设计
- 配置是一个 JSON 文件，改完点「重新加载配置」即生效

![设置窗口](docs/settings-window.png)

## 图标

图标按 macOS 图标网格绘制：1024 画布、内容区 824、超椭圆（n=5）连续圆角，4 倍超采样后降采样。玻璃层次为：投影 → 底色渐变 → 色晕 → 斜向反光 → 边缘亮环 → 底部厚度 → ⌘ 字形。

| 亮色 | 暗色 |
|---|---|
| ![亮色图标](docs/icon-light.png) | ![暗色图标](docs/icon-dark.png) |

**自动切换**：启动时和系统外观变化时（KVO `NSApp.effectiveAppearance` + `AppleInterfaceThemeChangedNotification`）切换 `NSApp.applicationIconImage`。设置窗口顶部的图标也会跟着变。

> 限制：`.icns` 格式本身不支持「同一图标多外观」，macOS 26 的图标外观变体（亮/暗/着色）要走 Icon Composer 的 `.icon` + `Assets.car`，而打包 `Assets.car` 需要 Xcode 的 `actool`（本机只装了 Command Line Tools，`actool` 不可用）。所以：
> - 运行中的 App（Dock、⌘-Tab、关于面板、设置窗口）里图标会跟随亮暗切换；
> - Finder / 访达 / Launchpad 里显示的静态图标固定用亮色版。
>
> 等装了 Xcode，用 Icon Composer 打开 `docs/icon-light.png` / `docs/icon-dark.png` 做成 `.icon` 就能做到 Finder 里也自动切换。

## 设置窗口

菜单栏图标 →「偏好设置…」（⌘,）。

- 顶部：图标 + 名称 + 说明
- 快捷键列表：每条显示按键、目标 App、解析到的真实路径和注册状态（✓ / ⚠）
- 开关：登录时自动启动（`SMAppService`）、显示菜单栏图标、显示 Dock 图标
- 按钮：编辑配置 / 重新加载 / 退出

### 隐藏菜单栏图标 / 隐藏 Dock 图标

两个开关存在 `UserDefaults`（域 `com.kaix.mac-kit`），改完立即生效并持久化：

- **显示菜单栏图标**（默认开）：关掉后 `NSStatusItem.isVisible = false`，菜单栏图标消失
- **显示 Dock 图标**（默认关）：开 = `NSApp.setActivationPolicy(.regular)`（Dock + ⌘-Tab 可见），关 = `.accessory`（只在菜单栏）

**安全兜底**：两个都关掉时 App 会完全不可见，所以在设置窗口里会显示橙色提示，并且始终注册了一个固定热键 **⌥⌘,** 用来打开设置窗口——不依赖任何配置文件，也不会被隐藏开关影响。

窗口背景在 macOS 26+ 用 `NSGlassEffectView`（27 上额外开启 `effectIsInteractive`），更老的系统回退到 `NSVisualEffectView` 的 `.hudWindow` 毛玻璃。

## 默认快捷键

装好后自动生成配置，只包含系统里真实存在的 App：

| 快捷键 | 打开 |
|---|---|
| ⌥⌘S | Safari |
| ⌥⌘F | Finder |
| ⌥⌘X | 微信 |

三个应用都用到时才写入配置（找不到的 App 会被跳过）；想加更多 App，直接往 `config.json` 的 `hotkeys` 数组里加一条，再点「重新加载」。

> 组合被系统或别的 App 占用（比如和 Loop 的触发键撞了）时注册会失败，设置窗口里显示 ⚠，日志里写明原因。

## 配置文件

路径：`~/Library/Application Support/mac-kit/config.json`

```json
{
  "hotkeys": [
    { "key": "1", "modifiers": ["option", "command"], "target": "Finder" },
    { "key": "k", "modifiers": ["option", "command"], "target": "kitty" },
    { "key": "s", "modifiers": ["control", "option"], "target": "com.apple.Safari" },
    { "key": "v", "modifiers": ["option"], "target": "/Applications/Visual Studio Code.app" }
  ]
}
```

**字段**

- `key`：键名，见下
- `modifiers`：`command`(⌘) / `option`(⌥) / `control`(⌃) / `shift`(⇧)，也接受 `cmd` `alt` `opt` `ctrl` 和 `⌘⌥⌃⇧`
- `target`：应用名（`kitty`）、Bundle ID（`com.apple.Safari`）或完整路径

**支持的键名**：`a`–`z`、`0`–`9`、`f1`–`f12`、`space`、`tab`、`return`、`escape`、`delete`、`home`、`end`、`pageup`、`pagedown`、方向键、`minus`、`equal`、`leftbracket`、`rightbracket`、`semicolon`、`quote`、`comma`、`period`、`slash`、`backslash`、`grave`

## 命令行

```bash
APP=/Applications/mac-kit.app/Contents/MacOS/mac-kit

$APP --check                 # 检查每个快捷键能否注册、目标能否解析、当前图标选型
$APP --open Finder           # 单独测试某个 target 能否被打开
$APP --settings              # 启动并直接打开设置窗口
$APP --check                 # 会报告图标选型
$APP --snapshot out.png      # 离屏渲染设置界面（用于检查排版）
```

`--check` 输出示例：

```
✓ ⌥⌘3 → kitty  (/Applications/kitty.app)
当前外观: dark，图标: 已加载（AppIcon-Dark.icns）
6/6 个快捷键可用
```

## 日志

`~/Library/Logs/mac-kit.log`：启动、快捷键注册、打开结果、图标加载。

## 构建

```bash
cd mac-kit
./build.sh              # 构建并安装到 /Applications
./build.sh none         # 只构建
```

重新构建前先退出旧实例：

```bash
pkill -f 'MacOS/mac-kit'
```

## 重新生成图标

```bash
# 需要带 Pillow 的 python3
python3 tools/make_icon.py

# 生成 iconset → icns（build.sh 只复制 Resources/ 里的 icns，不会自动跑这两步）
for v in Light Dark; do
  # 见 README 历史或 docs/；手工按 16/32/64/128/256/512/1024 生成 iconset 后：
  iconutil -c icns build/$v.iconset -o Resources/AppIcon-$v.icns
done
```

## 卸载

```bash
pkill -f 'MacOS/mac-kit'
rm -rf /Applications/mac-kit.app
rm -rf ~/Library/Application\ Support/mac-kit
rm -f ~/Library/Logs/mac-kit.log
```

开过「登录时自动启动」的话，先在设置窗口里关掉再删。

## 实现要点

- `AppDelegate` 安装 `NSStatusItem` 和 Carbon 事件处理器；热键回调通过 `GetEventParameter(typeEventHotKeyID)` 拿到 id 查表
- `RegisterEventHotKey` 返回的 `EventHotKeyRef` 都存着，重载配置时先 `UnregisterEventHotKey`
- 打开用 `NSWorkspace.openApplication(at:configuration:)`，已运行则激活
- 设置窗口是 `NSHostingView(SwiftUI)` 套在 `NSGlassEffectView` 里，窗口 `titlebarAppearsTransparent` + `fullSizeContentView`
- 菜单栏图标与 Dock 图标分别由 `NSStatusItem.isVisible` 和 `NSApp.setActivationPolicy(_:)` 控制，状态存 `UserDefaults`
- 保留热键 `⌥⌘,`（Carbon 注册，id `0xF000`）用于兜底打开设置窗口
