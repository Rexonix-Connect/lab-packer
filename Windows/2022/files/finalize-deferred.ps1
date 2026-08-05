# Deferred template hardening.
# Runs as a one-shot SYSTEM scheduled task, detached from Packer's WinRM
# session: every WinRM request re-authenticates, so re-hardening WinRM or
# disabling the build account from inside the session would cut the very
# connection Packer uses to deliver the shutdown command.
Start-Sleep -Seconds 15

$ErrorActionPreference = 'Continue'

winrm set winrm/config/service '@{AllowUnencrypted="false"}'
winrm set winrm/config/service/auth '@{Basic="false"}'
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -ErrorAction SilentlyContinue

# Disabled rather than deleted; clone customization manages accounts.
net user vagrant /active:no

# Remove the finalize scripts and this task itself from the template.
Remove-Item -Force -ErrorAction SilentlyContinue `
	'C:\Windows\Temp\packer-finalize-template.ps1', `
	'C:\Windows\Temp\packer-finalize-deferred.ps1'
schtasks.exe /Delete /TN 'packer-finalize-deferred' /F

# Always power off, even if a hardening step above reported an error.
shutdown /s /t 5 /f /d p:4:1 /c "Packer template finalize"
