# Installs Cloudbase-Init (pinned version from CLOUDBASE_INIT_VERSION) and
# applies the repository configuration and the OVF identity/network local
# scripts.
# The service first runs on the next boot, which is the first boot of a
# deployed clone - the build itself never reboots after this step.
$ErrorActionPreference = 'Stop'

$version = $env:CLOUDBASE_INIT_VERSION
if (-not $version) {
	throw 'CLOUDBASE_INIT_VERSION is not set'
}
$versionUnderscore = $version -replace '\.', '_'
$url = "https://github.com/cloudbase/cloudbase-init/releases/download/$version/CloudbaseInitSetup_${versionUnderscore}_x64.msi"
$msi = 'C:\Windows\Temp\CloudbaseInitSetup_x64.msi'

Write-Output "> Downloading Cloudbase-Init $version ..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing

Write-Output '> Installing Cloudbase-Init ...'
$process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /qn /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1" -Wait -PassThru
if ($process.ExitCode -ne 0) {
	throw "Cloudbase-Init installer exited with $($process.ExitCode)"
}
Remove-Item -Force $msi

$base = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
Write-Output '> Applying configuration ...'
Copy-Item -Force 'C:\Windows\Temp\cloudbase-init.conf' "$base\conf\cloudbase-init.conf"
# No sysprep in these builds: the unattend pass never runs, so mirror the main
# configuration there to keep the file consistent rather than misleading.
Copy-Item -Force 'C:\Windows\Temp\cloudbase-init.conf' "$base\conf\cloudbase-init-unattend.conf"
New-Item -ItemType Directory -Force -Path "$base\LocalScripts" | Out-Null
Copy-Item -Force 'C:\Windows\Temp\ovf-identity.ps1' "$base\LocalScripts\ovf-identity.ps1"
Copy-Item -Force 'C:\Windows\Temp\ovf-network.ps1' "$base\LocalScripts\ovf-network.ps1"
Remove-Item -Force 'C:\Windows\Temp\cloudbase-init.conf', 'C:\Windows\Temp\ovf-identity.ps1', 'C:\Windows\Temp\ovf-network.ps1'

$service = Get-Service -Name 'cloudbase-init'
if ($service.StartType -ne 'Automatic') {
	Set-Service -Name 'cloudbase-init' -StartupType Automatic
}
Write-Output '> Cloudbase-Init installed and configured.'
