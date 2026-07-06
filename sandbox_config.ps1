# sandbox_config.ps1 — Configure a Windows VM as a CAPEv2 sandbox guest.
#
# What this script does:
#   1. Sets a static IP on the first non-virtual, "Up" adapter.
#   2. Disables Teredo, LLMNR, Defender, Firewall, Microsoft Store.
#   3. Installs Sysmon with SwiftOnSecurity's config.
#   4. Installs Python 3.10.11 (32-bit, preferred for 32-bit malware hooks)
#      to C:\Python310 with Pillow.
#   5. Downloads agent.py and registers it as a scheduled task running as
#      SYSTEM at logon.
#
# MUST be run as Administrator in an elevated PowerShell:
#   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
#   .\sandbox_config.ps1
#
# IPs are patched in by cape_config.py from sandbox.conf. The defaults below
# are placeholders that should never reach a real run.

#Requires -RunAsAdministrator

# --- admin check (belt + suspenders, since #Requires already enforces it) -----
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script requires administrative privileges. Please run as Administrator."
    exit 1
}

# --- logging -----------------------------------------------------------------
$logFile = "C:\SandboxSetup.log"
try {
    Start-Transcript -Path $logFile -Append -ErrorAction Stop
} catch {
    Write-Warning "Could not start transcript: $_"
}

# --- IPs patched by cape_config.py ------------------------------------------
$sandbox_ip = "x.x.x.x"   # patched from sandbox.conf:sandbox_ip
$cape_ip    = "x.x.x.x"   # patched from sandbox.conf:resultserver_ip

# --- helper ------------------------------------------------------------------
function Test-IpPatched {
    param([string]$Value, [string]$Name)
    if ($Value -eq "x.x.x.x" -or [string]::IsNullOrWhiteSpace($Value)) {
        Write-Error "$Name was not patched from sandbox.conf (still '$Value'). Re-run cape_config.py."
        exit 1
    }
    try { [System.Net.IPAddress]::Parse($Value) | Out-Null }
    catch { Write-Error "$Name is not a valid IP: $Value"; exit 1 }
}
Test-IpPatched -Value $sandbox_ip -Name "sandbox_ip"
Test-IpPatched -Value $cape_ip    -Name "cape_ip"

# --- find a real (non-virtual) network adapter --------------------------------
function Get-PhysicalAdapter {
    # Prefer the first adapter that is "Up", physical, and not a loopback.
    # Fallback: first "Up" adapter. We avoid hard-coding "Ethernet Instance 0"
    # because the name differs across Hyper-V / KVM / VMware platforms.
    $candidates = Get-NetAdapter |
        Where-Object { $_.Status -eq "Up" -and -not $_.Virtual -and $_.HardwareInterface } |
        Sort-Object -Property ifIndex

    if ($candidates) { return $candidates | Select-Object -First 1 }

    $fallback = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Sort-Object ifIndex | Select-Object -First 1
    if ($fallback) {
        Write-Warning "No physical adapter found, falling back to '$($fallback.Name)'."
        return $fallback
    }
    Write-Error "No active network adapter found on this VM."
    exit 1
}

$adapter = Get-PhysicalAdapter
Write-Host "Using adapter: $($adapter.Name) (ifIndex=$($adapter.ifIndex))"

# --- static IP ---------------------------------------------------------------
try {
    $ipAddress = [System.Net.IPAddress]::Parse($sandbox_ip)
    $gateway   = [System.Net.IPAddress]::Parse($cape_ip)

    # Wipe whatever DHCP gave us first so the new address doesn't collide.
    Remove-NetIPAddress -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction Stop
    Remove-NetRoute     -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction Stop

    New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $sandbox_ip `
        -PrefixLength 24 -DefaultGateway $cape_ip -ErrorAction Stop

    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name `
        -ServerAddresses ("8.8.8.8", "8.8.4.4") -ErrorAction Stop

    Write-Host "✔️ Static IP $sandbox_ip set with gateway $cape_ip."
} catch {
    Write-Error "Failed to set static IP: $_"
    exit 1
}

# --- Disable Teredo ----------------------------------------------------------
try {
    netsh interface teredo set state disabled | Out-Null
    Write-Host "✔️ Teredo disabled."
} catch { Write-Warning "Teredo disable failed: $_" }

# --- Disable LLMNR -----------------------------------------------------------
try {
    $regPath = "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    New-ItemProperty -Path $regPath -Name "EnableMulticast" -Value 0 `
        -PropertyType DWORD -Force | Out-Null
    Write-Host "✔️ LLMNR disabled."
} catch { Write-Warning "LLMNR disable failed: $_" }

# --- Disable Windows Defender -----------------------------------------------
try {
    $defPath  = "HKLM:\Software\Policies\Microsoft\Windows Defender"
    $rtPath   = "$defPath\Real-Time Protection"
    if (-not (Test-Path $defPath)) { New-Item -Path $defPath -Force | Out-Null }
    if (-not (Test-Path $rtPath))  { New-Item -Path $rtPath  -Force | Out-Null }

    Set-ItemProperty -Path $defPath -Name "DisableAntiSpyware" -Value 1
    Set-ItemProperty -Path $defPath -Name "AllowFastServiceStartup" -Value 0
    Set-ItemProperty -Path $rtPath  -Name "DisableRealtimeMonitoring" -Value 1

    foreach ($key in @("DisableRealtimeMonitoring", "DisableBehaviorMonitoring")) {
        try {
            Set-MpPreference -Name $key -Value $true -ErrorAction Stop
        } catch {
            Write-Warning "Set-MpPreference $key skipped: $_"
        }
    }
    Write-Host "✔️ Windows Defender disabled."
} catch {
    Write-Warning "Defender disable via registry failed: $_"
    try {
        Stop-Service -Name WinDefend -Force -ErrorAction Stop
        Write-Host "✔️ WinDefend service stopped as fallback."
    } catch { Write-Warning "WinDefend stop failed: $_" }
}

