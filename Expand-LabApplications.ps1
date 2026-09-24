<#
.SYNOPSIS
    Enrichit le lab AD existant : ajoute des applications (OU) et leurs rôles (groupes) sous
    OU=Applications, crée des comptes admin/service/dormants, et pose des appartenances de rôle.

.DESCRIPTION
    Idempotent : ce qui existe déjà (OU, groupe, compte, appartenance) est constaté et laissé
    tel quel, seul ce qui manque est créé. N'écrase et ne supprime rien.

    Les utilisateurs "métier" ne sont pas créés ici : ils arrivent via IAM-JML-Lifecycle
    (Invoke-JMLBatch.ps1 avec sample-data\HR_Feed_Banque.csv). Ce script ajoute les objets que le
    cycle JML ne crée pas : applications et rôles, comptes privilégiés (adm-*), comptes de
    service (svc-*), comptes dormants/orphelins, et les appartenances de rôle privilégiées ou
    volontairement anormales (voir sample-data\Lab_ANOMALIES.md).

    Ordre conseillé : 1) ce script en -Step Apps, puis -Step Computers  2) Invoke-JMLBatch.ps1
    3) ce script en -Step Accounts puis -Step Memberships (ou sans -Step pour tout enchaîner si
    les joiners JML existent déjà).

    -Step Groups ajoute la couche AGDLP d'une vraie entreprise : groupes globaux G-<Département>
    (population) et G-ROLE-* (profils admin) dans OU=Groupes, groupes domaine local R-* (accès aux
    ressources) dans OU=Ressources, avec G-* imbriqués dans R-*. Ces groupes ne sont volontairement
    PAS imbriqués dans les rôles de OU=Applications : l'audit LDAP afficherait un nom de groupe
    au lieu des personnes et casserait la détection SoD. À lancer en dernier (comptes requis).

    -Step Nesting imbrique les groupes G-ROLE-* dans les rôles Admin de OU=Applications
    (nesting.csv), comme en entreprise : la personne est membre du profil, le profil est membre du
    rôle. L'accès est alors INDIRECT : il n'apparaît comme personne dans l'audit qu'avec
    Get-LdapAppRoleAudit.ps1 -ResolveNested (sans ce commutateur, le rôle affiche le nom du
    groupe). À lancer après -Step Groups.

    -Step Shares rend la chaîne AGDLP fonctionnelle : crée de vrais dossiers partagés sur
    -ShareServer (DC1 par défaut, via Invoke-Command / WinRM) dont les permissions NTFS et de
    partage sont accordées aux groupes R-* (Modify pour *-RW, Read pour *-RO), Administrators et
    SYSTEM gardant le contrôle total. Un utilisateur accède donc à un partage uniquement via
    G-Département -> R-ressource. À lancer après -Step Groups.

    -Step MergeUsers fusionne les comptes de démonstration de OU=Utilisateurs-Test dans
    OU=Utilisateurs (une seule OU d'identités). Ne déplace que les comptes membres d'au moins un
    rôle sous OU=Applications ; les comptes de test jetables (bind-debug, svc-vault-test), sans
    rôle applicatif, restent dans OU=Utilisateurs-Test. Les appartenances aux groupes suivent
    automatiquement le déplacement. L'OU source n'est jamais supprimée.

    -Step Birthright rattrape les groupes de base des Joiners du flux RH déjà créés dans
    OU=Utilisateurs mais restés sans groupe (cas où le lot JML a été lancé avant que les groupes
    n'existent : New-Joiner crée le compte puis échoue à l'ajout au groupe). Ignore les comptes
    désactivés ou déplacés (Leavers) et ne rajoute jamais un groupe déjà présent.

    -Step Computers crée les objets ordinateur (AssetTag) cités dans le flux RH, car
    Set-DeviceStatus.ps1 / Disable-Leaver.ps1 les recherchent avec Get-ADComputer.

.PARAMETER Step
    Apps | Computers | MergeUsers | Birthright | Accounts | Memberships | Groups | Nesting | Shares | All (défaut).

.PARAMETER Server
    Contrôleur de domaine cible. DC1.society.local par défaut.

.PARAMETER ApplicationsOU
    OU parente des applications. OU=Applications,DC=society,DC=local par défaut.

.PARAMETER AccountsOU
    OU où créer les comptes admin/service/dormants. OU=Utilisateurs par défaut : une seule OU
    d'identités, comme dans une vraie entreprise, partagée avec les Joiners JML. La colonne
    optionnelle TargetOU de accounts.csv prime (les comptes adm-* vont dans OU=Admins).

.PARAMETER WhatIf
    Simule sans rien écrire dans l'annuaire.

.EXAMPLE
    .\Expand-LabApplications.ps1 -Step Apps -WhatIf
#>

[CmdletBinding()]
param(
    [ValidateSet('Apps', 'Computers', 'MergeUsers', 'Birthright', 'Accounts', 'Memberships', 'Groups', 'Nesting', 'Shares', 'All')]
    [string]$Step = 'All',

    [string]$ApplicationsCsv = "$PSScriptRoot\sample-data\Lab_Applications.csv",
    [string]$AccountsCsv     = "$PSScriptRoot\sample-data\Lab_Accounts.csv",
    [string]$MembershipsCsv  = "$PSScriptRoot\sample-data\Lab_Memberships.csv",
    [string]$GroupsCsv       = "$PSScriptRoot\sample-data\Lab_Groups.csv",
    [string]$NestingCsv      = "$PSScriptRoot\sample-data\Lab_Nesting.csv",
    [string]$SharesCsv       = "$PSScriptRoot\sample-data\Lab_Shares.csv",
    [string]$ShareServer     = "",
    [string]$SharesRoot      = "C:\Shares",
    [string]$NetbiosDomain   = "SOCIETY",
    [string]$MoverFeedCsv    = "$PSScriptRoot\sample-data\HR_Feed_Banque_Reprise.csv",
    [string]$HRFeedCsv       = "$PSScriptRoot\sample-data\HR_Feed_Banque.csv",
    [string]$ComputersOU     = "CN=Computers,DC=society,DC=local",
    [string]$GroupMappingJson = "$PSScriptRoot\department-group-mapping.json",
    [string]$JoinersOU       = "OU=Utilisateurs,DC=society,DC=local",

    [string]$Server         = "DC1.society.local",
    [string]$ApplicationsOU = "OU=Applications,DC=society,DC=local",
    [string]$AccountsOU     = "OU=Utilisateurs,DC=society,DC=local",
    [string]$SourceUsersOU  = "OU=Utilisateurs-Test,DC=society,DC=local",
    [string]$UpnSuffix      = "society.local",

    [string]$OutputReportCsv = "$PSScriptRoot\Expand-LabApplications_Report_$(Get-Date -Format 'yyyy-MM-dd').csv",

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$WhatIf
)

Import-Module ActiveDirectory -ErrorAction Stop

$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

if (-not $Credential) {
    $Credential = Get-Credential -Message "Identifiants pour le bind sur $Server"
}
if (-not $Credential) {
    Write-Host "ERREUR : aucun identifiant fourni. Relancez et renseignez SOCIETY\Administrateur avec son mot de passe." -ForegroundColor Red
    exit 1
}
try {
    $null = Get-ADDomain -Server $Server -Credential $Credential -ErrorAction Stop
}
catch {
    Write-Host "ERREUR : connexion à $Server impossible avec ces identifiants ($($_.Exception.Message))." -ForegroundColor Red
    Write-Host "Vérifiez le mot de passe et que le compte n'est pas verrouillé (Utilisateurs et ordinateurs AD)." -ForegroundColor Yellow
    exit 1
}
$adArgs = @{ Server = $Server; Credential = $Credential }
if (-not $ShareServer) { $ShareServer = $Server }

function New-RandomPassword {
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digits = '23456789'; $special = '!@#$%^&*-_+='
    $all = $upper + $lower + $digits + $special
    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    ) + (1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] })
    -join ($chars | Sort-Object { Get-Random })
}

