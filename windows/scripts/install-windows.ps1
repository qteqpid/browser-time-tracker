param(
    [string] $ServicePublishDir = ".\src\BrowserTimeTracker.Service\bin\Release\net8.0-windows\win-x64\publish",
    [string] $TrayPublishDir = ".\src\BrowserTimeTracker.Tray\bin\Release\net8.0-windows\win-x64\publish",
    [string] $InstallRoot = "$env:ProgramFiles\BrowserTimeTracker",
    [switch] $Build,
    [switch] $SkipService,
    [switch] $SkipTrayStartup
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RequiredDirectory([string] $Path, [string] $Name) {
    $resolved = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw "$Name directory not found: $Path"
    }
    return $resolved.Path
}

function Join-RelativeToWindowsRoot([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $windowsRoot.Path $Path
}

function Stop-ServiceAndWait([string] $Name) {
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -eq "Stopped") {
        return
    }

    Write-Host "Stopping existing service before updating files: $Name"
    Stop-Service -Name $Name -Force
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
}

function Stop-TrayAndWait {
    $processes = Get-Process -Name "BrowserTimeTracker.Tray" -ErrorAction SilentlyContinue
    if (-not $processes) {
        return
    }

    Write-Host "Stopping existing tray UI before updating files."
    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force
    }

    foreach ($process in $processes) {
        try {
            $process.WaitForExit(10000) | Out-Null
        } catch {
        }
    }
}

function Ensure-EmailSettingsTemplate {
    $appDataRoot = Join-Path $env:LOCALAPPDATA "BrowserTimeTracker"
    $settingsPath = Join-Path $appDataRoot "email_settings.json"
    if (Test-Path $settingsPath) {
        return
    }

    New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
    $templatePath = Join-Path $windowsRoot.Path "email_settings.example.json"
    if (Test-Path $templatePath) {
        Copy-Item -Path $templatePath -Destination $settingsPath
    } else {
        @'
{
  "enabled": false,
  "smtpHost": "smtp.163.com",
  "smtpPort": 25,
  "enableSsl": false,
  "from": "",
  "username": "",
  "password": "",
  "to": "",
  "cooldownMinutes": 30
}
'@ | Set-Content -Path $settingsPath -Encoding UTF8
    }

    Write-Host "Email settings template created: $settingsPath"
    Write-Host "Fill in from/username/password/to and set enabled to true to enable startup email notifications."
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script from an elevated Administrator PowerShell."
}

$windowsRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ($Build) {
    Push-Location $windowsRoot.Path
    try {
        dotnet publish .\src\BrowserTimeTracker.Service\BrowserTimeTracker.Service.csproj -c Release -r win-x64 --self-contained true
        dotnet publish .\src\BrowserTimeTracker.Tray\BrowserTimeTracker.Tray.csproj -c Release -r win-x64 --self-contained true
    } finally {
        Pop-Location
    }
}

$serviceName = "BrowserTimeTracker"
$displayName = "Browser Time Tracker"
$servicePublishDir = Resolve-RequiredDirectory (Join-RelativeToWindowsRoot $ServicePublishDir) "Service publish"
$trayPublishDir = Resolve-RequiredDirectory (Join-RelativeToWindowsRoot $TrayPublishDir) "Tray publish"
$serviceExeSource = Join-Path $servicePublishDir "BrowserTimeTracker.Service.exe"
$trayExeSource = Join-Path $trayPublishDir "BrowserTimeTracker.Tray.exe"

if (-not (Test-Path $serviceExeSource)) {
    throw "Service executable not found: $serviceExeSource"
}
if (-not (Test-Path $trayExeSource)) {
    throw "Tray executable not found: $trayExeSource"
}

$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $SkipService -and $existing -and $existing.Status -ne "Stopped") {
    Stop-ServiceAndWait $serviceName
}
Stop-TrayAndWait
Ensure-EmailSettingsTemplate

$serviceInstallDir = Join-Path $InstallRoot "Service"
$trayInstallDir = Join-Path $InstallRoot "Tray"
New-Item -ItemType Directory -Force -Path $serviceInstallDir, $trayInstallDir | Out-Null

Copy-Item -Path (Join-Path $servicePublishDir "*") -Destination $serviceInstallDir -Recurse -Force
Copy-Item -Path (Join-Path $trayPublishDir "*") -Destination $trayInstallDir -Recurse -Force

$serviceExePath = Join-Path $serviceInstallDir "BrowserTimeTracker.Service.exe"
$trayExePath = Join-Path $trayInstallDir "BrowserTimeTracker.Tray.exe"

if (-not $SkipService) {
    if ($existing) {
        Write-Host "Updating existing service: $serviceName"
        sc.exe config $serviceName binPath= "`"$serviceExePath`"" start= auto DisplayName= "`"$displayName`"" | Out-Null
    } else {
        New-Service `
            -Name $serviceName `
            -DisplayName $displayName `
            -Description "Local-first browser usage tracker service for Browser Time Tracker." `
            -BinaryPathName "`"$serviceExePath`"" `
            -StartupType Automatic
    }

    sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    sc.exe failureflag $serviceName 1 | Out-Null
    Start-Service -Name $serviceName
    Write-Host "Service installed and running: $serviceName"
}

if (-not $SkipTrayStartup) {
    $runKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-ItemProperty `
        -Path $runKey `
        -Name "BrowserTimeTrackerTray" `
        -Value "`"$trayExePath`"" `
        -PropertyType String `
        -Force | Out-Null
    Write-Host "Tray startup registered for all users."

    Start-Process -FilePath $trayExePath
    Write-Host "Tray UI started."
}

Write-Host "Browser Time Tracker installed to: $InstallRoot"