# --- Disable Firewall --------------------------------------------------------
try {
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop
    Write-Host "✔️ Firewall disabled on all profiles."
} catch { Write-Warning "Firewall disable failed: $_" }

# --- Disable Microsoft Store -------------------------------------------------
try {
    $storePath = "HKLM:\Software\Policies\Microsoft\WindowsStore"
    if (-not (Test-Path $storePath)) { New-Item -Path $storePath -Force | Out-Null }
    New-ItemProperty -Path $storePath -Name "RemoveWindowsStore" -Value 1 `
        -PropertyType DWORD -Force | Out-Null
    Write-Host "✔️ Microsoft Store disabled."
} catch { Write-Warning "Microsoft Store disable failed: $_" }

# --- Sysmon ------------------------------------------------------------------
$sysmonInstallOk = $false
try {
    $sysmonUrl   = "https://download.sysinternals.com/files/Sysmon.zip"
    $sysmonZip   = "$env:TEMP\Sysmon.zip"
    $sysmonDir   = "$env:TEMP\Sysmon"
    $sysmonCfgUrl = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
    $sysmonCfg   = "$sysmonDir\sysmonconfig.xml"
    $sysmonExe   = if ([System.Environment]::Is64BitOperatingSystem) { "Sysmon64.exe" } else { "Sysmon.exe" }

    Write-Host "Downloading Sysmon..."
    Invoke-WebRequest -Uri $sysmonUrl   -OutFile $sysmonZip -UseBasicParsing -ErrorAction Stop
    if (Test-Path $sysmonDir) { Remove-Item -Recurse -Force $sysmonDir }
    Expand-Archive -Path $sysmonZip -DestinationPath $sysmonDir -Force -ErrorAction Stop

    Write-Host "Downloading Sysmon config..."
    Invoke-WebRequest -Uri $sysmonCfgUrl -OutFile $sysmonCfg -UseBasicParsing -ErrorAction Stop

    Write-Host "Installing Sysmon..."
    Start-Process -FilePath "$sysmonDir\$sysmonExe" `
        -ArgumentList "-accepteula -i `"$sysmonCfg`"" `
        -Verb RunAs -Wait -ErrorAction Stop
    $sysmonInstallOk = $true
    Write-Host "✔️ Sysmon installed."
} catch { Write-Warning "Sysmon install failed: $_" }

# --- Python 3.10.11 (32-bit) + Pillow ----------------------------------------
# Install to C:\Python310 to avoid clashing with any pre-existing Python.
$pythonDir   = "C:\Python310"
$pythonExe   = "$pythonDir\python.exe"
$pipExe      = "$pythonDir\Scripts\pip.exe"
$pyInstaller = "$env:TEMP\python-3.10.11.exe"
$pyUrl       = "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe"

try {
    if (Test-Path $pythonExe) {
        Write-Host "Python already present at $pythonExe — skipping install."
    } else {
        Write-Host "Downloading Python 3.10.11 (32-bit)..."
        Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstaller -UseBasicParsing -ErrorAction Stop

        Write-Host "Installing Python to $pythonDir..."
        Start-Process -FilePath $pyInstaller `
            -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 TargetDir=$pythonDir Include_pip=1" `
            -Wait -ErrorAction Stop
        Remove-Item $pyInstaller -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path $pythonExe)) {
            throw "Python executable not found at $pythonExe after install."
        }
    }

    $pyVer = & $pythonExe --version 2>&1
    Write-Host "✔️ Python detected: $pyVer"

    Write-Host "Installing Pillow..."
    & $pipExe install --quiet --disable-pip-version-update Pillow
    Write-Host "✔️ Pillow installed."
} catch {
    Write-Error "Python/Pillow install failed: $_"
    exit 1
}

# --- CAPE agent as scheduled task -------------------------------------------
$agentDest = "C:\cape_agent.pyw"
$taskName  = "CAPE_Agent"
try {
    if (-not (Test-Path $agentDest)) {
        Write-Host "Downloading CAPE agent..."
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py" `
            -OutFile $agentDest -UseBasicParsing -ErrorAction Stop
    }

    # SYSTEM + Highest lets the agent inject into any process started by any
    # user (which is what CAPE requires).
    $action    = New-ScheduledTaskAction -Execute "$pythonExe" -Argument "`"$agentDest`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest `
        -LogonType ServiceAccount
    $task      = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger `
        -Description "CAPE Sandbox analysis agent"

    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "✔️ CAPE agent scheduled task '$taskName' registered."
} catch { Write-Warning "CAPE agent setup failed: $_" }

# --- summary -----------------------------------------------------------------
Write-Host ""
Write-Host "================ Summary ================"
Write-Host "Adapter         : $($adapter.Name)"
Write-Host "Sandbox IP      : $sandbox_ip"
Write-Host "CAPE gateway    : $cape_ip"
Write-Host "Python          : $pythonExe"
Write-Host "Sysmon          : $(if ($sysmonInstallOk) {'installed'} else {'FAILED'})"
Write-Host "CAPE agent task : $taskName"
Write-Host "=========================================="
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Install any runtimes you want (.NET, Java, Office, ...)."
Write-Host "  2. Shut down the VM, take a snapshot in virt-manager."
Write-Host "  3. Make sure the snapshot name matches 'snapshot' in sandbox.conf."

$restart = Read-Host "Restart now? (Y/N)"
if ($restart -eq 'Y' -or $restart -eq 'y') {
    Restart-Computer -Force
} else {
    Write-Host "Please restart manually to apply all changes."
}

try { Stop-Transcript | Out-Null } catch { }