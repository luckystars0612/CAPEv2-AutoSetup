# Disable Teredo
netsh interface teredo set state disabled

# Disable LLMNR via registry
$regPath = "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient"
$name = "EnableMulticast"
$value = 0

# Create key if it doesn't exist
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

# Set the registry value to disable LLMNR
New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force

Write-Host "LLMNR has been disabled. A reboot or gpupdate /force may be required."

# Enable "Restrict Internet communication"
#$regPath = "HKLM:\Software\Policies\Microsoft\Windows\System"
#$name = "EnableRestrictedInternet"
#$value = 1

# Create the key if it doesn't exist
#if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
#}

# Set the registry value
#New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force

#Write-Host '"Restrict Internet communication" has been enabled. A reboot or gpupdate /force may be required.'

# Disable Microsoft Defender Antivirus
$regPath = "HKLM:\Software\Policies\Microsoft\Windows Defender"
$name = "DisableAntiSpyware"
$value = 1

# Create the key if it doesn't exist
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

# Set the registry value
New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force

Write-Host "Microsoft Defender Antivirus has been disabled via registry. A reboot may be required."

# Disable Microsoft Defender Real-time Protection
$regPath = "HKLM:\Software\Policies\Microsoft\Windows Defender\Real-Time Protection"
$name = "DisableRealtimeMonitoring"
$value = 1

# Create the key if it doesn't exist
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

# Set the registry value
New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force

Write-Host "Real-time protection has been disabled. A reboot or gpupdate /force may be required."

# Disable Microsoft Store using registry (GPO equivalent)
$regPath = "HKLM:\Software\Policies\Microsoft\WindowsStore"
$name = "RemoveWindowsStore"
$value = 1

# Create the key if it doesn't exist
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

# Set the value to disable Microsoft Store
New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWORD -Force

Write-Host "Microsoft Store has been disabled. Reboot or run 'gpupdate /force' to apply."

# disable ransomware protection
Set-MpPreference -EnableControlledFolderAccess Disabled

Write-Host "Ransomware protection (Controlled Folder Access) has been disabled."

# disable network firewall
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False

Write-Host "Firewall has been disabled for Domain, Private, and Public profiles."

# Download Sysmon ZIP
Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile "Sysmon.zip"

# Extract Sysmon.zip
Expand-Archive -Path "Sysmon.zip" -DestinationPath ".\Sysmon" -Force

# Download sysmon config
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile ".\sysmonconfig.xml"

# Use Sysmon64 if on 64-bit system
Start-Process -FilePath ".\Sysmon\Sysmon64.exe" -ArgumentList "-accepteula -i sysmonconfig.xml" -Verb RunAs -Wait

Write-Host "Sysmon installed with SwiftOnSecurity configuration."

# ----------------------------
# Step 1: Download and install Python 3.10.x (32-bit)
# ----------------------------
$pythonInstaller = "$env:TEMP\python-3.10.11.exe"
$pythonUrl = "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe"

Write-Host "Downloading Python 3.10.11 (32-bit)..."
Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonInstaller

Write-Host "Installing Python for all users..."
Start-Process -FilePath $pythonInstaller -ArgumentList `
    "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1" -Wait

# Check if python.exe is now available
$pythonPath = (Get-Command python.exe -ErrorAction SilentlyContinue)?.Source
if (-not $pythonPath) {
    Write-Error "❌ Python installation failed or not in PATH."
    exit 1
}

# ----------------------------
# Step 2: Download the CAPE agent
# ----------------------------
$agentUrl = "https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py"
$agentDest = "C:\cape_agent.pyw"

Write-Host "Downloading CAPE agent..."
Invoke-WebRequest -Uri $agentUrl -OutFile $agentDest

# ----------------------------
# Step 3: Create Scheduled Task to Run Agent Silently at Logon
# ----------------------------
$taskName = "CAPE_Agent"
$action = New-ScheduledTaskAction -Execute "pythonw.exe" -Argument "`"$agentDest`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger

Write-Host "Registering scheduled task '$taskName'..."
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force

Write-Host "`n✅ CAPE agent is now configured to run silently at logon with highest privileges."


# Install Pillow via pip
Write-Host "Installing Pillow (Python imaging library)..."
pip install Pillow

# Optional: Verify install
if (pip show Pillow) {
    Write-Host "`n✅ Pillow installed successfully. CAPE can now take screenshots in the guest."
} else {
    Write-Error "❌ Pillow installation failed. Please check Python installation and pip."
}

