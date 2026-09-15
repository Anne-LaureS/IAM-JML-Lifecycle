# 🔄 IAM JML Lifecycle

![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![ActiveDirectory](https://img.shields.io/badge/Active%20Directory-0078D4?style=for-the-badge&logo=windows&logoColor=white)
![IAM](https://img.shields.io/badge/IAM-Identity%20Lifecycle-0d1117?style=for-the-badge)

Automatisation Joiner/Mover/Leaver (JML) sur Active Directory — la brique qui referme le cycle
de vie identité que [LDAP-App-Role-Audit](https://github.com/Anne-LaureS/LDAP-App-Role-Audit)
et [IAM-Access-Recertification](https://github.com/Anne-LaureS/IAM-Access-Recertification)
laissent ouverte : ces deux repos détectent et décident quoi révoquer, celui-ci exécute
réellement la création, la modification et la désactivation des comptes dans l'annuaire.

Testé contre le même lab Active Directory (Windows Server 2022, `DC1.society.local`) que
LDAP-App-Role-Audit.

## ⚙️ Les scripts

| # | Script | Rôle | Sortie |
|---|---|---|---|
| — | [`New-Joiner.ps1`](New-Joiner.ps1) | Crée un compte et lui attribue son accès de base selon son département | Objet résultat (SamAccountName, mot de passe temporaire, groupes assignés) |
| — | [`Update-Mover.ps1`](Update-Mover.ps1) | Retire les groupes de l'ancien département, ajoute ceux du nouveau | Objet résultat (groupes retirés/ajoutés) |
| — | [`Disable-Leaver.ps1`](Disable-Leaver.ps1) | Retire tous les accès, désactive le compte, le déplace dans OU=Leavers | Objet résultat (groupes retirés, action matériel éventuelle) |
| — | [`Set-DeviceStatus.ps1`](Set-DeviceStatus.ps1) | Active/désactive un objet ordinateur AD (perdu/retrouvé/non rendu) | Objet résultat (action, statut) |
| — | [`Invoke-JMLBatch.ps1`](Invoke-JMLBatch.ps1) | Orchestrateur : lit un CSV RH et dispatche chaque ligne vers le script adapté | `JML_Run_Report_AAAA-MM-JJ.csv` |

Les 4 premiers scripts sont indépendants et directement utilisables un par un (paramètres
explicites, pas besoin de passer par l'orchestrateur pour traiter un seul cas). L'orchestrateur
sert à traiter un lot — le cas réel d'un export RH périodique.

## ⚙️ Pipeline

```
Export RH (CSV) --> Invoke-JMLBatch.ps1 --dispatch par ActionType-->
    Joiner      --> New-Joiner.ps1       --> compte créé + accès de base
    Mover       --> Update-Mover.ps1     --> accès mis à jour
    Leaver      --> Disable-Leaver.ps1   --> compte désactivé, accès retiré
                        │
                        └──► si matériel non rendu ──► Set-DeviceStatus.ps1 (NonRendu)
    DeviceLost  --> Set-DeviceStatus.ps1 (Perdu)
    DeviceFound --> Set-DeviceStatus.ps1 (Retrouve)
                                    │
                                    ▼
                        JML_Run_Report_AAAA-MM-JJ.csv
```

## ▶️ Utilisation

Les commandes ci-dessous s'exécutent depuis la racine du repo et sont directement à
copier-coller (adapter les valeurs FirstName/LastName/Department à votre cas).

### Un cas isolé

```powershell
.\New-Joiner.ps1 -FirstName "Alice" -LastName "Fontaine" -Department "CRM"
```

```powershell
.\Update-Mover.ps1 -SamAccountName "afontaine" -OldDepartment "CRM" -NewDepartment "ERP"
```

```powershell
.\Disable-Leaver.ps1 -SamAccountName "kbenatia" -AssetTag "LAPTOP-KBENATIA" -EquipmentReturned:$false
```

```powershell
.\Set-DeviceStatus.ps1 -AssetTag "LAPTOP-AFONTAINE" -Reason Perdu
```

Chaque script demande les identifiants du bind AD interactivement (`Get-Credential`) s'ils ne
sont pas fournis via `-Credential`, et supporte `-WhatIf` pour simuler sans rien écrire dans
l'annuaire.

### Un lot (export RH)

```powershell
.\Invoke-JMLBatch.ps1 -HRFeedCsv .\sample-data\HR_Feed_Sample.csv -OutputReportCsv .\JML_Run_Report.csv
```

Demande les identifiants **une seule fois** pour tout le lot, puis dispatche chaque ligne du
CSV vers le script correspondant selon la colonne `ActionType` (`Joiner`, `Mover`, `Leaver`,
`DeviceLost`, `DeviceFound`) — voir [`sample-data/HR_Feed_Sample.csv`](sample-data/HR_Feed_Sample.csv)
pour le schéma complet des colonnes. Une ligne en échec n'interrompt pas le traitement des
suivantes.

Par défaut, `-OutputReportCsv` est nommé avec la date du jour
(`JML_Run_Report_AAAA-MM-JJ.csv`) — utile en usage réel (une trace par exécution), mais la
commande ci-dessus fixe volontairement un nom constant pour que l'exemple reste copiable sans
changer de date.

## 📊 Exemple de bout en bout

Avec les données d'exemple ([`sample-data/HR_Feed_Sample.csv`](sample-data/HR_Feed_Sample.csv)
— 2 Joiners, 1 Mover, 1 Leaver avec matériel non rendu, 1 cycle perdu/retrouvé), résultat réel
obtenu contre le lab AD (`DC1.society.local`) en exécutant la commande ci-dessus :

| Ligne | Résultat |
|---|---|
| Joiner Alice Fontaine (CRM) | Compte `afontaine` créé, groupe `CRM-Lecture` assigné |
| Joiner Karim Benatia (RH) | Compte `kbenatia` créé, groupe `RH-Standard` assigné |
| Mover `afontaine` (CRM → ERP) | `CRM-Lecture` retiré, `ERP-Utilisateur` ajouté |
| DeviceLost `LAPTOP-AFONTAINE` | Objet ordinateur désactivé |
| DeviceFound `LAPTOP-AFONTAINE` | Objet ordinateur réactivé |
| Leaver `kbenatia` (matériel non rendu) | Groupe `RH-Standard` retiré, compte désactivé et déplacé vers `OU=Leavers`, `LAPTOP-KBENATIA` désactivé |

**6 lignes traitées, 6 succès, 0 échec** — [`JML_Run_Report.csv`](JML_Run_Report.csv) (mot de
passe temporaire retiré du fichier avant publication).

![Identifiants demandés une seule fois pour tout le lot](screenshots/credential-prompt.png)

![Exécution des 6 lignes du batch en console](screenshots/terminal-run.png)

### Mapping département → accès

[`department-group-mapping.json`](department-group-mapping.json) associe chaque département à
son (ses) groupe(s) AD de base — repris tels quels des groupes déjà audités par
LDAP-App-Role-Audit et recertifiés par IAM-Access-Recertification, pour que le compte créé ici
ait exactement l'accès que les deux autres repos savent auditer et recertifier ensuite.
Volontairement limité aux rôles "Standard"/"Lecture" — l'élévation vers un rôle Admin se
demande séparément, le birthright reste du moindre privilège.

## 🔐 Sécurité & précautions

- Comptes créés dans `OU=Utilisateurs,DC=society,DC=local` — une OU dédiée, vide, distincte à
  la fois de `CN=Users` (conteneur intégré : Administrator, Domain Admins, et autres objets
  système par défaut) et de `OU=Utilisateurs-Test` qui contient les 21 comptes de démo
  LDAP-App-Role-Audit (on ne veut mélanger ni l'un ni l'autre).
- Écritures via le module `ActiveDirectory` (`New-ADUser`, `Add/Remove-ADPrincipalGroupMembership`,
  `Disable/Enable-ADAccount`...) plutôt que du LDAP brut comme LDAP-App-Role-Audit — ce dernier
  reste agnostique du schéma pour un usage en lecture seule, mais pour des écritures réelles
  (création de compte, pose de mot de passe) le module AD est l'outil réellement utilisé en
  entreprise pour ce cas, plus sûr qu'un `ModifyRequest` LDAP brut avec mot de passe encodé
  manuellement en UTF-16LE.
- Mot de passe temporaire généré aléatoirement (respect de la complexité AD par défaut),
  `ChangePasswordAtLogon` forcé — jamais de mot de passe fixe/prévisible.
- `Disable-Leaver.ps1` désactive le compte utilisateur ET, si un poste non rendu est déclaré,
  désactive aussi l'objet ordinateur correspondant (`Set-DeviceStatus.ps1 -Reason NonRendu`) —
  un compte désactivé ne bloque pas un poste qui garde une session locale en cache.
- Chaque script retourne un objet résultat structuré et n'interrompt jamais un traitement en
  lot sur une erreur individuelle (try/catch systématique).
- `-WhatIf` supporté de bout en bout (scripts unitaires et orchestrateur) pour dry-run avant
  toute écriture réelle contre l'annuaire.
- **Fichiers `.ps1`/`.json`/`.csv` en UTF-8 avec BOM** dès leur création, comme le reste du
  portfolio — Windows PowerShell 5.1 lit mal les accents sans ce marqueur en tête de fichier.
