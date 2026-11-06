param(
    [string] $ServicePublishDir = ".\src\BrowserTimeTracker.Service\bin\Release\net8.0-windows\win-x64\publish",
    [string] $TrayPublishDir = ".\src\BrowserTimeTracker.Tray\bin\Release\net8.0-windows\win-x64\publish",
    [string] $InstallRoot = "$env:ProgramFiles\BrowserTimeTracker",
    [switch] $Build,
    [switch] $SkipService,
    [switch] $SkipTrayStartup
)

$ErrorActionPreference = "Stop"
$script:StepNumber = 0

function Write-Step([string] $Message) {
    $script:StepNumber += 1
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $script:StepNumber, $Message)
}

function Write-Detail([string] $Message) {
    Write-Host ("    {0}" -f $Message)
}

function Write-WarningLog([string] $Message) {
    Write-Host ("WARNING: {0}" -f $Message) -ForegroundColor Yellow
}

function Write-ErrorLog([string] $Message) {
    Write-Host ("ERROR: {0}" -f $Message) -ForegroundColor Red
}

function Read-YesNo([string] $Question, [bool] $DefaultYes) {
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    Write-Host -NoNewline $Question
    Write-Host -NoNewline " "
    Write-Host -NoNewline $suffix
    Write-Host -NoNewline ": "
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    $normalized = $answer.Trim().ToLowerInvariant()
    return $normalized -eq "y" -or $normalized -eq "yes" -or $normalized -eq "1"
}

function Read-TextWithDefault([string] $Question, [string] $DefaultValue) {
    Write-Host -NoNewline $Question
    if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        Write-Host -NoNewline ": "
        $answer = Read-Host
        return $answer.Trim()
    }

    Write-Host -NoNewline " ["
    Write-Host -NoNewline $DefaultValue
    Write-Host -NoNewline "]: "
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultValue
    }

    return $answer.Trim()
}

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
        Write-Detail "Service is already stopped or not installed: $Name"
        return
    }

    Write-Detail "Stopping existing service before updating files: $Name"
    Stop-Service -Name $Name -Force
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
    Write-Detail "Service stopped: $Name"
}

function Stop-TrayAndWait {
    $processes = Get-Process -Name "BrowserTimeTracker.Tray" -ErrorAction SilentlyContinue
    if (-not $processes) {
        Write-Detail "Tray UI is not running."
        return
    }

    Write-Detail "Stopping existing tray UI before updating files."
    foreach ($process in $processes) {
        Write-Detail "Stopping tray PID: $($process.Id)"
        Stop-Process -Id $process.Id -Force
    }

    foreach ($process in $processes) {
        try {
            $process.WaitForExit(10000) | Out-Null
        } catch {
            Write-WarningLog "Failed while waiting for tray PID $($process.Id) to exit: $($_.Exception.Message)"
        }
    }
    Write-Detail "Tray UI stopped."
}

function New-DefaultEmailSettings {
    return [ordered]@{
        enabled = $false
        smtpHost = "smtp.163.com"
        smtpPort = 25
        enableSsl = $false
        from = ""
        username = ""
        password = ""
        to = ""
        cooldownMinutes = 30
    }
}

function Write-EmailSettingsJson([string] $Path, $Settings) {
    $Settings | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding UTF8
}

function Read-ExistingEmailSettings([string] $Path) {
    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        return Get-Content -Path $Path -Raw | ConvertFrom-Json
    } catch {
        Write-WarningLog "Could not read existing email settings; installer can rewrite it if you choose to configure email now: $($_.Exception.Message)"
        return $null
    }
}

function Test-EmailSettingsConfigured($Settings) {
    return (
        $Settings -and
        $Settings.enabled -eq $true -and
        -not [string]::IsNullOrWhiteSpace($Settings.smtpHost) -and
        -not [string]::IsNullOrWhiteSpace($Settings.from) -and
        -not [string]::IsNullOrWhiteSpace($Settings.username) -and
        -not [string]::IsNullOrWhiteSpace($Settings.password) -and
        -not [string]::IsNullOrWhiteSpace($Settings.to)
    )
}

