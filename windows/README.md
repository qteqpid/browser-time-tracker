# Browser Time Tracker for Windows

[中文](#中文) · [English](#english)

## 中文

Windows 版采用三段式结构：

- `BrowserTimeTracker.Service`：Windows Service，负责接收浏览器事件、写入 SQLite、提供本地 Dashboard。
- `BrowserTimeTracker.Tray`：系统托盘 UI，只显示状态和打开 Dashboard；退出托盘不会停止追踪。
- `browser-extension`：Chrome / Edge 扩展，读取当前活动标签页并发送到 `http://127.0.0.1:38888/events`。

## Quick Start

在 Windows 机器上：

1. 安装 .NET 8 SDK。
2. 用管理员权限打开 PowerShell。
3. 进入本目录：

   ```powershell
   cd C:\Path\To\browser-time-tracker\windows
   ```

4. 构建并安装 Service / Tray：

   ```powershell
   .\scripts\install-windows.ps1 -Build
   ```

5. 在 Chrome 或 Edge 中加载 `windows\browser-extension` 扩展。
6. 打开几个普通网页。
7. 打开 Dashboard：

   ```text
   http://127.0.0.1:38888/dashboard
   ```

## Deliberately Removed Controls

Windows 版不在产品 UI 中提供这些入口：

- Pause Tracking
- Clear Data
- Stop Service
- Uninstall

托盘菜单里的 `Exit tray UI` 只关闭托盘图标，不停止 Windows Service。

## Antivirus-Friendly Design

为降低误报风险，Windows 版避免使用容易被安全软件标记的技术：

- 不隐藏进程。
- 不做进程注入、浏览器注入或 DLL 注入。
- 不安装内核驱动。
- 不拦截键盘、鼠标或网络流量。
- 不抓取网页内容，只读取活动标签页 URL 和标题。
- 只监听 `127.0.0.1:38888`，不对局域网或公网开放端口。
- 浏览器扩展只申请 `tabs`、`idle`、`alarms` 和 localhost host permission。
- Service 使用标准 Windows Service 安装方式，失败后自动重启。

正式发布时建议：

- 给 `.exe` 和安装包做 Authenticode code signing。
- 安装包使用明确的发布者名称、产品名称和版本号。
- 不使用加壳、混淆、反调试或自保护逻辑。
- 通过 Microsoft Defender SmartScreen reputation 的正常发布流程积累信誉。

## Build

需要在 Windows 上安装 .NET 8 SDK。

```powershell
dotnet publish .\src\BrowserTimeTracker.Service\BrowserTimeTracker.Service.csproj -c Release -r win-x64 --self-contained true
dotnet publish .\src\BrowserTimeTracker.Tray\BrowserTimeTracker.Tray.csproj -c Release -r win-x64 --self-contained true
```

## Install

以管理员 PowerShell 运行：

```powershell
.\scripts\install-windows.ps1 -Build
```

这个脚本会：

- 先运行 `dotnet publish` 生成 Service 和 Tray 的 `.exe`。
- 把 Service publish 目录复制到 `C:\Program Files\BrowserTimeTracker\Service`。
- 把 Tray publish 目录复制到 `C:\Program Files\BrowserTimeTracker\Tray`。
- 安装并启动 `BrowserTimeTracker` Windows Service。
- 设置 Service 失败后自动重启。
- 把 Tray 注册到 `HKLM\Software\Microsoft\Windows\CurrentVersion\Run`，让用户登录后自动显示托盘。
- 立即启动一次 Tray UI。

如果已经手动运行过 `dotnet publish`，也可以省略 `-Build`：

```powershell
.\scripts\install-windows.ps1
```

重复运行同一个命令可用于更新安装。脚本会在复制新文件前停止已有 Service，然后重新配置并启动 Service。

如果 publish 目录不在默认位置，可以显式传参：

```powershell
.\scripts\install-windows.ps1 `
  -ServicePublishDir "C:\Path\To\Service\publish" `
  -TrayPublishDir "C:\Path\To\Tray\publish"
```

如果只想给当前用户添加 Tray 启动项，也可以单独使用：

```powershell
.\scripts\install-tray-startup.ps1 -TrayExePath "C:\Path\To\BrowserTimeTracker.Tray.exe"
```

## Verify

安装后可以用这些方式确认状态：

```powershell
Get-Service BrowserTimeTracker
```

```powershell
Invoke-RestMethod http://127.0.0.1:38888/health
```

```text
http://127.0.0.1:38888/dashboard
```

如果 Service 正常运行，`/health` 应返回类似：

```json
{
  "ok": true,
  "paused": false
}
```

## Browser Extension

扩展目录：

```text
windows\browser-extension
```

扩展的作用是读取当前活动标签页的 URL 和标题，并把事件发送到本机 Service：

```text
http://127.0.0.1:38888/events
```

### Development Load

开发阶段可以用浏览器的开发者模式加载本地目录。

Chrome：

1. 打开 `chrome://extensions/`。
2. 打开右上角 `Developer mode`。
3. 点击 `Load unpacked`。
4. 选择 `windows\browser-extension` 目录。
5. 打开几个网页后访问 Dashboard：

```text
http://127.0.0.1:38888/dashboard
```

Edge：

1. 打开 `edge://extensions/`。
2. 打开左侧或右侧的 `Developer mode`。
3. 点击 `Load unpacked`。
4. 选择 `windows\browser-extension` 目录。
5. 打开几个网页后访问 Dashboard：

```text
http://127.0.0.1:38888/dashboard
```

如果 Dashboard 没有数据，先检查：

- Windows Service 是否运行：`Get-Service BrowserTimeTracker`
- 本地健康检查是否可访问：`http://127.0.0.1:38888/health`
- 扩展是否已经启用。
- 当前标签页 URL 是否是 `http://` 或 `https://`。

### Managed Install

面向受管设备时，推荐用 Chrome / Edge 的企业策略强制安装扩展。这样扩展由管理员部署，用户不能从普通扩展页面移除。

标准流程是：

1. 把扩展打包并发布到 Chrome Web Store 或 Microsoft Edge Add-ons，拿到正式 extension ID。
2. 在 Group Policy 或 Intune 中配置强制安装列表。
3. 策略值使用下面的格式：

```text
extension_id;update_url
```

Chrome Web Store 的格式通常是：

```text
<chrome_extension_id>;https://clients2.google.com/service/update2/crx
```

Microsoft Edge Add-ons 的格式通常是：

```text
<edge_extension_id>;https://edge.microsoft.com/extensionwebstorebase/v1/crx
```

Chrome Group Policy 路径：

```text
Computer Configuration
  -> Administrative Templates
  -> Google
  -> Google Chrome
  -> Extensions
  -> Configure the list of force-installed apps and extensions
```

Edge Group Policy 路径：

```text
Computer Configuration
  -> Administrative Templates
  -> Microsoft Edge
  -> Extensions
  -> Control which extensions are installed silently
```

Intune 里可以用 Settings Catalog 配置同类策略：

```text
Google Chrome / Microsoft Edge
  -> Extensions
  -> ExtensionInstallForcelist
```

开发阶段也可以临时用本地 unpacked extension 验证功能，但正式分发不要依赖本地目录；发布到扩展商店并用企业策略安装更稳定，也更不容易被安全软件误判。

## Current Limitations

- Windows 版目前是实验版，尚未在本仓库所在的 macOS 开发机上完成 Windows 实机编译和安装验证。
- 当前扩展优先覆盖 Chrome 和 Edge；Firefox 需要后续单独适配和测试。
- 正式托管扩展需要 Chrome Web Store 或 Microsoft Edge Add-ons 的 extension ID。
- App 内不提供 Pause、Clear Data、Stop Service、Uninstall，但 Windows 管理员仍可从系统层面管理 Service、启动项和文件。
- 当前没有安装包 UI；安装流程依赖 PowerShell 脚本。

## Troubleshooting

Dashboard 没有数据时：

1. 确认 Service 正在运行：

   ```powershell
   Get-Service BrowserTimeTracker
   ```

2. 确认本地 API 正常：

   ```powershell
   Invoke-RestMethod http://127.0.0.1:38888/health
   ```

3. 确认 Chrome / Edge 扩展已启用。
4. 确认当前标签页是 `http://` 或 `https://` 页面。
5. 确认浏览器不是停留在 `chrome://`、`edge://`、扩展页面或本地文件页面。

## Local Data

```text
%LOCALAPPDATA%\BrowserTimeTracker\browser_time.sqlite
```

Dashboard：

```text
http://127.0.0.1:38888/dashboard
```

## English

The Windows version is experimental. It uses three pieces:

- `BrowserTimeTracker.Service`: a Windows Service that receives browser events, writes SQLite data, and serves the local Dashboard.
- `BrowserTimeTracker.Tray`: a tray UI that shows service status and opens the Dashboard. Exiting the tray UI does not stop tracking.
- `browser-extension`: a Chrome / Edge extension that sends the active tab URL and title to `http://127.0.0.1:38888/events`.

### Quick Start

1. Install the .NET 8 SDK.
2. Open PowerShell as Administrator.
3. Enter the Windows project directory:

   ```powershell
   cd C:\Path\To\browser-time-tracker\windows
   ```

4. Build and install the Service and Tray apps:

   ```powershell
   .\scripts\install-windows.ps1 -Build
   ```

5. Load `windows\browser-extension` in Chrome or Edge.
6. Open a few normal `http://` or `https://` pages.
7. Open the Dashboard:

   ```text
   http://127.0.0.1:38888/dashboard
   ```

### Install Details

The installer script copies the published Service files to:

```text
C:\Program Files\BrowserTimeTracker\Service
```

It copies the Tray files to:

```text
C:\Program Files\BrowserTimeTracker\Tray
```

It installs and starts the `BrowserTimeTracker` Windows Service, configures automatic restart on failure, registers the Tray app in:

```text
HKLM\Software\Microsoft\Windows\CurrentVersion\Run
```

Running the same script again updates the install.

### Extension

For development:

1. Open `chrome://extensions/` or `edge://extensions/`.
2. Enable Developer mode.
3. Click `Load unpacked`.
4. Select `windows\browser-extension`.

For managed devices, publish the extension to Chrome Web Store or Microsoft Edge Add-ons, then deploy it with Group Policy or Intune using `ExtensionInstallForcelist`.

### Verify

```powershell
Get-Service BrowserTimeTracker
```

```powershell
Invoke-RestMethod http://127.0.0.1:38888/health
```

```text
http://127.0.0.1:38888/dashboard
```

### Limitations

- The Windows version is experimental and still needs real Windows build/install validation.
- Chrome and Edge are the first supported browsers; Firefox needs separate testing.
- The app UI intentionally does not expose Pause, Clear Data, Stop Service, or Uninstall.
- Windows administrators can still manage the service and files at the OS level.
- There is no graphical installer yet; installation uses PowerShell scripts.
