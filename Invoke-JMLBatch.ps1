<#
.SYNOPSIS
    Orchestrateur JML : lit un export RH (CSV) et déclenche le script adapté pour chaque ligne
    (Joiner, Mover, Leaver, ou changement de statut matériel).

.DESCRIPTION
    Demande les identifiants AD une seule fois au démarrage, puis dispatche chaque ligne du CSV
    vers New-Joiner.ps1, Update-Mover.ps1, Disable-Leaver.ps1 ou Set-DeviceStatus.ps1 selon la
    colonne ActionType. Une erreur sur une ligne n'interrompt pas le traitement des suivantes —
    chaque script sous-jacent retourne un objet résultat avec un Status plutôt que de lever une
    exception.

    Colonnes attendues dans le CSV RH : ActionType (Joiner/Mover/Leaver/DeviceLost/DeviceFound),
    FirstName, LastName, Department, OldDepartment, NewDepartment, SamAccountName, AssetTag,
    EquipmentReturned — vides selon le type de ligne (voir sample-data/HR_Feed_Sample.csv).

.PARAMETER HRFeedCsv
    CSV d'export RH en entrée.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER GroupMappingJson
    Fichier JSON Département -> liste de groupes, transmis à New-Joiner.ps1/Update-Mover.ps1.

.PARAMETER OutputReportCsv
    CSV de sortie récapitulant chaque ligne traitée.

.PARAMETER WhatIf
    Simule l'exécution sans rien écrire dans l'annuaire (transmis à chaque script appelé).

.EXAMPLE
    .\Invoke-JMLBatch.ps1 -HRFeedCsv .\sample-data\HR_Feed_Sample.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HRFeedCsv,

    [string]$Server = "DC1.society.local",

    [string]$GroupMappingJson = "department-group-mapping.json",

    [string]$OutputReportCsv = "JML_Run_Report_$(Get-Date -Format 'yyyy-MM-dd').csv",

    [switch]$WhatIf
)

if (-not (Test-Path $HRFeedCsv)) {
    Write-Host "Fichier RH introuvable : $HRFeedCsv" -ForegroundColor Red
    exit 1
}

# -Encoding UTF8 ajoute le BOM sous Windows PowerShell 5.1 mais pas sous PowerShell 7+, où
# Excel (locale FR) lit alors les accents comme du Windows-1252 et les corrompt. On force le
# BOM sur les deux versions.
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

$rows = Import-Csv $HRFeedCsv
Write-Host "Lignes RH chargées : $($rows.Count)"

$Credential = Get-Credential -Message "Identifiants pour le bind sur $Server (utilisés pour toutes les lignes du batch)"

$scriptDir = $PSScriptRoot
$report = [System.Collections.ArrayList]::new()

function Convert-ToBool {
    param([string]$Value)
    if (-not $Value) { return $false }
    return $Value.Trim().ToLowerInvariant() -in @('true', 'oui', 'yes', '1')
}

foreach ($row in $rows) {
    $actionType = $row.ActionType.Trim()
    Write-Host ""
    Write-Host "--- $actionType : $($row.FirstName) $($row.LastName) $($row.SamAccountName) ---" -ForegroundColor Cyan

    $itemResult = switch ($actionType) {
        "Joiner" {
            & (Join-Path $scriptDir "New-Joiner.ps1") `
                -FirstName $row.FirstName -LastName $row.LastName -Department $row.Department `
                -Server $Server -GroupMappingJson $GroupMappingJson -Credential $Credential -WhatIf:$WhatIf
        }
        "Mover" {
            & (Join-Path $scriptDir "Update-Mover.ps1") `
                -SamAccountName $row.SamAccountName -OldDepartment $row.OldDepartment -NewDepartment $row.NewDepartment `
                -Server $Server -GroupMappingJson $GroupMappingJson -Credential $Credential -WhatIf:$WhatIf
        }
        "Leaver" {
            $leaverParams = @{
                SamAccountName = $row.SamAccountName
                Server         = $Server
                Credential     = $Credential
                WhatIf         = $WhatIf
            }
            if ($row.AssetTag) {
                $leaverParams.AssetTag = $row.AssetTag
                $leaverParams.EquipmentReturned = Convert-ToBool $row.EquipmentReturned
            }
            & (Join-Path $scriptDir "Disable-Leaver.ps1") @leaverParams
        }
        "DeviceLost" {
            & (Join-Path $scriptDir "Set-DeviceStatus.ps1") `
                -AssetTag $row.AssetTag -Reason Perdu -Server $Server -Credential $Credential -WhatIf:$WhatIf
        }
        "DeviceFound" {
            & (Join-Path $scriptDir "Set-DeviceStatus.ps1") `
                -AssetTag $row.AssetTag -Reason Retrouve -Server $Server -Credential $Credential -WhatIf:$WhatIf
        }
        default {
            Write-Host "ActionType inconnu : '$actionType' — ligne ignorée." -ForegroundColor Red
            [PSCustomObject]@{ Status = "Failed"; Error = "ActionType inconnu : '$actionType'" }
        }
    }

    [void]$report.Add([PSCustomObject]@{
        ActionType     = $actionType
        FirstName      = $row.FirstName
        LastName       = $row.LastName
        SamAccountName = if ($itemResult.SamAccountName) { $itemResult.SamAccountName } else { $row.SamAccountName }
        AssetTag       = $row.AssetTag
        Status         = $itemResult.Status
        # TempPassword exclu du rapport persisté : un mot de passe temporaire n'a rien à faire
        # dans un fichier partagé/relu par d'autres que la personne qui l'a communiqué au
        # joiner — il reste visible uniquement dans la sortie console de New-Joiner.ps1.
        Detail         = (($itemResult | Select-Object -Property * -ExcludeProperty Status, Error, SamAccountName, FirstName, LastName, TempPassword | Out-String).Trim() -replace '\s+', ' ')
        Error          = $itemResult.Error
    })
}

$report | Export-Csv $OutputReportCsv -NoTypeInformation -Encoding $csvEncoding

$success = @($report | Where-Object { $_.Status -in @('Success', 'WhatIf') }).Count
$failed  = @($report | Where-Object { $_.Status -eq 'Failed' }).Count

Write-Host ""
Write-Host "=== Résumé du batch ===" -ForegroundColor Cyan
Write-Host "Lignes traitées : $($report.Count)"
Write-Host "Succès          : $success" -ForegroundColor Green
Write-Host "Échecs          : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Rapport -> $OutputReportCsv"