$report = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Step, [string]$Object, [string]$Status, [string]$Detail = "")
    $report.Add([PSCustomObject]@{ Step = $Step; Object = $Object; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'Created' { 'Green' } 'Exists' { 'DarkGray' } 'WhatIf' { 'Cyan' } default { 'Red' } }
    Write-Host ("[{0}] {1} : {2} {3}" -f $Step, $Object, $Status, $Detail) -ForegroundColor $color
}

function Test-Missing {
    param([scriptblock]$Query)
    try { return -not (& $Query) } catch { return $true }
}

# --- Étape 1 : applications (OU) + rôles (groupes) ---
if ($Step -in 'Apps', 'All') {
    foreach ($row in (Import-Csv $ApplicationsCsv)) {
        $appDn = "OU=$($row.Application),$ApplicationsOU"
        try {
            if (Test-Missing { Get-ADOrganizationalUnit -Identity $appDn @adArgs }) {
                New-ADOrganizationalUnit -Name $row.Application -Path $ApplicationsOU -Description $row.AppDescription `
                    -ProtectedFromAccidentalDeletion $false @adArgs -WhatIf:$WhatIf
                Add-Result 'Apps' "OU $($row.Application)" $(if ($WhatIf) { 'WhatIf' } else { 'Created' })
            }
            if (Test-Missing { Get-ADGroup -Identity $row.Role @adArgs }) {
                New-ADGroup -Name $row.Role -SamAccountName $row.Role -GroupScope Global -GroupCategory Security `
                    -Path $appDn -Description $row.RoleDescription @adArgs -WhatIf:$WhatIf
                Add-Result 'Apps' "Groupe $($row.Role)" $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) "dans $($row.Application)"
            }
            else {
                Add-Result 'Apps' "Groupe $($row.Role)" 'Exists'
            }
        }
        catch { Add-Result 'Apps' "$($row.Application)/$($row.Role)" 'Failed' $_.Exception.Message }
    }
}

