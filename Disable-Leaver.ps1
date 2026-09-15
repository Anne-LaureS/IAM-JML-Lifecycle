<#
.SYNOPSIS
    Désactive le compte d'une personne qui quitte l'organisation (Leaver) : retire tous ses
    accès applicatifs, désactive le compte, le déplace dans une OU dédiée.

.DESCRIPTION
    Retire la personne de tous ses groupes (hors groupe primaire Domain Users), désactive le
    compte AD, et le déplace dans OU=Leavers pour séparer les comptes désactivés des comptes
    actifs dans l'annuaire.

    Si -AssetTag est fourni et que le matériel n'a pas été rendu (-EquipmentReturned:$false),
    appelle aussi Set-DeviceStatus.ps1 pour désactiver l'objet ordinateur correspondant — un
    compte utilisateur désactivé ne bloque pas un poste qui garde une session locale en cache.
    Si le matériel est rendu, aucune action sur le poste (le reformatage/la réattribution
    relèvent de l'ITAM, pas de ce script).

    Ne lève jamais d'exception non interceptée : retourne toujours un objet résultat avec un
    Status, pour rester utilisable en boucle depuis Invoke-JMLBatch.ps1.

.PARAMETER SamAccountName
    Identifiant du compte à désactiver.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER LeaverOU
    OU où déplacer le compte désactivé. OU=Leavers,DC=society,DC=local par défaut — créée si
    absente.

.PARAMETER AssetTag
    sAMAccountName de l'objet ordinateur associé à cette personne (optionnel).

.PARAMETER EquipmentReturned
    Indique si le matériel a été rendu. Pertinent seulement si -AssetTag est fourni.

.PARAMETER Credential
    Identifiants pour le bind AD. Si omis, demandés interactivement (Get-Credential).

.PARAMETER WhatIf
    Simule l'exécution sans rien écrire dans l'annuaire.

.EXAMPLE
    .\Disable-Leaver.ps1 -SamAccountName "afontaine" -AssetTag "LAPTOP-AFONTAINE" -EquipmentReturned:$false
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SamAccountName,

    [string]$Server = "DC1.society.local",

    [string]$LeaverOU = "OU=Leavers,DC=society,DC=local",

    [string]$AssetTag,

    [bool]$EquipmentReturned = $true,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$WhatIf
)

$result = [PSCustomObject]@{
    SamAccountName = $SamAccountName
    GroupsRemoved  = ""
    DeviceAction   = ""
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
    }

    $user = Get-ADUser -Identity $SamAccountName -Server $Server -Credential $Credential -Properties MemberOf -ErrorAction Stop

    # Domain Users est le groupe primaire : il ne peut pas être retiré via
    # Remove-ADPrincipalGroupMembership (il faudrait d'abord changer le groupe primaire), et
    # n'accorde de toute façon aucun accès applicatif — pas besoin d'y toucher pour un leaver.
    $groups = $user.MemberOf
    $removedGroups = [System.Collections.Generic.List[string]]::new()
    foreach ($groupDn in $groups) {
        Remove-ADPrincipalGroupMembership -Identity $SamAccountName -MemberOf $groupDn -Server $Server -Credential $Credential -Confirm:$false -WhatIf:$WhatIf
        $removedGroups.Add((($groupDn -split ',')[0] -replace '^CN=', ''))
    }
    $result.GroupsRemoved = ($removedGroups -join "; ")

    Disable-ADAccount -Identity $SamAccountName -Server $Server -Credential $Credential -WhatIf:$WhatIf
    Set-ADUser -Identity $SamAccountName -Description "Désactivé par JML le $(Get-Date -Format 'yyyy-MM-dd') - Leaver" -Server $Server -Credential $Credential -WhatIf:$WhatIf

    # Get-ADOrganizationalUnit lève une exception terminale (ADIdentityNotFoundException) pour
    # une identité introuvable, qui contourne -ErrorAction SilentlyContinue — un vrai try/catch
    # est nécessaire pour tester son existence sans interrompre le script.
    $leaverOuExists = $true
    try {
        $null = Get-ADOrganizationalUnit -Identity $LeaverOU -Server $Server -Credential $Credential -ErrorAction Stop
    } catch {
        $leaverOuExists = $false
    }
    if (-not $leaverOuExists) {
        $leaverOuName = ($LeaverOU -split ',')[0] -replace '^OU=', ''
        $leaverParentPath = ($LeaverOU -split ',', 2)[1]
        New-ADOrganizationalUnit -Name $leaverOuName -Path $leaverParentPath -Server $Server -Credential $Credential -WhatIf:$WhatIf
    }
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $LeaverOU -Server $Server -Credential $Credential -WhatIf:$WhatIf

    if ($AssetTag -and -not $EquipmentReturned) {
        $deviceResult = & (Join-Path $PSScriptRoot "Set-DeviceStatus.ps1") -AssetTag $AssetTag -Reason NonRendu -Server $Server -Credential $Credential -WhatIf:$WhatIf
        $result.DeviceAction = "$AssetTag -> $($deviceResult.Action) ($($deviceResult.Status))"
    }
    elseif ($AssetTag) {
        $result.DeviceAction = "$AssetTag : matériel rendu, aucune action"
    }

    $result.Status = if ($WhatIf) { "WhatIf" } else { "Success" }
    Write-Host "=== Leaver désactivé : $SamAccountName (groupes retirés: $($result.GroupsRemoved)) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Leaver $SamAccountName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