function Get-EmailSettingValue($Settings, [string] $Name, [string] $DefaultValue) {
    if ($Settings -and $Settings.PSObject.Properties.Name -contains $Name) {
        $value = $Settings.$Name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return $DefaultValue
}

function Get-EmailSettingBool($Settings, [string] $Name, [bool] $DefaultValue) {
    if (-not $Settings -or -not ($Settings.PSObject.Properties.Name -contains $Name)) {
        return $DefaultValue
    }

    $value = $Settings.$Name
    if ($value -is [bool]) {
        return $value
    }

    $parsed = $false
    if ([bool]::TryParse([string]$value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Configure-EmailSettingsInteractively([string] $SettingsPath, $ExistingSettings) {
    Write-Detail "Configuring startup email notification."
    Write-Detail "For 163 email, use the SMTP authorization code as the password, not the normal mailbox login password."

    $smtpHost = Read-TextWithDefault "SMTP host" (Get-EmailSettingValue $ExistingSettings "smtpHost" "smtp.163.com")
    $smtpPortText = Read-TextWithDefault "SMTP port" (Get-EmailSettingValue $ExistingSettings "smtpPort" "25")
    $smtpPort = 25
    if (-not [int]::TryParse($smtpPortText, [ref]$smtpPort)) {
        Write-WarningLog "Invalid SMTP port '$smtpPortText'; using 25."
        $smtpPort = 25
    }

    $enableSsl = Read-YesNo "Enable SSL/TLS for SMTP?" (Get-EmailSettingBool $ExistingSettings "enableSsl" $false)
    $from = Read-TextWithDefault "Sender email" (Get-EmailSettingValue $ExistingSettings "from" "")
    $username = Read-TextWithDefault "SMTP username" (Get-EmailSettingValue $ExistingSettings "username" $from)
    $to = Read-TextWithDefault "Recipient email" (Get-EmailSettingValue $ExistingSettings "to" $from)
    $password = Read-Host "SMTP authorization code"

    if ([string]::IsNullOrWhiteSpace($from) -or
        [string]::IsNullOrWhiteSpace($username) -or
        [string]::IsNullOrWhiteSpace($to) -or
        [string]::IsNullOrWhiteSpace($password)) {
        Write-WarningLog "Email notification was not enabled because sender, username, recipient, or authorization code is empty."
        return
    }

    $cooldownText = Read-TextWithDefault "Email cooldown minutes" (Get-EmailSettingValue $ExistingSettings "cooldownMinutes" "30")
    $cooldownMinutes = 30
    if (-not [int]::TryParse($cooldownText, [ref]$cooldownMinutes) -or $cooldownMinutes -lt 1) {
        Write-WarningLog "Invalid cooldown '$cooldownText'; using 30 minutes."
        $cooldownMinutes = 30
    }

    $settings = [ordered]@{
        enabled = $true
        smtpHost = $smtpHost
        smtpPort = $smtpPort
        enableSsl = $enableSsl
        from = $from
        username = $username
        password = $password
        to = $to
        cooldownMinutes = $cooldownMinutes
    }
    Write-EmailSettingsJson $SettingsPath $settings
    Write-Detail "Email notification enabled and saved to: $SettingsPath"
}

function Ensure-EmailSettings {
    $appDataRoot = Join-Path $env:LOCALAPPDATA "BrowserTimeTracker"
    $settingsPath = Join-Path $appDataRoot "email_settings.json"
    Write-Detail "Email settings path: $settingsPath"

    New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
    Write-Detail "Ensured app data directory: $appDataRoot"

    if (-not (Test-Path $settingsPath)) {
        $templatePath = Join-Path $windowsRoot.Path "email_settings.example.json"
        if (Test-Path $templatePath) {
            Write-Detail "Copying email settings template from: $templatePath"
            Copy-Item -Path $templatePath -Destination $settingsPath
        } else {
            Write-Detail "Template not found; writing built-in email settings template."
            Write-EmailSettingsJson $settingsPath (New-DefaultEmailSettings)
        }
        Write-Detail "Email settings template created: $settingsPath"
    } else {
        Write-Detail "Email settings already exists."
    }

    $existingSettings = Read-ExistingEmailSettings $settingsPath
    if (Test-EmailSettingsConfigured $existingSettings) {
        if (-not (Read-YesNo "Email notification is already configured. Update it now?" $false)) {
            Write-Detail "Keeping existing email settings unchanged."
            return
        }
    } elseif (-not (Read-YesNo "Configure startup email notification now?" $true)) {
        Write-Detail "Email notification remains disabled. You can edit this file later: $settingsPath"
        return
    }

    Configure-EmailSettingsInteractively $settingsPath $existingSettings
}

try {
    if (-not (Test-IsAdministrator)) {
        throw "Run this script from an elevated Administrator PowerShell."
    }

    $windowsRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    Write-Step "Resolved Windows project root"
    Write-Detail "Windows root: $($windowsRoot.Path)"
    Write-Detail "Install root: $InstallRoot"
    Write-Detail "LOCALAPPDATA: $env:LOCALAPPDATA"

    if ($Build) {
        Write-Step "Publishing Service and Tray"
        Push-Location $windowsRoot.Path
        try {
            Write-Detail "Publishing Service project for win-x64."
            dotnet publish .\src\BrowserTimeTracker.Service\BrowserTimeTracker.Service.csproj -c Release -r win-x64 --self-contained true
            Write-Detail "Publishing Tray project for win-x64."
            dotnet publish .\src\BrowserTimeTracker.Tray\BrowserTimeTracker.Tray.csproj -c Release -r win-x64 --self-contained true
        } finally {
            Pop-Location
        }
    } else {
        Write-Step "Skipping build"
        Write-Detail "Using existing publish directories."
    }

    $serviceName = "BrowserTimeTracker"
    $displayName = "Browser Time Tracker"
    $servicePublishDir = Resolve-RequiredDirectory (Join-RelativeToWindowsRoot $ServicePublishDir) "Service publish"
    $trayPublishDir = Resolve-RequiredDirectory (Join-RelativeToWindowsRoot $TrayPublishDir) "Tray publish"
    $serviceExeSource = Join-Path $servicePublishDir "BrowserTimeTracker.Service.exe"
    $trayExeSource = Join-Path $trayPublishDir "BrowserTimeTracker.Tray.exe"

    Write-Step "Resolved publish outputs"
    Write-Detail "Service publish directory: $servicePublishDir"
    Write-Detail "Tray publish directory: $trayPublishDir"
    Write-Detail "Service executable source: $serviceExeSource"
    Write-Detail "Tray executable source: $trayExeSource"

    if (-not (Test-Path $serviceExeSource)) {
        throw "Service executable not found: $serviceExeSource"
    }
    if (-not (Test-Path $trayExeSource)) {
        throw "Tray executable not found: $trayExeSource"
    }

    $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    Write-Step "Stopping running components before copying files"
    if (-not $SkipService -and $existing -and $existing.Status -ne "Stopped") {
        Stop-ServiceAndWait $serviceName
    } elseif ($SkipService) {
        Write-Detail "Skipping service stop because -SkipService was provided."
    } else {
        Write-Detail "Service is not running or not installed."
    }
    Stop-TrayAndWait

    Write-Step "Preparing email notification settings"
    Ensure-EmailSettings

    $serviceInstallDir = Join-Path $InstallRoot "Service"
    $trayInstallDir = Join-Path $InstallRoot "Tray"
    Write-Step "Creating install directories"
    Write-Detail "Service install directory: $serviceInstallDir"
    Write-Detail "Tray install directory: $trayInstallDir"
    New-Item -ItemType Directory -Force -Path $serviceInstallDir, $trayInstallDir | Out-Null

    Write-Step "Copying published files into Program Files"
    Write-Detail "Copying Service files to: $serviceInstallDir"
    Copy-Item -Path (Join-Path $servicePublishDir "*") -Destination $serviceInstallDir -Recurse -Force
    Write-Detail "Copying Tray files to: $trayInstallDir"
    Copy-Item -Path (Join-Path $trayPublishDir "*") -Destination $trayInstallDir -Recurse -Force

    $serviceExePath = Join-Path $serviceInstallDir "BrowserTimeTracker.Service.exe"
    $trayExePath = Join-Path $trayInstallDir "BrowserTimeTracker.Tray.exe"
    Write-Detail "Installed Service executable: $serviceExePath"
    Write-Detail "Installed Tray executable: $trayExePath"

    if (-not $SkipService) {
        Write-Step "Installing or updating Windows Service"
        if ($existing) {
            Write-Detail "Updating existing service: $serviceName"
            sc.exe config $serviceName binPath= "`"$serviceExePath`"" start= auto DisplayName= "`"$displayName`"" | Out-Null
        } else {
            Write-Detail "Creating new service: $serviceName"
            New-Service `
                -Name $serviceName `
                -DisplayName $displayName `
                -Description "Local-first browser usage tracker service for Browser Time Tracker." `
                -BinaryPathName "`"$serviceExePath`"" `
                -StartupType Automatic
        }

        Write-Detail "Configuring service failure restart policy."
        sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
        sc.exe failureflag $serviceName 1 | Out-Null
        Write-Detail "Starting service: $serviceName"
        Start-Service -Name $serviceName
        Write-Detail "Service installed and running: $serviceName"
    } else {
        Write-Step "Skipping Windows Service install/update"
    }

    if (-not $SkipTrayStartup) {
        Write-Step "Registering and starting Tray UI"
        $runKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
        Write-Detail "Startup registry key: $runKey"
        Write-Detail "Startup value: `"$trayExePath`""
        New-ItemProperty `
            -Path $runKey `
            -Name "BrowserTimeTrackerTray" `
            -Value "`"$trayExePath`"" `
            -PropertyType String `
            -Force | Out-Null
        Write-Detail "Tray startup registered for all users."

        Write-Detail "Starting Tray UI: $trayExePath"
        Start-Process -FilePath $trayExePath
        Write-Detail "Tray UI started."
    } else {
        Write-Step "Skipping Tray startup registration"
    }

    Write-Step "Installation complete"
    Write-Detail "Browser Time Tracker installed to: $InstallRoot"
    Write-Detail "Email settings file: $(Join-Path (Join-Path $env:LOCALAPPDATA "BrowserTimeTracker") "email_settings.json")"
    Write-Detail "Local dashboard: http://127.0.0.1:38888/dashboard"
    Write-Detail "Use the tray menu to open screenshots or copy the LAN screenshot link."
} catch {
    Write-ErrorLog "Installation failed at step $script:StepNumber."
    Write-ErrorLog $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-ErrorLog ("Location: {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
        Write-ErrorLog ("Command: {0}" -f $_.InvocationInfo.Line.Trim())
    }
    throw
}