# --- Étape 1b : objets ordinateur référencés par le flux RH (AssetTag) ---
if ($Step -in 'Computers', 'All') {
    $tags = Import-Csv $HRFeedCsv | Where-Object { $_.AssetTag } | Select-Object -ExpandProperty AssetTag -Unique
    foreach ($tag in $tags) {
        try {
            if (-not (Test-Missing { Get-ADComputer -Identity $tag @adArgs })) {
                Add-Result 'Computers' $tag 'Exists'
                continue
            }
            New-ADComputer -Name $tag -SamAccountName $tag -Path $ComputersOU -Enabled $true @adArgs -WhatIf:$WhatIf
            Add-Result 'Computers' $tag $(if ($WhatIf) { 'WhatIf' } else { 'Created' })
        }
        catch { Add-Result 'Computers' $tag 'Failed' $_.Exception.Message }
    }
}

# --- Étape 1b bis : fusion des comptes de démo dans OU=Utilisateurs ---
if ($Step -in 'MergeUsers', 'All') {
    $demoUsers = Get-ADUser -Filter * -SearchBase $SourceUsersOU -SearchScope OneLevel -Properties MemberOf @adArgs
    foreach ($u in $demoUsers) {
        try {
            $inApp = $u.MemberOf | Where-Object { $_ -like "*,$ApplicationsOU" }
            if (-not $inApp) { Add-Result 'MergeUsers' $u.Name 'Skipped' 'aucun rôle applicatif : compte de test jetable, laissé en place'; continue }
            Move-ADObject -Identity $u.DistinguishedName -TargetPath $AccountsOU @adArgs -WhatIf:$WhatIf
            Add-Result 'MergeUsers' $u.Name $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) "-> $AccountsOU"
        }
        catch { Add-Result 'MergeUsers' $u.Name 'Failed' $_.Exception.Message }
    }
}

