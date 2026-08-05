# Final template cleanup script.
# Uploaded by the file provisioner and executed by `shutdown_command`. Only
# WinRM-session-safe steps run here; WinRM re-hardening, build-account
# disabling and the actual power-off happen in finalize-deferred.ps1, which
# this script launches as a detached SYSTEM scheduled task (changing WinRM
# auth or the build account from inside the session would break the session
# itself, since every WinRM request re-authenticates).
$ErrorActionPreference = 'Stop'

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
Get-ChildItem -Path 'C:\Windows\Temp' -Exclude 'packer-finalize-template.ps1', 'packer-finalize-deferred.ps1' | Remove-Item -Recurse -Force
Remove-Item -Recurse -Force 'C:\Users\*\AppData\Local\Temp\*'
wevtutil el | ForEach-Object { wevtutil cl $_ }
$ErrorActionPreference = 'Stop'

Write-Output '> Scheduling deferred hardening and shutdown ...'
schtasks.exe /Create /TN 'packer-finalize-deferred' /SC ONCE /ST 00:00 /RU 'SYSTEM' /RL HIGHEST /F /TR 'powershell.exe -ExecutionPolicy Bypass -File C:\Windows\Temp\packer-finalize-deferred.ps1'
if ($LASTEXITCODE -ne 0) {
	throw 'Failed to create the deferred finalize task'
}
schtasks.exe /Run /TN 'packer-finalize-deferred'
if ($LASTEXITCODE -ne 0) {
	throw 'Failed to start the deferred finalize task'
}

Write-Output '> Deferred finalize scheduled; the guest will power off shortly.'
