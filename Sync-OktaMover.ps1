<#
.SYNOPSIS
    V2 (non testé) — Met à jour les groupes Okta d'un Mover : retire ceux de l'ancien
    département, ajoute ceux du nouveau.

.DESCRIPTION
    Complément d'Update-Mover.ps1, même logique de diff que le script AD : seuls les groupes
    réellement propres à l'ancien département sont retirés, ceux communs aux deux départements
    restent en place. Résout les groupes Okta par nom via department-group-mapping.json (les
    noms de groupe Okta doivent être identiques aux noms de groupe AD).

.PARAMETER Login
    Login/UPN Okta de la personne (doit déjà exister côté Okta).

.PARAMETER OldDepartment
.PARAMETER NewDepartment
.PARAMETER OktaOrgUrl
    URL de base du tenant Okta (ex: "https://dev-12345.okta.com"), sans slash final.

.PARAMETER ApiToken
    Jeton API Okta (SSWS), en SecureString.

.PARAMETER GroupMappingJson
    Fichier JSON Département -> liste de groupes (department-group-mapping.json par défaut).

.EXAMPLE
    .\Sync-OktaMover.ps1 -Login "afontaine@society.local" -OldDepartment "CRM" -NewDepartment "ERP" -OktaOrgUrl "https://dev-12345.okta.com" -ApiToken (Read-Host -AsSecureString)

.NOTES
    Non testé contre un tenant Okta réel à ce stade — à valider avant de considérer ce script
    fiable (voir README, section V2).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Login,

    [Parameter(Mandatory)]
    [string]$OldDepartment,

    [Parameter(Mandatory)]
    [string]$NewDepartment,

    [Parameter(Mandatory)]
    [string]$OktaOrgUrl,

    [Parameter(Mandatory)]
    [System.Security.SecureString]$ApiToken,

    [string]$GroupMappingJson = "department-group-mapping.json"
)

function Get-OktaAuthHeaders {
    param([System.Security.SecureString]$ApiToken)
    $plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($ApiToken))
    return @{
        Authorization = "SSWS $plainToken"
        Accept        = "application/json"
        "Content-Type" = "application/json"
    }
}

function Get-OktaUserIdByLogin {
    param([string]$OktaOrgUrl, [hashtable]$Headers, [string]$Login)
    $user = Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/users/$Login" -Headers $Headers -Method Get -ErrorAction Stop
    return $user.id
}

function Get-OktaGroupIdByName {
    param([string]$OktaOrgUrl, [hashtable]$Headers, [string]$GroupName)
    $encoded = [uri]::EscapeDataString($GroupName)
    $groups = Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/groups?q=$encoded" -Headers $Headers -Method Get -ErrorAction Stop
    $match = $groups | Where-Object { $_.profile.name -eq $GroupName } | Select-Object -First 1
    if (-not $match) { throw "Groupe Okta introuvable pour le nom '$GroupName' — vérifier qu'il existe avec exactement ce nom dans Okta." }
    return $match.id
}

$result = [PSCustomObject]@{
    Login         = $Login
    OldDepartment = $OldDepartment
    NewDepartment = $NewDepartment
    GroupsRemoved = ""
    GroupsAdded   = ""
    Status        = "Failed"
    Error         = ""
}

try {
    if (-not (Test-Path $GroupMappingJson)) {
        throw "Fichier de mapping introuvable : $GroupMappingJson"
    }
    $mapping = Get-Content $GroupMappingJson -Raw | ConvertFrom-Json
    $oldGroups = @($mapping.$OldDepartment)
    $newGroups = @($mapping.$NewDepartment)

    $headers = Get-OktaAuthHeaders -ApiToken $ApiToken
    # Get-OktaUserIdByLogin lève une exception explicite si l'utilisateur n'existe pas — pas de
    # -ErrorAction SilentlyContinue ici (piège déjà rencontré côté AD : ça masquerait l'échec
    # réel derrière un message générique).
    $userId = Get-OktaUserIdByLogin -OktaOrgUrl $OktaOrgUrl -Headers $headers -Login $Login

    $groupsToRemove = $oldGroups | Where-Object { $_ -and ($newGroups -notcontains $_) }
    $groupsToAdd    = $newGroups | Where-Object { $_ -and ($oldGroups -notcontains $_) }

    foreach ($groupName in $groupsToRemove) {
        $groupId = Get-OktaGroupIdByName -OktaOrgUrl $OktaOrgUrl -Headers $headers -GroupName $groupName
        Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/groups/$groupId/users/$userId" -Headers $headers -Method Delete -ErrorAction Stop
    }
    foreach ($groupName in $groupsToAdd) {
        $groupId = Get-OktaGroupIdByName -OktaOrgUrl $OktaOrgUrl -Headers $headers -GroupName $groupName
        Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/groups/$groupId/users/$userId" -Headers $headers -Method Put -ErrorAction Stop
    }

    $result.GroupsRemoved = ($groupsToRemove -join "; ")
    $result.GroupsAdded   = ($groupsToAdd -join "; ")
    $result.Status = "Success"
    Write-Host "=== Sync Okta Mover $Login : $OldDepartment -> $NewDepartment (retiré: $($result.GroupsRemoved) / ajouté: $($result.GroupsAdded)) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Sync Okta Mover $Login : $($_.Exception.Message)" -ForegroundColor Red
}

$result