# --- Étape 1c : rattrapage des groupes de base (birthright) des Joiners du flux RH ---
if ($Step -in 'Birthright', 'All') {
    $mapping = Get-Content $GroupMappingJson -Raw | ConvertFrom-Json
    # Département ACTUEL : un mover déjà traité par JML doit recevoir les groupes de son nouveau
    # département, pas ceux du département d'arrivée initial (sinon on annulerait son mouvement).
    $moverDept = @{}
    if (Test-Path $MoverFeedCsv) {
        foreach ($m in (Import-Csv $MoverFeedCsv | Where-Object { $_.ActionType -eq 'Mover' })) {
            $moverDept[$m.SamAccountName] = $m.NewDepartment
        }
    }
    foreach ($row in (Import-Csv $HRFeedCsv | Where-Object { $_.ActionType -eq 'Joiner' })) {
        $who = "$($row.FirstName) $($row.LastName)"
        try {
            $user = Get-ADUser -Filter "GivenName -eq '$($row.FirstName)' -and Surname -eq '$($row.LastName)'" `
                -SearchBase $JoinersOU -Properties MemberOf @adArgs | Select-Object -First 1
            if (-not $user) { Add-Result 'Birthright' $who 'Skipped' "introuvable dans $JoinersOU (non créé ou déplacé)"; continue }
            if (-not $user.Enabled) { Add-Result 'Birthright' $who 'Skipped' 'compte désactivé'; continue }
            $dept = if ($moverDept.ContainsKey($user.SamAccountName)) { $moverDept[$user.SamAccountName] } else { $row.Department }
            foreach ($group in @($mapping.$dept)) {
                $g = Get-ADGroup -Identity $group @adArgs
                if ($user.MemberOf -contains $g.DistinguishedName) { Add-Result 'Birthright' "$who -> $group" 'Exists'; continue }
                Add-ADGroupMember -Identity $g -Members $user @adArgs -WhatIf:$WhatIf
                Add-Result 'Birthright' "$who -> $group" $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) $dept
            }
        }
        catch { Add-Result 'Birthright' $who 'Failed' $_.Exception.Message }
    }
}

# --- Étape 2 : comptes admin / service / dormants ---
if ($Step -in 'Accounts', 'All') {
    foreach ($row in (Import-Csv $AccountsCsv)) {
        try {
            if (-not (Test-Missing { Get-ADUser -Identity $row.SamAccountName @adArgs })) {
                Add-Result 'Accounts' $row.SamAccountName 'Exists'
                continue
            }
            $pwd = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
            New-ADUser -Name "$($row.FirstName) $($row.LastName) ($($row.SamAccountName))" `
                -GivenName $row.FirstName -Surname $row.LastName -SamAccountName $row.SamAccountName `
                -UserPrincipalName "$($row.SamAccountName)@$UpnSuffix" -Path $(if ($row.TargetOU) { $row.TargetOU } else { $AccountsOU }) `
                -Department $row.Department -Description $row.Description `
                -AccountPassword $pwd -Enabled ($row.Enabled -eq 'true') @adArgs -WhatIf:$WhatIf
            Add-Result 'Accounts' $row.SamAccountName $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) $row.Description
        }
        catch { Add-Result 'Accounts' $row.SamAccountName 'Failed' $_.Exception.Message }
    }
}

# --- Étape 3 : appartenances de rôle ---
if ($Step -in 'Memberships', 'All') {
    foreach ($row in (Import-Csv $MembershipsCsv)) {
        $label = "$($row.SamAccountName) -> $($row.Role)"
        try {
            $already = Get-ADGroupMember -Identity $row.Role @adArgs -ErrorAction Stop |
                Where-Object { $_.SamAccountName -eq $row.SamAccountName }
            if ($already) { Add-Result 'Memberships' $label 'Exists'; continue }
            Add-ADGroupMember -Identity $row.Role -Members $row.SamAccountName @adArgs -WhatIf:$WhatIf
            Add-Result 'Memberships' $label $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) $row.Anomaly
        }
        catch { Add-Result 'Memberships' $label 'Failed' $_.Exception.Message }
    }
}

# --- Étape 4 : couche AGDLP (G-* globaux, R-* domaine local) ---
if ($Step -in 'Groups', 'All') {
    $groupRows = Import-Csv $GroupsCsv
    foreach ($row in $groupRows) {
        try {
            if (Test-Missing { Get-ADGroup -Identity $row.Group @adArgs }) {
                New-ADGroup -Name $row.Group -SamAccountName $row.Group -GroupScope $row.Scope -GroupCategory Security `
                    -Path $row.Path -Description $row.Description @adArgs -WhatIf:$WhatIf
                Add-Result 'Groups' $row.Group $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) $row.Scope
            }
            else { Add-Result 'Groups' $row.Group 'Exists' }
        }
        catch { Add-Result 'Groups' $row.Group 'Failed' $_.Exception.Message }
    }
    $moverDeptG = @{}
    if (Test-Path $MoverFeedCsv) {
        foreach ($m in (Import-Csv $MoverFeedCsv | Where-Object { $_.ActionType -eq 'Mover' })) { $moverDeptG[$m.SamAccountName] = $m.NewDepartment }
    }
    $joinerPeople = foreach ($j in (Import-Csv $HRFeedCsv | Where-Object { $_.ActionType -eq 'Joiner' })) {
        $u = Get-ADUser -Filter "GivenName -eq '$($j.FirstName)' -and Surname -eq '$($j.LastName)'" -SearchBase $JoinersOU @adArgs | Select-Object -First 1
        if ($u -and $u.Enabled) {
            [PSCustomObject]@{
                Sam  = $u.SamAccountName
                Dept = $(if ($moverDeptG.ContainsKey($u.SamAccountName)) { $moverDeptG[$u.SamAccountName] } else { $j.Department })
            }
        }
    }
    foreach ($row in $groupRows) {
        $members = [System.Collections.Generic.List[string]]::new()
        foreach ($person in ($joinerPeople | Where-Object { $row.Department -and $_.Dept -eq $row.Department })) {
            $members.Add($person.Sam)
        }
        foreach ($m in ($row.MemberSams -split ';' | Where-Object { $_ })) { $members.Add($m) }
        foreach ($m in ($row.MemberGroups -split ';' | Where-Object { $_ })) { $members.Add($m) }
        foreach ($m in $members) {
            $label = "$m -> $($row.Group)"
            try {
                $current = Get-ADGroupMember -Identity $row.Group @adArgs -ErrorAction Stop | Where-Object { $_.SamAccountName -eq $m }
                if ($current) { Add-Result 'Groups' $label 'Exists'; continue }
                Add-ADGroupMember -Identity $row.Group -Members $m @adArgs -WhatIf:$WhatIf
                Add-Result 'Groups' $label $(if ($WhatIf) { 'WhatIf' } else { 'Created' })
            }
            catch { Add-Result 'Groups' $label 'Failed' $_.Exception.Message }
        }
    }
}

