<#
.SYNOPSIS
    Groepeert bestanden met een gemeenschappelijke basisnaam in een eigen submap.

.DESCRIPTION
    Bepaalt per bestand een "basisnaam" door:
      1. de extensie te verwijderen;
      2. een duplicaatmarker zoals " (2)" of " (3)" te verwijderen;
      3. afsluitende volgnummers te verwijderen (bv. "-12", "_227464", " 1"),
         net zo lang tot er geen eindnummer meer is.
    Bestanden met dezelfde basisnaam vormen een groep. Alleen groepen met
    minimaal -MinCount bestanden (standaard 3) krijgen een eigen map; de
    bijbehorende bestanden worden daarheen verplaatst.

    STANDAARD DRY-RUN: er wordt niets verplaatst, alleen getoond wat er zou
    gebeuren. Voeg -Execute toe om de bestanden daadwerkelijk te verplaatsen.

.PARAMETER Path
    De map met de bestanden. Standaard de huidige map.

.PARAMETER MinCount
    Minimaal aantal bestanden dat een gemeenschappelijke naam moet hebben.
    Standaard 3.

.PARAMETER Execute
    Verplaatst de bestanden echt. Zonder deze schakelaar = dry-run.

.PARAMETER CaseSensitive
    Groepeer hoofdlettergevoelig. Standaard uit (aanbevolen).

.PARAMETER MergePrefix
    Eén of meer voorvoegsels die je in één map wilt samenvoegen, ongeacht de
    fijnere indeling. Alles waarvan de naam met zo'n voorvoegsel begint komt
    in een map met die naam. Bij overlap wint het langste voorvoegsel.

.EXAMPLE
    # Alle align-* bestanden samen in map "Align":
    .\Groepeer-Bestanden.ps1 -MergePrefix Align

.EXAMPLE
    # Meerdere families samenvoegen:
    .\Groepeer-Bestanden.ps1 -MergePrefix Align, Arrow, "Voortman Steel Group"

.EXAMPLE
    # Eerst kijken wat er zou gebeuren (verplaatst niets):
    .\Groepeer-Bestanden.ps1 -Path "C:\pad\naar\iconen"

.EXAMPLE
    # Daadwerkelijk uitvoeren:
    .\Groepeer-Bestanden.ps1 -Path "C:\pad\naar\iconen" -Execute
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [int]$MinCount = 3,
    [switch]$Execute,
    [switch]$CaseSensitive,
    [string[]]$MergePrefix = @()
)

$ErrorActionPreference = 'Stop'

# --- Basisnaam bepalen -------------------------------------------------------
function Get-BaseKey([string]$name) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $stem = $stem -replace '\s*\(\d+\)\s*$', ''          # " (2)" duplicaatmarker
    while ($true) {
        $new = $stem -replace '[\s_-]+\d+$', ''          # afsluitend volgnummer
        if ($new -eq $stem) { break }
        $stem = $new
    }
    return $stem.Trim()
}

# --- Mapnaam veilig maken voor Windows --------------------------------------
function Get-SafeFolderName([string]$folder) {
    $folder = $folder -replace '[<>:"/\\|?*]', '_'
    $folder = $folder.TrimEnd(' ', '.')
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = '_' }
    return $folder
}

# --- Voorbereiden ------------------------------------------------------------
$root = (Resolve-Path -LiteralPath $Path).Path
Write-Host "Map        : $root"
Write-Host "MinCount   : $MinCount"
Write-Host "Modus      : $(if ($Execute) { 'UITVOEREN (verplaatst bestanden)' } else { 'DRY-RUN (verplaatst niets)' })"
Write-Host ("-" * 60)

# Alleen bestanden in de bovenste laag; bestaande submappen worden genegeerd.
$scriptSelf = if ($PSCommandPath) { [System.IO.Path]::GetFileName($PSCommandPath) } else { '' }
$files = Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -ne $scriptSelf }

# --- Groeperen ---------------------------------------------------------------
# Sleutel = basisnaam (standaard hoofdletter-ongevoelig via lowercase-sleutel).
$groups  = @{}   # sleutel -> lijst met FileInfo
$casings = @{}   # sleutel -> hashtable(exacte basisnaam -> aantal), voor mooiste mapnaam

foreach ($f in $files) {
    $base = Get-BaseKey $f.Name
    if ([string]::IsNullOrWhiteSpace($base)) { continue }

    # Optioneel: voorvoegsels samenvoegen tot één groep (langste match wint).
    foreach ($p in ($MergePrefix | Sort-Object { $_.Length } -Descending)) {
        if ($base.ToLowerInvariant().StartsWith($p.ToLowerInvariant())) { $base = $p; break }
    }

    $key = if ($CaseSensitive) { $base } else { $base.ToLowerInvariant() }

    if (-not $groups.ContainsKey($key)) {
        $groups[$key]  = New-Object System.Collections.ArrayList
        $casings[$key] = @{}
    }
    [void]$groups[$key].Add($f)
    if ($casings[$key].ContainsKey($base)) { $casings[$key][$base]++ }
    else { $casings[$key][$base] = 1 }
}

# --- Plan opstellen ----------------------------------------------------------
$plan = @()   # objecten met FolderName + Files
foreach ($key in $groups.Keys) {
    $members = $groups[$key]
    if ($members.Count -lt $MinCount) { continue }
    # Mooiste mapnaam = meest voorkomende exacte schrijfwijze van de basisnaam.
    $display = ($casings[$key].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    $plan += [pscustomobject]@{
        FolderName = Get-SafeFolderName $display
        Files      = ($members | Sort-Object Name)
    }
}
$plan = $plan | Sort-Object { $_.Files.Count } -Descending

# --- Overzicht tonen ---------------------------------------------------------
$totalMove = 0
foreach ($grp in $plan) { $totalMove += $grp.Files.Count }
Write-Host ("Aan te maken mappen : {0}" -f $plan.Count)
Write-Host ("Te verplaatsen      : {0}" -f $totalMove)
Write-Host ("Blijft los staan    : {0}" -f ($files.Count - $totalMove))
Write-Host ("-" * 60)

# --- Uitvoeren of tonen ------------------------------------------------------
$moved = 0; $skipped = 0
foreach ($grp in $plan) {
    $targetDir = Join-Path $root $grp.FolderName
    Write-Host ("[{0}]  ({1} bestanden)" -f $grp.FolderName, $grp.Files.Count) -ForegroundColor Cyan

    if ($Execute -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir | Out-Null
    }

    foreach ($file in $grp.Files) {
        $dest = Join-Path $targetDir $file.Name
        if (Test-Path -LiteralPath $dest) {
            Write-Warning ("  OVERGESLAGEN (bestaat al): {0}" -f $file.Name)
            $skipped++
            continue
        }
        if ($Execute) {
            Move-Item -LiteralPath $file.FullName -Destination $dest
            $moved++
        }
        else {
            Write-Host ("  -> {0}" -f $file.Name)
        }
    }
}

Write-Host ("-" * 60)
if ($Execute) {
    Write-Host ("Klaar. Verplaatst: {0}  Overgeslagen: {1}" -f $moved, $skipped) -ForegroundColor Green
}
else {
    Write-Host "Dit was een DRY-RUN. Voeg -Execute toe om echt te verplaatsen." -ForegroundColor Yellow
}