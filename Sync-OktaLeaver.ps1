<#
.SYNOPSIS
    V2 (non testé) — Désactive l'utilisateur Okta correspondant à un Leaver AD.

.DESCRIPTION
    Complément de Disable-Leaver.ps1 : équivalent fonctionnel de Disable-ADAccount côté Okta —
    l'utilisateur est désactivé (récupérable via réactivation), pas supprimé. Pas besoin de
    retirer les groupes explicitement : un utilisateur désactivé perd tout accès de fait.

.PARAMETER Login
    Login/UPN Okta de la personne (doit déjà exister côté Okta).

.PARAMETER OktaOrgUrl
    URL de base du tenant Okta (ex: "https://dev-12345.okta.com"), sans slash final.

.PARAMETER ApiToken
    Jeton API Okta (SSWS), en SecureString.

.EXAMPLE
    .\Sync-OktaLeaver.ps1 -Login "kbenatia@society.local" -OktaOrgUrl "https://dev-12345.okta.com" -ApiToken (Read-Host -AsSecureString)

.NOTES
    Non testé contre un tenant Okta réel à ce stade — à valider avant de considérer ce script
    fiable (voir README, section V2).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Login,

    [Parameter(Mandatory)]
    [string]$OktaOrgUrl,

    [Parameter(Mandatory)]
    [System.Security.SecureString]$ApiToken
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

$result = [PSCustomObject]@{
    Login  = $Login
    Status = "Failed"
    Error  = ""
}

try {
    $headers = Get-OktaAuthHeaders -ApiToken $ApiToken
    $userId = Get-OktaUserIdByLogin -OktaOrgUrl $OktaOrgUrl -Headers $headers -Login $Login

    Invoke-RestMethod -Uri "$OktaOrgUrl/api/v1/users/$userId/lifecycle/deactivate" -Headers $headers -Method Post -ErrorAction Stop

    $result.Status = "Success"
    Write-Host "=== Sync Okta Leaver OK : $Login désactivé ===" -ForegroundColor Green
}
catch {
    $result.Error = $_.Exception.Message
    Write-Host "ERREUR Sync Okta Leaver $Login : $($_.Exception.Message)" -ForegroundColor Red
}

$result
