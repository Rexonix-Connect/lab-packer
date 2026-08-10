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
	$parsed = [version]([regex]::Match($toolsVersion, '^\d+(\.\d+){1,3}').Value)
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
$hardeningChecks = @(
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters'; Name = 'RequireSecuritySignature'; Expected = 1 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'LmCompatibilityLevel'; Expected = 5 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'RunAsPPL'; Expected = 1 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'; Name = 'UseLogonCredential'; Expected = 0 },
	@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; Name = 'EnableMulticast'; Expected = 0 },
	@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server'; Name = 'Enabled'; Expected = 0 }
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

Write-Output '> Verification finished.'
