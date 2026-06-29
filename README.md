# Browser Time Tracker

一个本地优先的 macOS 浏览器使用时间统计工具。它会在菜单栏常驻，统计你在不同网站和网页上花了多少时间，并提供本地 Dashboard 查看最近一周的使用情况。

> 默认所有数据只保存在你的 Mac 本地，不上传云端。

## 功能

- 支持浏览器：
  - Google Chrome
  - Safari
  - Microsoft Edge
  - Firefox
- 统计维度：
  - 最近 7 天每日使用时间
  - 单日 24 小时使用时间
  - Top Websites
  - Top Pages
  - 按网站颜色区分的堆叠柱状图
- 菜单栏常驻：
  - 沙漏图标
  - 打开 Dashboard
  - 暂停/恢复统计
  - 清空数据
  - 退出
- 自动暂停：
  - 电脑睡眠
  - 屏幕锁定
  - 当前前台 App 不是受支持浏览器
- Admin Lock：
  - 暂停、清空数据、退出需要管理员鉴权
- 数据保留：
  - 只保留最近 7 天
  - 启动时清理一次，运行中每 6 小时清理一次

## 下载安装

1. 从 GitHub Releases 下载最新的：

   ```text
   BrowserTimeTracker.dmg
   ```

2. 双击打开 DMG。

3. 将 `Browser Time Tracker.app` 拖到 `Applications`。

4. 从 `Applications` 打开 `Browser Time Tracker`。

5. 菜单栏出现沙漏图标后，表示应用正在运行。

## 首次权限设置

这个应用需要读取当前前台浏览器的网页 URL 和标题，因此 macOS 会弹出权限确认。

### Automation 权限

用于读取 Chrome、Safari、Edge 的当前标签页。

如果系统没有自动弹窗，或者你之前拒绝过，可以手动打开：

```text
System Settings -> Privacy & Security -> Automation
```

允许 `Browser Time Tracker` 控制你要统计的浏览器。

### Accessibility 权限

Firefox 的 URL 读取依赖 macOS Accessibility。

请打开：

```text
System Settings -> Privacy & Security -> Accessibility
```

允许 `Browser Time Tracker`。

## 使用方式

点击菜单栏的沙漏图标：

- `Open Dashboard`：打开统计页面
- `Pause Tracking`：暂停统计
- `Clear Data`：清空本地统计数据
- `Quit`：退出应用

Dashboard 地址是本地页面：

```text
http://127.0.0.1:38888/dashboard
```

Dashboard 支持：

- 选择日期
- 选择全天或某个小时
- 点击天柱状图切换当天统计
- 点击小时柱状图切换小时统计
- 查看 Top Websites 和 Top Pages

## 登录后自动启动

当前版本的 DMG 安装后需要手动打开应用。打开后应用会常驻菜单栏。

如果你是从源码运行，也可以用 LaunchAgent 脚本安装登录自启：

```bash
./scripts/install-launch-agent.sh
```

卸载登录自启：

```bash
./scripts/uninstall-launch-agent.sh
```

## 数据保存在哪里

数据保存在本地 SQLite 文件：

```text
~/Library/Application Support/BrowserTimeTracker/browser_time.sqlite
```

应用不会上传浏览记录。你也可以在菜单中使用 `Clear Data` 清空数据。

## 卸载

1. 退出菜单栏里的 `Browser Time Tracker`。
2. 删除：

   ```text
   /Applications/Browser Time Tracker.app
   ```

3. 如需删除本地数据：

   ```bash
   rm -rf "$HOME/Library/Application Support/BrowserTimeTracker"
   ```

4. 如果你使用过 LaunchAgent 脚本：

   ```bash
   ./scripts/uninstall-launch-agent.sh
   ```

## 从源码构建

要求：

- macOS 13+
- Xcode Command Line Tools
- Swift 5.9+

运行开发版本：

```bash
cd mac-menubar
swift run BrowserTimeMenubar
```

自检：

```bash
cd mac-menubar
swift run BrowserTimeMenubar --self-test
```

打包 DMG：

```bash
NOTARY_PROFILE="btt-notary" ./scripts/package-dmg.sh
```

脚本会自动尝试读取本机 `Developer ID Application` 证书。如果有多个证书，可以手动指定：

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="btt-notary" \
./scripts/package-dmg.sh
```

## English

# Browser Time Tracker

A local-first macOS browser time tracker. It runs in the menu bar, records how much time you spend on websites and pages, and provides a local dashboard for the last 7 days.

> All tracking data is stored locally on your Mac by default. Nothing is uploaded to a server.

## Features

- Supported browsers:
  - Google Chrome
  - Safari
  - Microsoft Edge
  - Firefox
- Insights:
  - Daily usage for the last 7 days
  - Hourly usage for each day
  - Top Websites
  - Top Pages
  - Stacked bar charts colored by website
- Menu bar app:
  - Hourglass icon
  - Open Dashboard
  - Pause or resume tracking
  - Clear local data
  - Quit
- Automatic pause:
  - Mac sleep
  - Screen lock
  - Active app is not a supported browser
- Admin Lock:
  - Pause, Clear Data, and Quit require administrator authentication
- Data retention:
  - Keeps only the last 7 days

## Install

1. Download the latest release:

   ```text
   BrowserTimeTracker.dmg
   ```

2. Open the DMG.

3. Drag `Browser Time Tracker.app` into `Applications`.

4. Open `Browser Time Tracker` from `Applications`.

5. The hourglass menu bar icon means the app is running.

## First-run permissions

The app needs permission to read the active browser tab URL and title.

### Automation

Used for Chrome, Safari, and Edge.

Open:

```text
System Settings -> Privacy & Security -> Automation
```

Allow `Browser Time Tracker` to control the browsers you want to track.

### Accessibility

Firefox URL tracking requires Accessibility access.

Open:

```text
System Settings -> Privacy & Security -> Accessibility
```

Allow `Browser Time Tracker`.

## Usage

Click the hourglass icon in the menu bar:

- `Open Dashboard`: open the local dashboard
- `Pause Tracking`: pause tracking
- `Clear Data`: clear local data
- `Quit`: quit the app

Dashboard:

```text
http://127.0.0.1:38888/dashboard
```

The dashboard supports:

- Date selection
- All-day or hourly view
- Clicking a daily bar to switch to that day
- Clicking an hourly bar to switch to that hour
- Top Websites and Top Pages

## Data Location

Local SQLite database:

```text
~/Library/Application Support/BrowserTimeTracker/browser_time.sqlite
```

## Uninstall

1. Quit `Browser Time Tracker` from the menu bar.
2. Delete:

   ```text
   /Applications/Browser Time Tracker.app
   ```

3. Optional: delete local data:

   ```bash
   rm -rf "$HOME/Library/Application Support/BrowserTimeTracker"
   ```

4. If you installed the LaunchAgent from source:

   ```bash
   ./scripts/uninstall-launch-agent.sh
   ```

## Build from Source

Requirements:

- macOS 13+
- Xcode Command Line Tools
- Swift 5.9+

Run locally:

```bash
cd mac-menubar
swift run BrowserTimeMenubar
```

Self-test:

```bash
cd mac-menubar
swift run BrowserTimeMenubar --self-test
```

Package DMG:

```bash
NOTARY_PROFILE="btt-notary" ./scripts/package-dmg.sh
```

If multiple Developer ID certificates are installed:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="btt-notary" \
./scripts/package-dmg.sh
```
