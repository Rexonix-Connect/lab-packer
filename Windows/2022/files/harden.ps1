# Baseline OS hardening baked into the template. Every setting here is a
# well-established server-hardening default that does not impair normal use of
# a lab VM; each is a single registry value or service state, so any of them is
# trivially reverted per-VM if a specific lab needs the legacy behaviour (see
# README "Windows template hardening"). Deploy-time personalization runs
# through Cloudbase-Init, not WinRM/SMB, so none of this affects cloning.
$ErrorActionPreference = 'Stop'

function Set-RegValue {
	param([string]$Path, [string]$Name, [Parameter(Mandatory)]$Value,
		[string]$Type = 'DWord')
	if (-not (Test-Path -Path $Path)) {
		New-Item -Path $Path -Force | Out-Null
	}
	New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

Write-Output '> SMB signing required (server and client) ...'
$srv = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters'
$wrk = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManWorkstation\Parameters'
Set-RegValue -Path $srv -Name 'RequireSecuritySignature' -Value 1
Set-RegValue -Path $srv -Name 'EnableSecuritySignature' -Value 1
Set-RegValue -Path $wrk -Name 'RequireSecuritySignature' -Value 1
Set-RegValue -Path $wrk -Name 'EnableSecuritySignature' -Value 1

Write-Output '> Removing SMBv1 ...'
Set-RegValue -Path $srv -Name 'SMB1' -Value 0
# The optional feature is already absent on current builds; tolerate that.
try {
	$smb1 = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -ErrorAction Stop
	if ($smb1.State -eq 'Enabled') {
		Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -ErrorAction Stop | Out-Null
	}
} catch {
	Write-Output "  (SMB1 optional feature not adjustable: $($_.Exception.Message))"
}

Write-Output '> NTLMv2 only, refuse LM and NTLMv1 ...'
# Level 5 still permits NTLMv2, which standalone WinRM/Negotiate uses, so the
# build and Ansible-over-WinRM keep working; only LM and NTLMv1 are refused.
Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -Value 5
Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'NoLMHash' -Value 1

Write-Output '> Disabling WDigest cleartext credential caching ...'
Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name 'UseLogonCredential' -Value 0

Write-Output '> Enabling LSA protection (RunAsPPL) ...'
# Takes effect after the finalize reboot; protects LSASS from credential dumps.
Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 1

Write-Output '> Disabling LLMNR and NetBIOS name resolution ...'
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -Value 0
# NetbiosOptions=2 disables NetBIOS over TCP/IP on every current interface and
# on the template default that new NICs inherit.
Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_{Default}' -Name 'NetbiosOptions' -Value 2
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' |
	Where-Object { $_.PSChildName -like 'Tcpip_*' } |
	ForEach-Object { Set-RegValue -Path $_.PSPath -Name 'NetbiosOptions' -Value 2 }

Write-Output '> Disabling the Print Spooler ...'
# Removes the PrintNightmare-class attack surface; lab VMs rarely print, and
# Set-Service re-enables it in seconds if one does.
Stop-Service -Name 'Spooler' -Force -ErrorAction SilentlyContinue
Set-Service -Name 'Spooler' -StartupType Disabled

Write-Output '> Restricting Schannel to TLS 1.2+ and dropping weak ciphers ...'
$schannel = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
foreach ($proto in @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
	foreach ($role in @('Server', 'Client')) {
		$path = "$schannel\Protocols\$proto\$role"
		Set-RegValue -Path $path -Name 'Enabled' -Value 0
		Set-RegValue -Path $path -Name 'DisabledByDefault' -Value 1
	}
}
foreach ($proto in @('TLS 1.2')) {
	foreach ($role in @('Server', 'Client')) {
		$path = "$schannel\Protocols\$proto\$role"
		Set-RegValue -Path $path -Name 'Enabled' -Value 1
		Set-RegValue -Path $path -Name 'DisabledByDefault' -Value 0
	}
}
foreach ($cipher in @('RC4 40/128', 'RC4 56/128', 'RC4 64/128', 'RC4 128/128', 'DES 56/56', 'Triple DES 168')) {
	Set-RegValue -Path "$schannel\Ciphers\$cipher" -Name 'Enabled' -Value 0
}

Write-Output '> Enabling PowerShell script block logging ...'
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Name 'EnableScriptBlockLogging' -Value 1

Write-Output '> Enabling a minimal security audit policy ...'
foreach ($sub in @('Logon', 'Logoff', 'Special Logon', 'User Account Management',
		'Security Group Management', 'Process Creation', 'Audit Policy Change',
		'Authentication Policy Change', 'Sensitive Privilege Use')) {
	& auditpol.exe /set /subcategory:"$sub" /success:enable /failure:enable | Out-Null
}
# Command line in process-creation events makes the audit trail actionable.
Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -Name 'ProcessCreationIncludeCmdLine_Enabled' -Value 1

Write-Output '> Configuring Windows Update to auto-install with a reboot window ...'
# Server does not self-install updates by default; keep deployed clones patching
# known vulnerabilities. AUOptions=4 = auto download and scheduled install.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-RegValue -Path $au -Name 'NoAutoUpdate' -Value 0
Set-RegValue -Path $au -Name 'AUOptions' -Value 4
Set-RegValue -Path $au -Name 'ScheduledInstallDay' -Value 0
Set-RegValue -Path $au -Name 'ScheduledInstallTime' -Value 3
Set-RegValue -Path $au -Name 'AllowMUUpdateService' -Value 1

Write-Output '> Hardening finished.'
