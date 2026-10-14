# easyADPW – Active Directory Password Management Tool

![PSScriptAnalyzer](https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/actions/workflows/powershell.yml/badge.svg)
![Version](https://img.shields.io/badge/version-0.1.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

**DE:** PowerShell-WPF-Oberfläche (`easyPASSWORDRESET`) zum sicheren Zurücksetzen von Active-Directory-Kennwörtern, Entsperren von Konten, Setzen von Kontooptionen für Benutzer, OUs und Gruppen sowie zur Verwaltung von Fine-Grained Password Policies (FGPP) – inkl. HTML-/TXT-Berichten.

**EN:** PowerShell WPF GUI (`easyPASSWORDRESET`) to securely reset Active Directory passwords, unlock accounts, set account options for users, OUs and groups and manage Fine-Grained Password Policies (FGPP) – including HTML/TXT reports.

> Screenshots der aktuellen Version folgen in [`docs/screenshots/`](docs/screenshots/). / Screenshots of the current version will be added to `docs/screenshots/`.

---

## 📁 Repository-Struktur / Repository structure

```text
PhinIT.PowerShell_ADPassword/
├── V0.1.0/
│   └── easyADPW.ps1          # Anwendung / application (aktuelle Version)
├── docs/
│   ├── AUDIT.md              # Audit-Bericht (Sicherheit, Performance, Funktionen, GUI …)
│   └── screenshots/          # Screenshots der aktuellen Version
├── .github/                  # Workflows (PSScriptAnalyzer, Codacy), Issue-/PR-Vorlagen
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── VERSION
├── LICENSE
└── README.md
```

Zur Laufzeit legt das Skript neben sich die Ordner `Logs\` und `Reports\` an (beide in `.gitignore`).

---

## 🔧 Funktionen / Features

| Registerkarte / Tab | Deutsch | English |
|---|---|---|
| **Einzelbenutzer** | Suche (Anmeldename, UPN, Name – exakt bzw. ANR), Kennwort-Reset mit Zufallskennwort, Entsperren, Kontooptionen (Kennwort läuft nie ab, kann nicht ändern, Konto aktiviert, Änderung bei nächster Anmeldung) | Search (logon name, UPN, name – exact or ANR), password reset with random password, unlock, account options |
| **OU / Gruppe** | Massen-Reset und Massen-Entsperrung für eine OU (optional inkl. Unter-OUs) oder die direkten Benutzer-Mitglieder einer Gruppe | Bulk reset / unlock for an OU (optionally incl. child OUs) or the direct user members of a group |
| **Kennwortrichtlinie** | Anzeige der Standard-Domänenkennwortrichtlinie mit Empfehlung und Bewertung | Default domain password policy with recommendation and rating |
| **Fine-Grained Password Policies** | FGPP anzeigen, erstellen, bearbeiten (inkl. Zielgruppen) und löschen | List, create, edit (incl. target groups) and delete FGPPs |

Weitere Eigenschaften / Further characteristics:

- Kennwörter aus kryptografisch sicherem Zufallsgenerator (`RandomNumberGenerator`), Standardlänge 16, mindestens ein Zeichen je Zeichengruppe. / Passwords from a cryptographically secure RNG.
- Kennwörter werden **nie** protokolliert und nur als `SecureString` verarbeitet; Klartext nur für Anzeige und Bericht. / Passwords are never logged.
- Massenvorgänge überspringen das eigene Konto, `krbtgt`, das integrierte Administratorkonto und (konfigurierbar) geschützte Konten mit `adminCount=1`. / Bulk operations skip protected accounts.
- Bestätigungsdialoge vor jeder Änderung im AD. / Confirmation before every AD change.
- HTML- und TXT-Berichte in `Reports\`; der Ordner wird auf aktuellen Benutzer, Administratoren und SYSTEM beschränkt. / Reports folder is ACL-restricted.
- Logdatei `Logs\easyPASSWORDRESET.log` mit Rotation (Standard 10 MB). / Rotating log file.

Die Oberfläche ist auf **Deutsch**. / The GUI is in **German**.

---

## 📋 Voraussetzungen / Requirements

- Windows 10/11 oder Windows Server 2016+ / Windows 10/11 or Windows Server 2016+
- Windows PowerShell 5.1 oder PowerShell 7.x (STA-Modus) / Windows PowerShell 5.1 or PowerShell 7.x (STA)
- RSAT-Modul **ActiveDirectory** / RSAT **ActiveDirectory** module
- Domänenmitgliedschaft und delegierte Rechte (Kennwort zurücksetzen, `lockoutTime`/`userAccountControl` schreiben; FGPP: Schreibrechte im *Password Settings Container*, i. d. R. Domänen-Admins) / Domain membership and delegated permissions

RSAT installieren / install RSAT:

```powershell
# Windows 10/11 (Client)
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# Windows Server
Install-WindowsFeature RSAT-AD-PowerShell
```

---

## 🚀 Start / Usage

```powershell
cd .\V0.1.0
powershell.exe -STA -ExecutionPolicy RemoteSigned -File .\easyADPW.ps1

# Mit Debug-Einträgen im Log (enthält keine Kennwörter) / with debug log entries
powershell.exe -STA -ExecutionPolicy RemoteSigned -File .\easyADPW.ps1 -DebugLog
```

`pwsh.exe` (PowerShell 7) läuft standardmäßig im STA-Modus. / `pwsh.exe` runs in STA by default.

---

## ⚙️ Konfiguration / Configuration

Die Einstellungen stehen im Hashtable `$script:Config` am Anfang von `easyADPW.ps1`:

| Schlüssel / Key | Standard / Default | Beschreibung / Description |
|---|---|---|
| `AppName`, `ThemeColor`, `FooterText`, `FooterWebsite` | `easyPASSWORDRESET`, `#0078D7`, … | Branding (Website nur `http`/`https`) |
| `LogFolder`, `LogFileName`, `LogMaxSizeMB` | `<Skriptordner>\Logs`, `easyPASSWORDRESET.log`, `10` | Protokollierung (Fallback `%TEMP%\easyPASSWORDRESET`) |
| `ReportFolder`, `RestrictReportFolderAcl` | `<Skriptordner>\Reports`, `$true` | Berichtsordner und ACL-Beschränkung |
| `DefaultPasswordLength`, `MinimumPasswordLength` | `16`, `12` | Kennwortlänge |
| `UseUppercase`, `UseLowercase`, `UseNumbers`, `UseSpecialChars`, `SpecialChars` | `$true` … | Zeichengruppen (ohne verwechselbare Zeichen `I l 1 O 0`) |
| `RequirePasswordChangeAfterReset` | `$true` | „Kennwort bei nächster Anmeldung ändern“ nach Reset |
| `ExcludeProtectedAccountsFromBulk` | `$true` | Konten mit `adminCount=1` bei Massenvorgängen überspringen |
| `MaxSearchResults` | `200` | Maximale Treffer der Benutzersuche |

---

## 🔐 Sicherheit / Security

- Berichte enthalten Kennwörter im Klartext – nach der Übergabe sicher löschen. / Reports contain plaintext passwords – delete them after hand-over.
- Das Skript ist in Version 0.1.0 **nicht signiert**. Für `AllSigned`-Umgebungen bitte mit dem eigenen Code-Signing-Zertifikat signieren (siehe [SECURITY.md](SECURITY.md) und [PS-PhinIT/PhinIT.Certificate](https://github.com/PS-PhinIT/PhinIT.Certificate)). / The script is unsigned in 0.1.0.
- Sicherheitslücken bitte gemäß [SECURITY.md](SECURITY.md) melden. / Report vulnerabilities according to SECURITY.md.

---

## 📚 Weitere Dokumente / Further documents

- [CHANGELOG.md](CHANGELOG.md) – Versionshistorie / version history
- [docs/AUDIT.md](docs/AUDIT.md) – Audit-Bericht zu Version 0.1.0 / audit report
- [CONTRIBUTING.md](CONTRIBUTING.md) – Mitwirken / contributing
- [SECURITY.md](SECURITY.md) – Sicherheitsrichtlinie / security policy
- [LICENSE](LICENSE) – MIT

---

## 👤 Autor / Author

**PHiNiT** – [www.phinit.de](https://www.phinit.de) – [github.com/PS-PhinIT](https://github.com/PS-PhinIT)
