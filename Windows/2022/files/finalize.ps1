# Final template hardening script.
# Uploaded by the file provisioner and executed by `shutdown_command` at the
# very end of the Packer build, so the WinRM communicator remains available
# until this point.
$ErrorActionPreference = 'Stop'

Write-Output '> Re-hardening WinRM ...'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'
winrm set winrm/config/service/auth '@{Basic="false"}'
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -ErrorAction SilentlyContinue

Write-Output '> Removing autologon credentials ...'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0'
Remove-ItemProperty -Path $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name 'DefaultUserName' -ErrorAction SilentlyContinue

Write-Output '> Removing unattend answer files ...'
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue `
	'C:\Windows\Panther\unattend.xml', `
	'C:\Windows\Panther\Unattend', `
	'C:\Windows\System32\Sysprep\unattend.xml', `
	'C:\autounattend.xml'

Write-Output '> Cleaning update cache, temporary files and event logs ...'
$ErrorActionPreference = 'SilentlyContinue'
Stop-Service -Name 'wuauserv' -Force
Remove-Item -Recurse -Force 'C:\Windows\SoftwareDistribution\Download\*'
Get-ChildItem -Path 'C:\Windows\Temp' -Exclude 'packer-finalize-template.ps1' | Remove-Item -Recurse -Force
Remove-Item -Recurse -Force 'C:\Users\*\AppData\Local\Temp\*'
wevtutil el | ForEach-Object { wevtutil cl $_ }
$ErrorActionPreference = 'Stop'

# Disabled rather than deleted: deleting the account that owns the live WinRM
# session is unreliable, and clone customization manages accounts anyway.
Write-Output '> Disabling the vagrant provisioning account ...'
net user vagrant /active:no

Write-Output '> Shutting down ...'
shutdown /s /t 10 /f /d p:4:1 /c "Packer template finalize"
