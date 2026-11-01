# Turns on Windows Search on the test machine, as a normal Windows has it, and waits until it knows a new file.
# Asks the index directly too, so a failure says why and not only that it failed.
param([string]$Out)

New-Item -ItemType Directory -Force $Out | Out-Null
function Say([string]$text) { Write-Output $text; Add-Content -Path (Join-Path $Out 'suchdienst.txt') -Value $text }

function Ask([string]$sql) {
    $connection = New-Object Data.OleDb.OleDbConnection "Provider=Search.CollatorDSO;Extended Properties='Application=Windows';"
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        $command.CommandTimeout = 5
        $reader = $command.ExecuteReader()
        $rows = @()
        while ($reader.Read()) { $rows += [string]$reader.GetValue(0) }
        $reader.Close()
        return $rows
    } finally {
        $connection.Dispose()
    }
}

$sample = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'NotchSuchprobe 100%.txt'
Set-Content -Path $sample -Value 'Boring Notch'

$query = "SELECT TOP 6 System.ItemPathDisplay FROM SystemIndex WHERE SCOPE='file:' AND System.FileName LIKE '%NotchSuchprobe%' ORDER BY System.DateModified DESC"
$escaped = "SELECT TOP 6 System.ItemPathDisplay FROM SystemIndex WHERE SCOPE='file:' AND System.FileName LIKE '%100[%]%' ORDER BY System.DateModified DESC"

Say ("Service before: " + (Get-Service WSearch -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Status) $($_.StartType)" }))
try {
    Ask $query | Out-Null
    Say 'Query with the service as it was: answered'
} catch {
    Say ("Query with the service as it was: " + $_.Exception.InnerException.Message + " " + $_.Exception.InnerException.ErrorCode)
}

try {
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        $feature = Install-WindowsFeature Search-Service
        Say ("Feature: success=" + $feature.Success + " restart=" + $feature.RestartNeeded)
    }
    Set-Service WSearch -StartupType Automatic
    Start-Service WSearch
    Say ("Service now: " + (Get-Service WSearch).Status)
} catch {
    Say ("Could not start the service: " + $_)
}

$found = $false
for ($i = 0; $i -lt 40 -and -not $found; $i++) {
    Start-Sleep -Seconds 5
    try {
        $rows = @(Ask $query)
        if ($rows -contains $sample) { $found = $true }
        Say "After $(($i + 1) * 5) s: $($rows.Count) rows"
    } catch {
        Say ("After $(($i + 1) * 5) s: " + $_.Exception.InnerException.Message + " " + $_.Exception.InnerException.ErrorCode)
    }
}
Say "The index knows the file: $found"

if ($found) {
    try {
        Say ("A literal % through bracket escaping finds it: " + ((@(Ask $escaped)) -contains $sample))
    } catch {
        Say ("Bracket escaping failed: " + $_.Exception.InnerException.Message + " " + $_.Exception.InnerException.ErrorCode)
    }
}
