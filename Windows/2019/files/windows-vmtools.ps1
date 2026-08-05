# Installs VMware Tools from the ESXi-provided tools ISO mounted at E: so the
# vmxnet3 driver comes up and Packer can reach the guest over WinRM.
$ErrorActionPreference = 'Stop'

$setup = 'E:\setup64.exe'
if (-not (Test-Path -Path $setup)) {
	throw "VMware Tools setup not found at $setup"
}

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
