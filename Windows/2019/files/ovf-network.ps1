# Applies the network.* vApp properties from the OVF environment ISO
# (Cloudbase-Init local script; runs once per instance-id). Empty properties
# leave DHCP/router discovery untouched. Every value is validated before any
# adapter change, so a malformed property can never strand the clone without
# networking, and the script always exits 0 so a parse problem never fails
# the Cloudbase-Init run.
$ErrorActionPreference = 'Stop'

function Test-OvfIpAddress {
	param([string]$Value, [System.Net.Sockets.AddressFamily]$Family)
	$parsed = $null
	if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $false }
	return $parsed.AddressFamily -eq $Family
}

function Test-OvfCidr {
	param([string]$Value, [System.Net.Sockets.AddressFamily]$Family, [int]$MaxPrefix)
	$parts = $Value -split '/', 2
	if ($parts.Count -ne 2) { return $false }
	$prefix = 0
	if (-not [int]::TryParse($parts[1], [ref]$prefix)) { return $false }
	if ($prefix -lt 0 -or $prefix -gt $MaxPrefix) { return $false }
	return (Test-OvfIpAddress -Value $parts[0] -Family $Family)
}

try {
	$xmlPath = $null
	foreach ($drive in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5')) {
		$candidate = Join-Path $drive.DeviceID 'ovf-env.xml'
		if (Test-Path -Path $candidate) {
			$xmlPath = $candidate
			break
		}
	}
	if (-not $xmlPath) {
		Write-Output 'ovf-network: no ovf-env.xml CD found; nothing to do.'
		exit 0
	}

	[xml]$doc = Get-Content -Path $xmlPath -Raw
	$props = @{}
	foreach ($node in $doc.SelectNodes('//*[local-name()="Property"]')) {
		$key = $node.GetAttribute('key', 'http://schemas.dmtf.org/ovf/environment/1')
		if (-not $key) { $key = $node.GetAttribute('key') }
		$value = $node.GetAttribute('value', 'http://schemas.dmtf.org/ovf/environment/1')
		if (-not $value) { $value = $node.GetAttribute('value') }
		if ($key) { $props[$key] = $value.Trim() }
	}

	$ip4 = $props['network.ip4']
	$gw4 = $props['network.gw4']
	$ip6 = $props['network.ip6']
	$gw6 = $props['network.gw6']
	$dns = @()
	if ($props['network.dns']) { $dns = $props['network.dns'] -split '[,\s]+' | Where-Object { $_ } }
	$search = @()
	if ($props['network.domain']) { $search = $props['network.domain'] -split '[,\s]+' | Where-Object { $_ } }

	if (-not ($ip4 -or $gw4 -or $ip6 -or $gw6 -or $dns -or $search)) {
		Write-Output 'ovf-network: no network properties set; keeping DHCP.'
		exit 0
	}

	# Validation pass: reject everything before touching the adapter.
	$v4 = [System.Net.Sockets.AddressFamily]::InterNetwork
	$v6 = [System.Net.Sockets.AddressFamily]::InterNetworkV6
	$invalid = @()
	if ($ip4 -and -not (Test-OvfCidr -Value $ip4 -Family $v4 -MaxPrefix 32)) { $invalid += "network.ip4=$ip4" }
	if ($gw4 -and -not (Test-OvfIpAddress -Value $gw4 -Family $v4)) { $invalid += "network.gw4=$gw4" }
	if ($ip6 -and -not (Test-OvfCidr -Value $ip6 -Family $v6 -MaxPrefix 128)) { $invalid += "network.ip6=$ip6" }
	if ($gw6 -and -not (Test-OvfIpAddress -Value $gw6 -Family $v6)) { $invalid += "network.gw6=$gw6" }
	foreach ($server in $dns) {
		$parsed = $null
		if (-not [System.Net.IPAddress]::TryParse($server, [ref]$parsed)) { $invalid += "network.dns=$server" }
	}
	if ($invalid.Count -gt 0) {
		Write-Output "ovf-network: ignoring invalid values, keeping current configuration: $($invalid -join '; ')"
		exit 0
	}

	# Virtual NICs are not always reported as physical, so do not filter on
	# -Physical; take the lowest ifIndex adapter.
	$adapter = Get-NetAdapter | Sort-Object -Property ifIndex | Select-Object -First 1
	if (-not $adapter) {
		Write-Output 'ovf-network: no network adapter found.'
		exit 0
	}
	$ifIndex = $adapter.ifIndex

	if ($ip4) {
		$address, $prefix = $ip4 -split '/', 2
		Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Disabled
		Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
			Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
		Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
			Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
		New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $address -PrefixLength ([int]$prefix) | Out-Null
		if ($gw4) {
			New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $gw4 | Out-Null
		}
		Write-Output "ovf-network: applied IPv4 $ip4 (gateway: $gw4)"
	}

	if ($ip6) {
		$address, $prefix = $ip6 -split '/', 2
		Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv6 -RouterDiscovery Disabled
		Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -PrefixOrigin Manual -ErrorAction SilentlyContinue |
			Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
		Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
			Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
		New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $address -PrefixLength ([int]$prefix) | Out-Null
		if ($gw6) {
			New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '::/0' -NextHop $gw6 | Out-Null
		}
		Write-Output "ovf-network: applied IPv6 $ip6 (gateway: $gw6)"
	}

	if ($dns.Count -gt 0) {
		Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dns
		Write-Output "ovf-network: applied DNS servers $($dns -join ', ')"
	}
	if ($search.Count -gt 0) {
		Set-DnsClientGlobalSetting -SuffixSearchList $search
		Write-Output "ovf-network: applied DNS search list $($search -join ', ')"
	}
} catch {
	Write-Output "ovf-network: error: $_"
}
exit 0
