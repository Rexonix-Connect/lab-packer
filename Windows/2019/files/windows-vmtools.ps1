# Installs VMware Tools from the mounted tools ISO so the vmxnet3 driver comes
# up and Packer can reach the guest over WinRM. The installer is located by
# scanning the CD drives rather than assuming a drive letter, and either
# setup64.exe (older / ESXi-bundled ISOs) or setup.exe (VMware Tools 13.x,
# which dropped the 32-bit installer and ships a single 64-bit setup.exe) is
# accepted. The Tools ISO is identified by its VMware Tools folder so the
# Windows installation media's own setup.exe is never picked by mistake.
$ErrorActionPreference = 'Stop'

$setup = $null
foreach ($drive in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5')) {
	$root = $drive.DeviceID
	if (-not (Test-Path -Path (Join-Path $root 'Program Files\VMware\VMware Tools'))) {
		continue
	}
	foreach ($name in @('setup64.exe', 'setup.exe')) {
		$candidate = Join-Path $root $name
		if (Test-Path -Path $candidate) {
			$setup = $candidate
			break
		}
	}
	if ($setup) { break }
}
if (-not $setup) {
	throw 'VMware Tools installer (setup64.exe or setup.exe) not found on any CD drive'
}
Write-Output "Using VMware Tools installer: $setup"

for ($attempt = 1; $attempt -le 5; $attempt++) {
	Write-Output "Installing VMware Tools (attempt $attempt) ..."
	Start-Process -FilePath $setup -ArgumentList '/S /v "/qn REBOOT=R"' -Wait
	Start-Sleep -Seconds 10
	$service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
	if ($service -and $service.Status -eq 'Running') {
		Write-Output 'VMware Tools service is running.'
		exit 0
	}
}

throw 'VMware Tools service failed to start after installation'
