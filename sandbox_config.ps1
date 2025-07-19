# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script requires administrative privileges. Please run as Administrator."
    exit 1
}

# Start logging
$logFile = "C:\SandboxSetup.log"
Start-Transcript -Path $logFile -Append

# set static IP
$sandbox_ip = "x.x.x.x"
$cape_ip = "x.x.x.x"

try {
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq "Ethernet Instance 0" }
    if ($adapter) {
        $ipAddress = [System.Net.IPAddress]::Parse($sandbox_ip)
        $gateway = [System.Net.IPAddress]::Parse($cape_ip)
        $subnet = "255.255.255.0"

        # Remove existing IP configuration
        Remove-NetIPAddress -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction Stop
        Remove-NetRoute -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction Stop

        # Set static IP, subnet, and gateway
        New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $sandbox_ip -PrefixLength 24 -DefaultGateway $cape_ip -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses ("8.8.8.8", "8.8.4.4") -ErrorAction Stop

        Write-Host "Static IP $sandbox_ip set with gateway $cape_ip for adapter $($adapter.Name)."
    } else {
        Write-Error "No network adapter named 'Ethernet' found."
    }
} catch {
    Write-Error "Failed to set static IP: $_"
}

# Disable Teredo
try {
    netsh interface teredo set state disabled
    Write-Host "Teredo has been disabled."
} catch {
    Write-Error "Failed to disable Teredo: $_"
}

# Disable LLMNR
$regPath = "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient"
$name = "EnableMulticast"
$value = 0

try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force | Out-Null
    Write-Host "LLMNR has been disabled."
} catch {
    Write-Error "Failed to disable LLMNR: $_"
}

# Disable Windows Defender and Related Features
$regPath = "HKLM:\Software\Policies\Microsoft\Windows Defender"
$realTimePath = "$regPath\Real-Time Protection"
$mpPreferenceSettings = @{
    DisableRealtimeMonitoring = $true
    DisableBehaviorMonitoring = $true
}

try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    if (-not (Test-Path $realTimePath)) {
        New-Item -Path $realTimePath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name "DisableAntiSpyware" -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path $regPath -Name "AllowFastServiceStartup" -Value 0 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path $realTimePath -Name "DisableRealtimeMonitoring" -Value 1 -PropertyType DWORD -Force | Out-Null

    foreach ($key in $mpPreferenceSettings.Keys) {
        try {
            Set-MpPreference -Name $key -Value $mpPreferenceSettings[$key] -ErrorAction Stop
        } catch {
            Write-Warning "Skipping unsupported parameter '$key': $_"
        }
    }
    Write-Host "Windows Defender and related protections have been disabled."
} catch {
    Write-Error "Failed to disable Windows Defender: $_"
    # Fallback: Stop Defender service if registry method fails
    try {
        Stop-Service -Name WinDefend -Force -ErrorAction Stop
        Write-Host "Windows Defender service stopped as a fallback."
    } catch {
        Write-Warning "Could not stop Windows Defender service: $_"
    }
}

# Disable Firewall
try {
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop
    Write-Host "Firewall has been disabled for all profiles."
} catch {
    Write-Error "Failed to disable firewall: $_"
}

# Disable Microsoft Store
$regPath = "HKLM:\Software\Policies\Microsoft\WindowsStore"
$name = "RemoveWindowsStore"
$value = 1

try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force | Out-Null
    Write-Host "Microsoft Store has been disabled."
} catch {
    Write-Error "Failed to disable Microsoft Store: $_"
}

# Download and Install Sysmon
try {
    $sysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"
    $sysmonZip = "$env:TEMP\Sysmon.zip"
    $sysmonDir = "$env:TEMP\Sysmon"
    $sysmonConfigUrl = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
    $sysmonConfig = "$sysmonDir\sysmonconfig.xml"
    $sysmonExe = if ([System.Environment]::Is64BitOperatingSystem) { "Sysmon64.exe" } else { "Sysmon.exe" }

    Write-Host "Downloading Sysmon..."
    Invoke-WebRequest -Uri $sysmonUrl -OutFile $sysmonZip -ErrorAction Stop
    Expand-Archive -Path $sysmonZip -DestinationPath $sysmonDir -Force -ErrorAction Stop

    Write-Host "Downloading Sysmon configuration..."
    Invoke-WebRequest -Uri $sysmonConfigUrl -OutFile $sysmonConfig -ErrorAction Stop

    Write-Host "Installing Sysmon with configuration..."
    Start-Process -FilePath "$sysmonDir\$sysmonExe" -ArgumentList "-accepteula -i `"$sysmonConfig`"" -Verb RunAs -Wait -ErrorAction Stop

    Write-Host "Sysmon installed successfully."
} catch {
    Write-Error "Failed to install Sysmon: $_"
}

# Install Python 3.10.11 (32-bit)
$pythonInstallerUrl = "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe"
$installerPath = "$env:TEMP\python-3.10.11.exe"
$pythonPath = "C:\Python\python.exe"
$pipPath = "C:\Python\Scripts\pip.exe"

try {
    Write-Host "Downloading Python 3.10.11 (32-bit)..."
    Invoke-WebRequest -Uri $pythonInstallerUrl -OutFile $installerPath -ErrorAction Stop

    Write-Host "Installing Python for all users..."
    Start-Process -FilePath $installerPath -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 TargetDir=C:\Python" -Wait -ErrorAction Stop

    if (Test-Path $pythonPath) {
        $pythonVersion = & $pythonPath --version
        Write-Host "✅ Python installed successfully: $pythonVersion"
    } else {
        Write-Error "❌ Python installation failed. $pythonPath not found."
        exit 1
    }

    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-Error "Failed to install Python: $_"
    exit 1
}

# Install Pillow
try {
    Write-Host "Installing Pillow..."
    & $pipPath install Pillow

    $pillowCheck = & $pipPath show Pillow
    if ($pillowCheck) {
        $pillowVersion = ($pillowCheck | Where-Object { $_ -match "Version:" }) -replace "Version: ", ""
        Write-Host "✅ Pillow installed successfully: $pillowVersion"
    } else {
        Write-Error "❌ Pillow installation failed."
    }
} catch {
    Write-Error "Failed to install Pillow: $_"
}

# Download CAPE Agent
$agentUrl = "https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py"
$agentDest = "C:\cape_agent.pyw"

try {
    Write-Host "Downloading CAPE agent..."
    Invoke-WebRequest -Uri $agentUrl -OutFile $agentDest -ErrorAction Stop

    if (-not (Test-Path $agentDest)) {
        Write-Error "❌ CAPE agent download failed. $agentDest not found."
        exit 1
    }

    # Create Scheduled Task
    $taskName = "CAPE_Agent"
    $action = New-ScheduledTaskAction -Execute "pythonw.exe" -Argument "`"$agentDest`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger

    Write-Host "Registering scheduled task '$taskName'..."
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop

    Write-Host "✅ CAPE agent configured to run at logon with highest privileges."
} catch {
    Write-Error "Failed to configure CAPE agent: $_"
}

# Prompt for restart
Write-Host "A system restart is required to apply changes. Restart now? (Y/N)"
$response = Read-Host
if ($response -eq 'Y' -or $response -eq 'y') {
    Restart-Computer -Force
} else {
    Write-Host "Please restart the system manually to apply changes."
}

Stop-Transcript