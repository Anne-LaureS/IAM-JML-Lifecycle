<#
.SYNOPSIS
    Met à jour l'accès d'une personne qui change de département (Mover) : retire les groupes
    de l'ancien département, ajoute ceux du nouveau.

.DESCRIPTION
    Résout OldDepartment et NewDepartment dans le même department-group-mapping.json que
    New-Joiner.ps1, puis calcule la différence entre les deux listes de groupes — seuls les
    groupes réellement propres à l'ancien département sont retirés, ceux communs aux deux
    départements restent en place (évite un retrait/réajout inutile si un groupe est partagé).

    Ne lève jamais d'exception non interceptée : retourne toujours un objet résultat avec un
    Status, pour rester utilisable en boucle depuis Invoke-JMLBatch.ps1.

.PARAMETER SamAccountName
    Identifiant du compte existant à modifier.

.PARAMETER OldDepartment
    Département quitté.

.PARAMETER NewDepartment
    Nouveau département.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER GroupMappingJson
    Fichier JSON Département -> liste de groupes (department-group-mapping.json par défaut).

.PARAMETER Credential
    Identifiants pour le bind AD. Si omis, demandés interactivement (Get-Credential).

.PARAMETER WhatIf
    Simule l'exécution sans rien écrire dans l'annuaire.

.EXAMPLE
    .\Update-Mover.ps1 -SamAccountName "afontaine" -OldDepartment "CRM" -NewDepartment "ERP"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SamAccountName,

    [Parameter(Mandatory)]
    [string]$OldDepartment,

    [Parameter(Mandatory)]
    [string]$NewDepartment,

    [string]$Server = "DC1.society.local",

    [string]$GroupMappingJson = "department-group-mapping.json",

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$WhatIf
)

$result = [PSCustomObject]@{
    SamAccountName = $SamAccountName
    OldDepartment  = $OldDepartment
    NewDepartment  = $NewDepartment
    GroupsRemoved  = ""
    GroupsAdded    = ""
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not (Test-Path $GroupMappingJson)) {
        throw "Fichier de mapping introuvable : $GroupMappingJson"
    }
    $mapping = Get-Content $GroupMappingJson -Raw | ConvertFrom-Json
    $oldGroups = @($mapping.$OldDepartment)
    $newGroups = @($mapping.$NewDepartment)

    if (-not $Credential) {
        $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
    }

    # Get-ADUser -Identity lève une exception terminale (ADIdentityNotFoundException) pour une
    # identité introuvable, qui contourne -ErrorAction SilentlyContinue — un vrai try/catch est
    # nécessaire pour renvoyer un message clair plutôt que l'exception .NET brute.
    try {
        $null = Get-ADUser -Identity $SamAccountName -Server $Server -Credential $Credential -ErrorAction Stop
    } catch {
        throw "Compte introuvable : $SamAccountName"
    }

    $groupsToRemove = $oldGroups | Where-Object { $_ -and ($newGroups -notcontains $_) }
    $groupsToAdd    = $newGroups | Where-Object { $_ -and ($oldGroups -notcontains $_) }

    foreach ($group in $groupsToRemove) {
        Remove-ADPrincipalGroupMembership -Identity $SamAccountName -MemberOf $group -Server $Server -Credential $Credential -Confirm:$false -WhatIf:$WhatIf
    }
    foreach ($group in $groupsToAdd) {
        Add-ADPrincipalGroupMembership -Identity $SamAccountName -MemberOf $group -Server $Server -Credential $Credential -WhatIf:$WhatIf
    }

    Set-ADUser -Identity $SamAccountName -Department $NewDepartment -Server $Server -Credential $Credential -WhatIf:$WhatIf

    $result.GroupsRemoved = ($groupsToRemove -join "; ")
    $result.GroupsAdded   = ($groupsToAdd -join "; ")
    $result.Status = if ($WhatIf) { "WhatIf" } else { "Success" }

    Write-Host "=== Mover $SamAccountName : $OldDepartment -> $NewDepartment (retiré: $($result.GroupsRemoved) / ajouté: $($result.GroupsAdded)) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Mover $SamAccountName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
