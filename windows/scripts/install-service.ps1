param(
    [Parameter(Mandatory = $true)]
    [string] $ServiceExePath
)

$ErrorActionPreference = "Stop"
$serviceName = "BrowserTimeTracker"
$displayName = "Browser Time Tracker"

if (-not (Test-Path $ServiceExePath)) {
    throw "Service executable not found: $ServiceExePath"
}

$resolvedServiceExePath = (Resolve-Path $ServiceExePath).Path
$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Service already exists: $serviceName"
} else {
    New-Service `
        -Name $serviceName `
        -DisplayName $displayName `
        -Description "Local-first browser usage tracker service for Browser Time Tracker." `
        -BinaryPathName "`"$resolvedServiceExePath`"" `
        -StartupType Automatic
}

sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
sc.exe failureflag $serviceName 1 | Out-Null
Start-Service -Name $serviceName

Write-Host "Installed and started $displayName."
