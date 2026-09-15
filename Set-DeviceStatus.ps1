<#
.SYNOPSIS
    Active ou désactive un objet ordinateur AD selon son statut matériel (perdu, retrouvé, non
    rendu par un leaver).

.DESCRIPTION
    Un compte utilisateur désactivé (Disable-Leaver.ps1) ne suffit pas si le poste physique
    reste capable d'ouvrir une session de domaine — désactiver l'objet ordinateur correspondant
    empêche l'établissement du canal sécurisé avec le domaine, donc bloque l'accès aux
    ressources réseau même si la personne qui détient le poste (voleur, leaver récalcitrant) a
    encore une session locale en cache.

    Ne lève jamais d'exception non interceptée : retourne toujours un objet résultat avec un
    Status, pour rester utilisable en boucle depuis Invoke-JMLBatch.ps1 ou depuis
    Disable-Leaver.ps1.

.PARAMETER AssetTag
    sAMAccountName de l'objet ordinateur AD concerné (ex: "LAPTOP-JDUPONT$" — le $ final fait
    partie du sAMAccountName standard des comptes ordinateur, accepté avec ou sans).

.PARAMETER Reason
    Motif du changement de statut : Perdu ou NonRendu désactivent l'objet, Retrouve le
    réactive.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER Credential
    Identifiants pour le bind AD. Si omis, demandés interactivement (Get-Credential).

.PARAMETER WhatIf
    Simule l'exécution sans rien écrire dans l'annuaire.

.EXAMPLE
    .\Set-DeviceStatus.ps1 -AssetTag "LAPTOP-JDUPONT" -Reason Perdu
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AssetTag,

    [Parameter(Mandatory)]
    [ValidateSet('Perdu', 'Retrouve', 'NonRendu')]
    [string]$Reason,

    [string]$Server = "DC1.society.local",

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$WhatIf
)

$result = [PSCustomObject]@{
    AssetTag = $AssetTag
    Reason   = $Reason
    Action   = ""
    Status   = "Failed"
    Error    = ""
}

try {
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
    }

    $identity = $AssetTag.TrimEnd('$')
    $computer = Get-ADComputer -Identity $identity -Server $Server -Credential $Credential -ErrorAction Stop

    $description = "Statut: $Reason - $(Get-Date -Format 'yyyy-MM-dd')"

    if ($Reason -eq 'Retrouve') {
        Enable-ADAccount -Identity $computer -Server $Server -Credential $Credential -WhatIf:$WhatIf
        $result.Action = "Enabled"
    }
    else {
        Disable-ADAccount -Identity $computer -Server $Server -Credential $Credential -WhatIf:$WhatIf
        $result.Action = "Disabled"
    }
    Set-ADComputer -Identity $computer -Description $description -Server $Server -Credential $Credential -WhatIf:$WhatIf

    $result.Status = if ($WhatIf) { "WhatIf" } else { "Success" }
    Write-Host "=== Poste $AssetTag : $Reason -> $($result.Action) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Set-DeviceStatus $AssetTag : $($_.Exception.Message)" -ForegroundColor Red
}

$result
