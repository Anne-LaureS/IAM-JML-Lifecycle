<#
.SYNOPSIS
    Crée un compte AD pour un nouvel arrivant (Joiner) et lui attribue son accès de base
    ("birthright") selon son département.

.DESCRIPTION
    Génère un sAMAccountName et un mot de passe temporaire, crée le compte dans l'annuaire,
    puis l'ajoute aux groupes correspondant à son département via department-group-mapping.json
    — les mêmes groupes que ceux audités par LDAP-App-Role-Audit et recertifiés par
    IAM-Access-Recertification, pour que le cycle de vie complet reste cohérent avec le reste
    du portfolio.

    Ne lève jamais d'exception non interceptée : retourne toujours un objet résultat avec un
    Status, pour rester utilisable en boucle depuis Invoke-JMLBatch.ps1 sans interrompre le
    traitement des autres lignes en cas d'échec sur une personne.

.PARAMETER FirstName
    Prénom du nouvel arrivant.

.PARAMETER LastName
    Nom de famille du nouvel arrivant.

.PARAMETER Department
    Département déclaré — résolu dans -GroupMappingJson pour déterminer l'accès de base.

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut (lab de référence du portfolio).

.PARAMETER UsersContainer
    OU où créer le compte. OU=Utilisateurs,DC=society,DC=local par défaut — une OU dédiée,
    vide, distincte à la fois de CN=Users (conteneur intégré, contient les objets système par
    défaut comme Administrator/Domain Admins). Les 21 comptes de démo de LDAP-App-Role-Audit y
    sont fusionnés (Expand-LabApplications.ps1 -Step MergeUsers) : une seule OU d'identités.
    OU=Utilisateurs-Test ne garde que les comptes de test jetables.

.PARAMETER GroupMappingJson
    Fichier JSON Département -> liste de groupes (department-group-mapping.json par défaut).

.PARAMETER Credential
    Identifiants pour le bind AD. Si omis, demandés interactivement (Get-Credential).

.PARAMETER WhatIf
    Simule l'exécution sans rien écrire dans l'annuaire.

.EXAMPLE
    .\New-Joiner.ps1 -FirstName "Alice" -LastName "Fontaine" -Department "CRM"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FirstName,

    [Parameter(Mandatory)]
    [string]$LastName,

    [Parameter(Mandatory)]
    [string]$Department,

    [string]$Server = "DC1.society.local",

    [string]$UsersContainer = "OU=Utilisateurs,DC=society,DC=local",

    [string]$GroupMappingJson = "department-group-mapping.json",

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$WhatIf
)

function Remove-Diacritics {
    param([string]$Text)
    if (-not $Text) { return "" }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Get-CandidateSamAccountName {
    # Convention déjà en usage dans le lab (jdupont, hlemoine, lrousseau) : 1ère lettre du
    # prénom + nom complet, minuscule, sans accents/espaces.
    param([string]$FirstName, [string]$LastName)
    $first = (Remove-Diacritics $FirstName).Substring(0, 1)
    $last  = (Remove-Diacritics $LastName) -replace '[^A-Za-z]', ''
    return ($first + $last).ToLowerInvariant()
}

function New-RandomPassword {
    # Mot de passe temporaire respectant la complexité AD par défaut (3 des 4 catégories) :
    # au moins 1 majuscule, 1 minuscule, 1 chiffre, 1 caractère spécial, 14 caractères.
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnpqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#$%^&*-_+='
    $all = $upper + $lower + $digits + $special
    $required = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )
    $rest = 1..10 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    $chars = @($required + $rest) | Sort-Object { Get-Random }
    return -join $chars
}

$result = [PSCustomObject]@{
    FirstName      = $FirstName
    LastName       = $LastName
    SamAccountName = ""
    Department     = $Department
    GroupsAssigned = ""
    TempPassword   = ""
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not (Test-Path $GroupMappingJson)) {
        throw "Fichier de mapping introuvable : $GroupMappingJson"
    }
    $mapping = Get-Content $GroupMappingJson -Raw | ConvertFrom-Json
    $groupsForDept = $mapping.$Department
    if (-not $groupsForDept) {
        Write-Host "ATTENTION : département '$Department' absent de $GroupMappingJson — aucun groupe ne sera assigné." -ForegroundColor Yellow
        $groupsForDept = @()
    }

    if (-not $Credential) {
        $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
    }

    # Résolution du sAMAccountName avec gestion des collisions (jdupont, jdupont2, ...)
    $candidate = Get-CandidateSamAccountName -FirstName $FirstName -LastName $LastName
    $samAccountName = $candidate
    $suffix = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$samAccountName'" -Server $Server -Credential $Credential -ErrorAction SilentlyContinue) {
        $suffix++
        $samAccountName = "$candidate$suffix"
    }
    $result.SamAccountName = $samAccountName

    $tempPassword = New-RandomPassword
    $result.TempPassword = $tempPassword
    $securePassword = ConvertTo-SecureString $tempPassword -AsPlainText -Force

    $upn = "$samAccountName@society.local"

    New-ADUser `
        -Name "$FirstName $LastName" `
        -GivenName $FirstName `
        -Surname $LastName `
        -SamAccountName $samAccountName `
        -UserPrincipalName $upn `
        -Path $UsersContainer `
        -Department $Department `
        -AccountPassword $securePassword `
        -ChangePasswordAtLogon $true `
        -Enabled $true `
        -Server $Server `
        -Credential $Credential `
        -WhatIf:$WhatIf

    $assignedGroups = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $groupsForDept) {
        Add-ADPrincipalGroupMembership -Identity $samAccountName -MemberOf $group -Server $Server -Credential $Credential -WhatIf:$WhatIf
        $assignedGroups.Add($group)
    }
    $result.GroupsAssigned = ($assignedGroups -join "; ")
    $result.Status = if ($WhatIf) { "WhatIf" } else { "Success" }

    Write-Host "=== Joiner créé : $samAccountName ($Department) -> $($result.GroupsAssigned) ===" -ForegroundColor Green
    Write-Host "Mot de passe temporaire (à communiquer de façon sécurisée, jamais conservé dans les rapports) : $tempPassword" -ForegroundColor Yellow
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Joiner $FirstName $LastName : $($_.Exception.Message)" -ForegroundColor Red
}

$result
