#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'build/client-install.ps1'
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
Write-Host 'PASS: PowerShell installer syntax'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: user environment and registry checks require Windows.'
    return
}

function Assert-RKTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$names = @('http_proxy', 'https_proxy', 'no_proxy', 'all_proxy')
$originalEnvironment = @{}
foreach ($name in $names) {
    $originalEnvironment[$name] = @{
        User = [Environment]::GetEnvironmentVariable($name, 'User')
        Process = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}
$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$originalRegistry = @{}
if (Test-Path $registryPath) { $key = Get-Item $registryPath } else { $key = $null }
foreach ($name in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')) {
    $present = $null -ne $key -and $key.GetValueNames() -contains $name
    $originalRegistry[$name] = @{
        Present = $present
        Kind = if ($present) { $key.GetValueKind($name).ToString() } else { $null }
        Value = if ($present) {
            $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else { $null }
    }
}
$originalLocalAppData = $env:LOCALAPPDATA
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('vpn-proxy-windows-test-' + [Guid]::NewGuid().ToString('N'))
$global:RKTestCurlExit = 0
function global:curl.exe {
    if ($args -contains '--write-out') { '200 200 0' } else { 'HTTP/2 200' }
    $global:LASTEXITCODE = $global:RKTestCurlExit
}
try {
    $env:LOCALAPPDATA = $scratch
    [Environment]::SetEnvironmentVariable('http_proxy', 'http://previous.invalid:8000', 'User')
    $env:http_proxy = 'http://process.invalid:8001'
    $env:no_proxy = 'existing.internal'
    $env:all_proxy = 'socks5://previous.invalid:1080'
    if (-not (Test-Path $registryPath)) { [void](New-Item -Path $registryPath -Force) }
    [void](New-ItemProperty -Path $registryPath -Name ProxyEnable -Value 0 -PropertyType DWord -Force)
    [void](New-ItemProperty -Path $registryPath -Name AutoConfigURL -Value 'http://previous.invalid/proxy.pac' -PropertyType String -Force)

    & $installer -ProxyUrl 'http://proxy.example:7897' -NoProxy 'new.internal'
    Assert-RKTest ($env:http_proxy -eq 'http://proxy.example:7897') 'Process proxy not installed'
    Assert-RKTest ([Environment]::GetEnvironmentVariable('https_proxy', 'User') -eq 'http://proxy.example:7897') 'User proxy not persisted'
    Assert-RKTest ([string]::IsNullOrEmpty($env:all_proxy)) 'Old SOCKS proxy not cleared'
    Assert-RKTest ($env:no_proxy -match 'existing.internal' -and $env:no_proxy -match 'new.internal') 'Bypass entries not preserved'
    Assert-RKTest ((Get-ItemProperty $registryPath).ProxyEnable -eq 0) 'Terminal-only install changed Windows proxy'

    & $installer -ProxyUrl 'http://proxy.example:7897' -SystemProxy
    & $installer -ProxyUrl 'http://alternate.example:8765' -SystemProxy
    Assert-RKTest ((Get-ItemProperty $registryPath).ProxyServer -eq 'alternate.example:8765') 'Windows proxy not updated'
    Assert-RKTest ((Get-ItemProperty $registryPath).ProxyEnable -eq 1) 'Windows proxy not enabled'
    $backup = Join-Path $scratch 'rk-vpn-proxy/backup.json'
    $state = Get-Content $backup -Raw | ConvertFrom-Json
    Assert-RKTest ($state.Environment.http_proxy.User -eq 'http://previous.invalid:8000') 'Repeated install replaced original backup'

    & $installer -Uninstall
    Assert-RKTest ($env:http_proxy -eq 'http://process.invalid:8001') 'Process environment not restored'
    Assert-RKTest ([Environment]::GetEnvironmentVariable('http_proxy', 'User') -eq 'http://previous.invalid:8000') 'User environment not restored'
    Assert-RKTest ((Get-ItemProperty $registryPath).ProxyEnable -eq 0) 'Windows proxy not restored'
    Assert-RKTest ((Get-ItemProperty $registryPath).AutoConfigURL -eq 'http://previous.invalid/proxy.pac') 'PAC not restored'
    Assert-RKTest (-not (Test-Path $backup)) 'Active backup not archived after uninstall'

    $global:RKTestCurlExit = 28
    $failed = $false
    try { & $installer -ProxyUrl 'http://unreachable.example:7897' } catch { $failed = $true }
    Assert-RKTest $failed 'Failed probe incorrectly succeeded'
    Assert-RKTest ($env:http_proxy -eq 'http://process.invalid:8001') 'Failed probe changed process proxy'
    Assert-RKTest (-not (Test-Path $backup)) 'Failed probe wrote persistent state'
    Write-Host 'PASS: Windows persistence, optional system proxy, repeated installation, restore and failed probe'
} finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name].User, 'User')
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name].Process, 'Process')
    }
    foreach ($name in $originalRegistry.Keys) {
        $saved = $originalRegistry[$name]
        if ($saved.Present) {
            [void](New-ItemProperty -Path $registryPath -Name $name -Value $saved.Value -PropertyType $saved.Kind -Force)
        } else { Remove-ItemProperty -Path $registryPath -Name $name -ErrorAction SilentlyContinue }
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    Remove-Item Function:\curl.exe
    if ('RKVPN.Native' -as [type]) {
        [void][RKVPN.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][RKVPN.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    }
}
