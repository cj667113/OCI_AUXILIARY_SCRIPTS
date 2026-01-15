$ErrorActionPreference = "Stop"

$Namespace     = "production"
$MetricName    = "disk_used_percent"
$ResourceGroup = "windows"
$Hostname      = $env:COMPUTERNAME.ToLower()

function Get-ImdsInstance() {
  Invoke-RestMethod `
    -Headers @{ Authorization = "Bearer Oracle" } `
    -Method GET `
    -Uri "http://169.254.169.254/opc/v2/instance/"
}

function Require-OciCli() {
  if (-not (Get-Command "oci" -ErrorAction SilentlyContinue)) {
    throw "OCI CLI not found in PATH"
  }
}

Require-OciCli

$imds          = Get-ImdsInstance
$CompartmentId = $imds.compartmentId
$Region        = $imds.canonicalRegionName

$RealmDomain   = $imds.regionInfo.realmDomainComponent
$Endpoint      = "https://telemetry-ingestion.$Region.$RealmDomain"

$disks   = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
$nowUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$metrics = @()

foreach ($d in $disks) {
  if (-not $d.Size -or $d.Size -le 0) { continue }

  $pctUsed = (($d.Size - $d.FreeSpace) / $d.Size) * 100
  if ([double]::IsNaN($pctUsed) -or [double]::IsInfinity($pctUsed)) { continue }

  $metrics += @{
    compartmentId = $CompartmentId
    namespace     = $Namespace
    name          = $MetricName
    resourceGroup = $ResourceGroup
    dimensions    = @{
      drive    = $d.DeviceID
      hostname = $Hostname
    }
    metadata   = @{ unit = "percent" }
    datapoints = @(@{
      timestamp = $nowUtc
      value     = [Math]::Round($pctUsed, 3)
    })
  }
}

if ($metrics.Count -eq 0) { exit 0 }

# Wrap $metrics in an array
$jsonPath = Join-Path $env:TEMP "oci_disk_metrics.json"
$json = ConvertTo-Json -InputObject @($metrics) -Depth 10
[System.IO.File]::WriteAllText($jsonPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "JSON Payload:"
Get-Content $jsonPath -Raw

Write-Host "`nPosting metrics to OCI..."
& oci monitoring metric-data post `
  --metric-data "file://$jsonPath" `
  --endpoint $Endpoint `
  --auth instance_principal | Out-String | Write-Host