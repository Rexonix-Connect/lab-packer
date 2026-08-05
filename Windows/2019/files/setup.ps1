# Verifies the built guest before it is finalized into a template.
$ErrorActionPreference = 'Stop'

Write-Output '> Verifying VMware Tools service ...'
$service = Get-Service -Name 'VMTools'
if ($service.Status -ne 'Running') {
	throw 'VMware Tools service is not running'
}

Write-Output '> Verifying no software updates are pending ...'
$searcher = (New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateSearcher()
$result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
$pending = @($result.Updates | ForEach-Object { $_.Title } | Where-Object { $_ -notlike '*Preview*' })
if ($pending.Count -gt 0) {
	$pending | ForEach-Object { Write-Output ">   pending: $_" }
	throw 'Software updates are still pending after the windows-update pass'
}

Write-Output '> Verification finished.'
