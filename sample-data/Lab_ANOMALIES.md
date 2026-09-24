# Anomalies volontaires du lab (manifeste)

Chaque anomalie ci-dessous est **posée exprès** dans l'annuaire par `Expand-LabApplications.ps1`
(données dans `Lab_Memberships.csv`, `Lab_Accounts.csv`, `Lab_Groups.csv`, `Lab_Nesting.csv`) ou par le flux RH `HR_Feed_Banque.csv`. Ce
manifeste sert de jeu de tests : après avoir relancé les outils, chaque ligne doit ressortir.

| ID | Anomalie | Comptes / objets | Outil censé la détecter |
|---|---|---|---|
| A01 | SoD Crédit : Analyste + Décisionnaire | `mchevalier` | `Find-SoDViolations.ps1` (règle « Crédit — Analyste + Décisionnaire ») |
| A02 | SoD 4 yeux Paiements : Initiateur + Validateur | `dfabre` | `Find-SoDViolations.ps1` |
| A03 | SoD inter-applications : Admin Coeur bancaire + Validateur Paiements (+ Initiateur) | `bhenry` | `Find-SoDViolations.ps1` |
| A04 | SoD Trésorerie : Front-office + Back-office | `eloiseau` | `Find-SoDViolations.ps1` |
| A05 | SoD : Opérateur Coeur bancaire + Validateur KYC | `jmasson` | `Find-SoDViolations.ps1` |
| A06 | Admin sur 2 applications ou plus : Risques + Monétique (`fguillot`), IT + Sécurité (`naubert`, cf. A13), Dev + Coeur bancaire (`eriou`, cf. A14) | `fguillot`, `naubert`, `eriou` | `Find-CrossAppAdminOverlap.ps1` |
| A07 | SoD : Approbateur Comptabilité + Initiateur Paiements | `jbarre` | `Find-SoDViolations.ps1` |
| A08 | Mover mal traité : Agences → Conformité, garde `CRM-Lecture` | `hguerin` | Revue de campagne (`New-CertificationCampaign.ps1`) — cas témoin propre : `nperrin` |
| A09 | Rôle vide : `Credit-Legacy-Admin` (0 membre) | groupe | `Find-AlibiRoles.ps1` |
| A10 | Rôle quasi vide : `Monetique-Legacy-Operateur` (1 membre, ancien collaborateur) | groupe | `Find-AlibiRoles.ps1` |
| A11 | Leaver sans restitution du matériel | `ozimmer` (`EquipmentReturned=false`) | Objet ordinateur `LAPTOP-OZIMMER` désactivé, description « Statut: NonRendu » (posé par `Set-DeviceStatus.ps1`) ; à voir dans le rapport `JML_Run_Report_*.csv` d'un lot rejoué depuis zéro |
| A13 | SoD IT : Admin IT + Admin Sécurité | `naubert` | `Find-SoDViolations.ps1` (règle « IT — Admin IT + Admin Sécurité ») |
| A14 | SoD DevOps : Admin Dev + Admin Coeur bancaire (production) | `eriou` | `Find-SoDViolations.ps1` |
| A15 | SoD Achats : Manager Achats + Approbateur Comptabilité | `slopes` | `Find-SoDViolations.ps1` |
| A16 | SoD masqué par groupe imbriqué : `cdurand` (Validateur Paiements) ajouté par erreur au profil `G-ROLE-COREBANKING-ADMIN`, donc Admin Coeur bancaire indirect | `cdurand` | `Find-SoDViolations.ps1` sur un audit produit avec `Get-LdapAppRoleAudit.ps1 -ResolveNested` (invisible sans ce commutateur) |
| A12 | Comptes dormants / orphelins avec accès conservés | `legacy-admin`, `former-employee`, `old-user01`, `old-user02`, `stagiaire-2023`, `test-user` | **Non couvert par les outils actuels** : candidat à une évolution (détection de comptes dormants) |

Cas témoins sans anomalie : `nperrin` (mover propre), `llemaire` (leaver propre, matériel rendu),
`tlambert` (matériel perdu puis retrouvé).

Points à savoir en relançant les outils :

- **Accès indirects (imbrication) :** les 7 comptes `adm-*` ne sont plus membres directs des rôles
  Admin : ils sont dans un profil `G-ROLE-*`, lui-même membre du rôle (`Expand-LabApplications.ps1
  -Step Nesting`). Pour voir les personnes, lancer l'audit avec `-ResolveNested`. Sans ce
  commutateur, le rôle affiche le nom du groupe (`G-ROLE-CREDIT-ADMIN`) et les outils SoD/alibi
  ne voient pas les personnes derrière.

- L'audit LDAP affiche les membres par **nom d'objet (CN)**, pas par identifiant : `Maxime Chevalier`
  et non `mchevalier` pour les comptes créés par JML, `Christophe Bonnin (adm-cbonnin)` pour les
  comptes admin. Les identifiants de ce manifeste sont donc à rapprocher du nom affiché.
- `Find-AlibiRoles.ps1` signale tout rôle à 0 ou 1 membre (seuil par défaut). Il remontera donc
  aussi des rôles Admin à un seul administrateur (`Credit-Admin`, `KYC-Admin`, `Paiements-Admin`,
  `Tresorerie-Admin`, `Helpdesk-Admin`, `Risques-Admin`, ...) : ce sont des candidats à arbitrer en
  revue, pas des anomalies plantées. Seuls A09 et A10 sont voulus.
- Les objets ordinateur des `AssetTag` du flux RH doivent exister avant le lot JML
  (`Expand-LabApplications.ps1 -Step Computers`).

Chaîne AGDLP (accès aux ressources) : un utilisateur accède à un partage uniquement via
`G-<Département>` (global) -> `R-SHARE-*` (domaine local) -> permissions du dossier partagé sur
`\\DC1\<partage>` (`Expand-LabApplications.ps1 -Step Shares`). Cette chaîne est fonctionnelle
mais n'est vérifiée par aucun outil du portfolio : c'est une base réaliste, pas une anomalie.

Limite connue : `lastLogonTimestamp` n'est pas modifiable dans AD ; l'ancienneté des comptes
dormants est portée par leur description, pas par une vraie date de dernière connexion.