# --- Étape 5 : imbrication des profils admin dans les rôles applicatifs ---
if ($Step -in 'Nesting', 'All') {
    foreach ($row in (Import-Csv $NestingCsv)) {
        $label = "$($row.ChildGroup) -> $($row.ParentGroup)"
        try {
            $already = Get-ADGroupMember -Identity $row.ParentGroup @adArgs -ErrorAction Stop |
                Where-Object { $_.SamAccountName -eq $row.ChildGroup }
            if ($already) { Add-Result 'Nesting' $label 'Exists'; continue }
            Add-ADGroupMember -Identity $row.ParentGroup -Members $row.ChildGroup @adArgs -WhatIf:$WhatIf
            Add-Result 'Nesting' $label $(if ($WhatIf) { 'WhatIf' } else { 'Created' }) $row.Note
        }
        catch { Add-Result 'Nesting' $label 'Failed' $_.Exception.Message }
    }
}

# --- Étape 6 : partages réels dont les ACL pointent sur les groupes R-* ---
if ($Step -in 'Shares', 'All') {
    foreach ($row in (Import-Csv $SharesCsv)) {
        $folder = Join-Path $SharesRoot $row.Share
        if ($WhatIf) { Add-Result 'Shares' "\\$ShareServer\$($row.Share)" 'WhatIf' "$($row.Access) pour $($row.Group)"; continue }
        try {
            $outcome = Invoke-Command -ComputerName $ShareServer -Credential $Credential -ErrorAction Stop -ArgumentList $row, $folder, $NetbiosDomain -ScriptBlock {
                param($r, $folder, $domain)
                $step = 'init'
                try {
                    # Comptes intégrés désignés par SID : indépendant de la langue de Windows.
                    $adminSid  = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
                    $adminName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value
                    $account = "$domain\$($r.Group)"
                    $existed = [bool](Get-SmbShare -Name $r.Share -ErrorAction SilentlyContinue)

                    $step = 'création du dossier'
                    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null

                    if (-not $existed) {
                        $step = 'création du partage SMB'
                        if ($r.Access -eq 'Read') {
                            New-SmbShare -Name $r.Share -Path $folder -Description $r.Description -FullAccess $adminName -ReadAccess $account -ErrorAction Stop | Out-Null
                        }
                        else {
                            New-SmbShare -Name $r.Share -Path $folder -Description $r.Description -FullAccess $adminName -ChangeAccess $account -ErrorAction Stop | Out-Null
                        }
                    }

                    # icacls plutôt que Set-Acl : Set-Acl tente aussi de réécrire le propriétaire, ce qui
                    # échoue souvent en session distante (Accès refusé). Rejouable sans effet de bord.
                    $step = 'permissions NTFS (icacls)'
                    $perm = if ($r.Access -eq 'Read') { 'RX' } else { 'M' }
                    $out = & icacls.exe $folder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "${account}:(OI)(CI)$perm" 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "icacls code $LASTEXITCODE : $out" }
                    if ($existed) { return 'Exists' } else { return 'Created' }
                }
                catch { throw "[$step] $($_.Exception.Message)" }
            }
            Add-Result 'Shares' "\\$ShareServer\$($row.Share)" $outcome "$($row.Access) pour $($row.Group)"
        }
        catch { Add-Result 'Shares' $row.Share 'Failed' $_.Exception.Message }
    }
}

$report | Export-Csv -Path $OutputReportCsv -NoTypeInformation -Encoding $csvEncoding
Write-Host "`nRésumé : $(($report | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' | ')" -ForegroundColor Yellow
Write-Host "Rapport : $OutputReportCsv"
