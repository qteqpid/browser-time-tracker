param(
    [Parameter(Mandatory = $true)]
    [string] $TrayExePath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $TrayExePath)) {
    throw "Tray executable not found: $TrayExePath"
}

$startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force -Path $startup | Out-Null

$shortcutPath = Join-Path $startup "Browser Time Tracker Tray.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = (Resolve-Path $TrayExePath).Path
$shortcut.WorkingDirectory = Split-Path -Parent $shortcut.TargetPath
$shortcut.Description = "Browser Time Tracker tray UI"
$shortcut.Save()

Write-Host "Tray startup shortcut created: $shortcutPath"
