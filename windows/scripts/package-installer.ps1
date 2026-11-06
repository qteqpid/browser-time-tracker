param(
    [string] $OutputDir = ".\artifacts\installer"
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

function Write-ErrorLog([string] $Message) {
    Write-Host ("ERROR: {0}" -f $Message) -ForegroundColor Red
}

try {
    $windowsRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $windowsRoot.Path $OutputDir }
    $payloadRoot = Join-Path $windowsRoot.Path "artifacts\installer-payload"
    $installerProject = Join-Path $windowsRoot.Path "src\BrowserTimeTracker.Installer"
    $payloadZip = Join-Path $installerProject "Payload\payload.zip"

    Write-Step "Publishing Service and Tray"
    Push-Location $windowsRoot.Path
    try {
        Write-Detail "Publishing Service self-contained win-x64."
        dotnet publish .\src\BrowserTimeTracker.Service\BrowserTimeTracker.Service.csproj -c Release -r win-x64 --self-contained true
        Write-Detail "Publishing Tray self-contained win-x64."
        dotnet publish .\src\BrowserTimeTracker.Tray\BrowserTimeTracker.Tray.csproj -c Release -r win-x64 --self-contained true
    } finally {
        Pop-Location
    }

    Write-Step "Staging installer payload"
    if (Test-Path $payloadRoot) {
        Remove-Item -Path $payloadRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null
    $servicePayloadDir = Join-Path $payloadRoot "Service"
    $trayPayloadDir = Join-Path $payloadRoot "Tray"
    $extensionPayloadDir = Join-Path $payloadRoot "browser-extension"
    New-Item -ItemType Directory -Force -Path $servicePayloadDir, $trayPayloadDir, $extensionPayloadDir | Out-Null
    Copy-Item -Path (Join-Path $windowsRoot.Path "src\BrowserTimeTracker.Service\bin\Release\net8.0-windows\win-x64\publish\*") -Destination $servicePayloadDir -Recurse -Force
    Copy-Item -Path (Join-Path $windowsRoot.Path "src\BrowserTimeTracker.Tray\bin\Release\net8.0-windows\win-x64\publish\*") -Destination $trayPayloadDir -Recurse -Force
    Copy-Item -Path (Join-Path $windowsRoot.Path "browser-extension\*") -Destination $extensionPayloadDir -Recurse -Force
    Copy-Item -Path (Join-Path $windowsRoot.Path "email_settings.example.json") -Destination (Join-Path $payloadRoot "email_settings.example.json") -Force
    Copy-Item -Path (Join-Path $windowsRoot.Path "packaging\install-from-package.ps1") -Destination (Join-Path $payloadRoot "install-from-package.ps1") -Force
    Write-Detail "Payload root: $payloadRoot"

    Write-Step "Compressing payload"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $payloadZip) | Out-Null
    if (Test-Path $payloadZip) {
        Remove-Item -Path $payloadZip -Force
    }
    Compress-Archive -Path (Join-Path $payloadRoot "*") -DestinationPath $payloadZip -Force
    Write-Detail "Payload zip: $payloadZip"

    Write-Step "Building setup executable"
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    dotnet publish (Join-Path $installerProject "BrowserTimeTracker.Installer.csproj") `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:EnableCompressionInSingleFile=true `
        -o $outputPath

    Write-Step "Installer package complete"
    Write-Detail "Setup executable: $(Join-Path $outputPath "BrowserTimeTrackerSetup.exe")"
    Write-Detail "Run the setup executable as administrator, or double-click it and approve the UAC prompt."
} catch {
    Write-ErrorLog "Installer packaging failed at step $script:StepNumber."
    Write-ErrorLog $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-ErrorLog ("Location: {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
        Write-ErrorLog ("Command: {0}" -f $_.InvocationInfo.Line.Trim())
    }
    throw
}
