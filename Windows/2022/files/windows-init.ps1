# Prepares the freshly installed guest for the Packer WinRM communicator.
# Everything loosened here is re-hardened by the finalize script.
$ErrorActionPreference = 'Stop'

# WinRM only accepts connections on Private/Domain networks; wait until the
# connection profile is identified, then force it to Private.
Write-Output 'Setting the network connection profile to Private ...'
$profile = Get-NetConnectionProfile
while ($profile.Name -eq 'Identifying...') {
	Start-Sleep -Seconds 10
	$profile = Get-NetConnectionProfile
}
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Packer's WinRM communicator defaults to basic authentication over HTTP.
Write-Output 'Configuring WinRM for the build ...'
winrm quickconfig -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes

# Grant the local build account a full admin token over WinRM while keeping
# UAC enabled (instead of disabling LUA altogether).
Write-Output 'Allowing remote administration for local accounts ...'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -PropertyType DWord -Value 1 -Force | Out-Null

# The unattend autologon is only needed for this first logon.
Write-Output 'Resetting the autologon count ...'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoLogonCount' -Value 0
