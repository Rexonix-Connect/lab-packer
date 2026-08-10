# Verifies the built guest before it is finalized into a template.
$ErrorActionPreference = 'Stop'

Write-Output '> Verifying VMware Tools service ...'
$service = Get-Service -Name 'VMTools'
if ($service.Status -ne 'Running') {
	throw 'VMware Tools service is not running'
}

$minimumTools = $env:MINIMUM_TOOLS_VERSION
if ($minimumTools) {
	Write-Output "> Verifying VMware Tools version >= $minimumTools ..."
	$toolsVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\VMware, Inc.\VMware Tools' -ErrorAction Stop).ProductVersion
	# ProductVersion can carry a build suffix (e.g. 13.1.0.25218885); compare on
	# the leading dotted-numeric portion only.
	$match = [regex]::Match([string]$toolsVersion, '^\d+(\.\d+){1,3}')
	if (-not $match.Success) {
		throw "Could not parse a version from VMware Tools ProductVersion '$toolsVersion'"
	}
	$parsed = [version]$match.Value
	if ($parsed -lt [version]$minimumTools) {
		throw "VMware Tools $toolsVersion is older than the required $minimumTools; refresh the pinned tools ISO"
	}
	Write-Output "  VMware Tools $toolsVersion"
}

Write-Output '> Verifying no software updates are pending ...'
$searcher = (New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateSearcher()
$result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
$pending = @($result.Updates | ForEach-Object { $_.Title } | Where-Object { $_ -notlike '*Preview*' })
if ($pending.Count -gt 0) {
	$pending | ForEach-Object { Write-Output ">   pending: $_" }
	throw 'Software updates are still pending after the windows-update pass'
}

Write-Output '> Verifying Cloudbase-Init ...'
$cbService = Get-Service -Name 'cloudbase-init'
if ($cbService.StartType -ne 'Automatic') {
	throw 'cloudbase-init service is not set to automatic start'
}
$cbBase = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
if (-not (Select-String -Path "$cbBase\conf\cloudbase-init.conf" -Pattern 'OvfService' -Quiet)) {
	throw 'cloudbase-init.conf does not contain the expected metadata services'
}
if (-not (Test-Path -Path "$cbBase\LocalScripts\ovf-network.ps1")) {
	throw 'ovf-network.ps1 local script is missing'
}
if (-not (Test-Path -Path "$cbBase\LocalScripts\ovf-identity.ps1")) {
	throw 'ovf-identity.ps1 local script is missing'
}

Write-Output '> Verifying OS hardening was applied ...'
# One assertion per control harden.ps1 sets, so the build fails if any did
# not take. Schannel protocol/cipher keys carry a space in the subkey name.
$schannel = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
$hardeningChecks = @(
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters'; Name = 'RequireSecuritySignature'; Expected = 1 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManWorkstation\Parameters'; Name = 'RequireSecuritySignature'; Expected = 1 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters'; Name = 'SMB1'; Expected = 0 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'LmCompatibilityLevel'; Expected = 5 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'NoLMHash'; Expected = 1 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'RunAsPPL'; Expected = 1 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'; Name = 'UseLogonCredential'; Expected = 0 },
	@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; Name = 'EnableMulticast'; Expected = 0 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_{Default}'; Name = 'NetbiosOptions'; Expected = 2 },
	@{ Path = "$schannel\Protocols\TLS 1.0\Server"; Name = 'Enabled'; Expected = 0 },
	@{ Path = "$schannel\Protocols\TLS 1.1\Server"; Name = 'Enabled'; Expected = 0 },
	@{ Path = "$schannel\Protocols\TLS 1.2\Server"; Name = 'Enabled'; Expected = 1 },
	@{ Path = "$schannel\Ciphers\RC4 128/128"; Name = 'Enabled'; Expected = 0 },
	@{ Path = "$schannel\Ciphers\Triple DES 168"; Name = 'Enabled'; Expected = 0 },
	@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Name = 'EnableScriptBlockLogging'; Expected = 1 },
	@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'; Name = 'ProcessCreationIncludeCmdLine_Enabled'; Expected = 1 },
	@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Expected = 0 },
	@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; Expected = 4 }
)
foreach ($check in $hardeningChecks) {
	$actual = (Get-ItemProperty -Path $check.Path -Name $check.Name -ErrorAction Stop).($check.Name)
	if ($actual -ne $check.Expected) {
		throw "hardening check failed: $($check.Path)\$($check.Name) is $actual, expected $($check.Expected)"
	}
}
if ((Get-Service -Name 'Spooler').StartType -ne 'Disabled') {
	throw 'Print Spooler is not disabled'
}
# NetBIOS-over-TCP/IP disabled on every currently-present interface too.
$nbtInterfaces = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' |
	Where-Object { $_.PSChildName -like 'Tcpip_*' }
foreach ($iface in $nbtInterfaces) {
	$opt = (Get-ItemProperty -Path $iface.PSPath -Name 'NetbiosOptions' -ErrorAction SilentlyContinue).NetbiosOptions
	if ($opt -ne 2) {
		throw "hardening check failed: $($iface.PSChildName) NetbiosOptions is $opt, expected 2"
	}
}
# The audit subcategory policy is stored outside the registry; confirm the
# Process Creation subcategory is auditing.
$auditProc = (& auditpol.exe /get /subcategory:'Process Creation') -join "`n"
if ($auditProc -notmatch 'Success') {
	throw 'Process Creation audit policy is not enabled'
}

Write-Output '> Verification finished.'
