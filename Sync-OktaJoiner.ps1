<#
.SYNOPSIS
    V2 (non testé) — Crée/active l'utilisateur Okta correspondant à un Joiner AD et l'ajoute
    aux groupes Okta de son département.

.DESCRIPTION
    Complément de New-Joiner.ps1 : AD reste la source de vérité, ce script répercute
    l'arrivée côté Okta pour que le provisioning et l'authentification fédérée restent
    cohérents. Idempotent : si un utilisateur Okta existe déjà avec ce login, il n'est pas
    recréé (seuls les groupes sont vérifiés/ajoutés).

    Réutilise department-group-mapping.json (le même fichier que New-Joiner.ps1) : les groupes
    Okta doivent porter exactement les mêmes noms que les groupes AD pour être résolus par nom,
    sans fichier de correspondance séparé à maintenir.

.PARAMETER Login
    Login/UPN Okta, doit correspondre à l'UPN AD (ex: "afontaine@society.local") pour que les
    deux comptes soient corrélables.

.PARAMETER FirstName
.PARAMETER LastName
.PARAMETER Department
    Département déclaré — résolu dans -GroupMappingJson pour déterminer les groupes Okta.

.PARAMETER OktaOrgUrl
    URL de base du tenant Okta (ex: "https://dev-12345.okta.com"), sans slash final.

.PARAMETER ApiToken
    Jeton API Okta (SSWS), en SecureString. Généré dans Okta : Security > API > Tokens.

.PARAMETER GroupMappingJson
    Fichier JSON Département -> liste de groupes (department-group-mapping.json par défaut).

.EXAMPLE
    .\Sync-OktaJoiner.ps1 -Login "afontaine@society.local" -FirstName "Alice" -LastName "Fontaine" -Department "CRM" -OktaOrgUrl "https://dev-12345.okta.com" -ApiToken (Read-Host -AsSecureString)

.NOTES
    Non testé contre un tenant Okta réel à ce stade — à valider avant de considérer ce script
    fiable (voir README, section V2).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Login,

    [Parameter(Mandatory)]
    [string]$FirstName,

    [Parameter(Mandatory)]
    [string]$LastName,

    [Parameter(Mandatory)]
    [string]$Department,

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
    try {
        $user = Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/users/$Login" -Headers $Headers -Method Get -ErrorAction Stop
        return $user.id
    }
    catch {
        return $null
    }
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
    Login          = $Login
    Department     = $Department
    OktaUserId     = ""
    Created        = $false
    GroupsAssigned = ""
    Status         = "Failed"
    Error          = ""
}

try {
    if (-not (Test-Path $GroupMappingJson)) {
        throw "Fichier de mapping introuvable : $GroupMappingJson"
    }
    $mapping = Get-Content $GroupMappingJson -Raw | ConvertFrom-Json
    $groupsForDept = @($mapping.$Department)
    if ($groupsForDept.Count -eq 0) {
        Write-Host "ATTENTION : département '$Department' absent de $GroupMappingJson — aucun groupe ne sera assigné." -ForegroundColor Yellow
    }

    $headers = Get-OktaAuthHeaders -ApiToken $ApiToken
    $existingId = Get-OktaUserIdByLogin -OktaOrgUrl $OktaOrgUrl -Headers $headers -Login $Login

    if ($existingId) {
        $result.OktaUserId = $existingId
        $result.Created = $false
        Write-Host "Utilisateur Okta déjà existant : $Login ($existingId) — pas de recréation." -ForegroundColor Yellow
    }
    else {
        $body = @{
            profile = @{
                firstName = $FirstName
                lastName  = $LastName
                email     = $Login
                login     = $Login
            }
        } | ConvertTo-Json

        $newUser = Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/users?activate=true" -Headers $headers -Method Post -Body $body -ErrorAction Stop
        $result.OktaUserId = $newUser.id
        $result.Created = $true
        Write-Host "Utilisateur Okta créé et activé : $Login ($($newUser.id))" -ForegroundColor Green
    }

    $assignedGroups = [System.Collections.Generic.List[string]]::new()
    foreach ($groupName in $groupsForDept) {
        $groupId = Get-OktaGroupIdByName -OktaOrgUrl $OktaOrgUrl -Headers $headers -GroupName $groupName
        Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/groups/$groupId/users/$($result.OktaUserId)" -Headers $headers -Method Put -ErrorAction Stop
        $assignedGroups.Add($groupName)
    }
    $result.GroupsAssigned = ($assignedGroups -join "; ")

    $result.Status = "Success"
    Write-Host "=== Sync Okta Joiner OK : $Login -> $($result.GroupsAssigned) ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Sync Okta Joiner $Login : $($_.Exception.Message)" -ForegroundColor Red
}

$result
