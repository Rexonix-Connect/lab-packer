# Applies the identity vApp properties (username, password, public-keys)
# from the OVF environment ISO (Cloudbase-Init local script; runs once per
# instance-id). The stock Cloudbase-Init user plugins are intentionally not
# used: they set a generated random password whenever the metadata carries
# none, which would break the documented Administrator break-glass login on
# every form deployment. Here empty fields change nothing, and the script
# always exits 0 so a bad value never fails the Cloudbase-Init run.
$ErrorActionPreference = 'Stop'

$reservedUsernames = @('root', 'vagrant', 'recovery', 'administrator')

function Split-OvfPublicKeys {
	param([string]$Value)
	# Keys are separated by newlines or commas; a comma only splits where the
	# next token starts a key type (ssh-*, ecdsa-*, sk-*), so commas inside
	# an options prefix such as from="a,b" do not break a key apart.
	$keys = @()
	foreach ($line in ($Value -split "`r?`n")) {
		foreach ($part in ($line -split ',\s*(?=(?:ssh|ecdsa|sk)-)')) {
			$part = $part.Trim(" `t,".ToCharArray())
			if ($part) { $keys += $part }
		}
	}
	return $keys
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
		Write-Output 'ovf-identity: no ovf-env.xml CD found; nothing to do.'
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

	$username = $props['username']
	$password = $props['password']
	$keys = @()
	if ($props['public-keys']) { $keys = @(Split-OvfPublicKeys -Value $props['public-keys']) }

	if (-not ($username -or $password -or $keys.Count -gt 0)) {
		Write-Output 'ovf-identity: no identity properties set; nothing to do.'
		exit 0
	}

	# Default target: the built-in Administrator (RID 500), whatever its name.
	$builtin = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' } | Select-Object -First 1
	$target = if ($builtin) { $builtin.Name } else { $null }
	if (-not $target) {
		Write-Output 'ovf-identity: built-in Administrator (RID 500) not found; only an explicit username can be targeted'
	}

	if ($username -and $username.ToLower() -ne 'administrator') {
		if ($username -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,19}$' -or $reservedUsernames -contains $username.ToLower()) {
			Write-Output "ovf-identity: ignoring invalid or reserved username '$username'"
		} elseif (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
			$target = $username
		} elseif ($password -or $keys.Count -gt 0) {
			# Keys-only deployments get a random throwaway password; the GUID
			# suffix keeps it compliant with any complexity policy.
			$initial = if ($password) { $password } else { [guid]::NewGuid().ToString('N') + 'aA1!' }
			New-LocalUser -Name $username -Password (ConvertTo-SecureString $initial -AsPlainText -Force) `
				-PasswordNeverExpires -AccountNeverExpires | Out-Null
			$target = $username
			Write-Output "ovf-identity: created user '$username'"
		} else {
			Write-Output "ovf-identity: not creating user '$username' without a password or SSH keys"
		}
		if ($target -eq $username) {
			# Administrators group by well-known SID, immune to localization.
			Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $username -ErrorAction SilentlyContinue
		}
	}

	if ($password) {
		if ($target) {
			Set-LocalUser -Name $target -Password (ConvertTo-SecureString $password -AsPlainText -Force)
			Write-Output "ovf-identity: password set for '$target'"
		} else {
			Write-Output 'ovf-identity: no target account available; password not applied'
		}
	}

	if ($keys.Count -gt 0) {
		# Members of Administrators (which covers the target account either
		# way) authenticate against this file under the default sshd_config,
		# and sshd requires it to be readable by Administrators/SYSTEM only.
		# OpenSSH Server is not preinstalled; the file takes effect once the
		# operator enables it.
		$sshDir = Join-Path $env:ProgramData 'ssh'
		New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
		$akPath = Join-Path $sshDir 'administrators_authorized_keys'
		[IO.File]::WriteAllLines($akPath, [string[]]$keys, (New-Object System.Text.UTF8Encoding($false)))
		icacls.exe $akPath /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
		Write-Output "ovf-identity: wrote $($keys.Count) SSH key(s) to $akPath"
	}
} catch {
	Write-Output "ovf-identity: error: $_"
}
exit 0
