# Audit-Bericht easyADPW

| | |
|---|---|
| **Geprüfte Version** | `easyADPW_V0.0.1.ps1` (Stand nach PR #1, 5.516 Zeilen) |
| **Ergebnis-Version** | `V0.1.0/easyADPW.ps1` |
| **Datum** | 2026-10-14 |
| **Umfang** | Sicherheit, Performance, Funktionen, Verweise, GUI, Befehle, Dokumentation, Repository-Struktur |

Schweregrade: **Kritisch** · **Hoch** · **Mittel** · **Niedrig**. Alle Befunde wurden in Version 0.1.0 behoben (Status ✅), sofern nicht anders angegeben.

## 1. Sicherheit

| ID | Schwere | Befund | Maßnahme | Status |
|---|---|---|---|---|
| SEC-01 | Kritisch | `VerboseDebug = $true` als Standard: Aufrufstapel und Variableninhalte des aufrufenden Scopes (inkl. möglicher Kennwörter) wurden in Konsole und Debug-Log geschrieben. | Entfernt. Optionaler Schalter `-DebugLog` schreibt nur Aktionsnamen und Fehler, nie Variableninhalte. | ✅ |
| SEC-02 | Hoch | Kennwortgenerierung mit `Get-Random` (kein CSPRNG) und verzerrter Auswahl der Zeichengruppen. | `RandomNumberGenerator` mit Rejection Sampling, Fisher-Yates-Mischung, mindestens ein Zeichen je Gruppe. | ✅ |
| SEC-03 | Hoch | Schwache, vorhersagbare Fallback-Kennwörter (`Passw0rd!`+Zufall, `Temp…!`, `Passwort123!`) und hartcodiertes `DefaultPassword = "Passwort1!"`. | Entfernt. Schlägt die Generierung fehl, wird abgebrochen. | ✅ |
| SEC-04 | Hoch | Neues Kennwort im Klartext in MessageBox und Konsole (`Write-Host`/`Write-Information`). | Anzeige nur in maskierter `PasswordBox`, auf Wunsch in schreibgeschütztem Feld; Feld wird beim Schließen/Benutzerwechsel geleert. | ✅ |
| SEC-05 | Hoch | Filter-Injection: Suchbegriffe ungeprüft in `-Filter "… '$Identity'"` und LDAP-Filter (`(Name='…')`, ADSI-Fallback) eingesetzt. | `ConvertTo-ADFilterValue` (`'` → `''`) und `ConvertTo-LdapFilterValue` (RFC 4515) für alle dynamischen Filter. | ✅ |
| SEC-06 | Mittel | HTML-Injection in Berichten (AD-Attribute ungefiltert in HTML). | `WebUtility.HtmlEncode` für alle Werte, Content-Security-Policy im Bericht. | ✅ |
| SEC-07 | Mittel | Berichte mit Klartext-Kennwörtern in ungeschütztem Ordner `Reports\` (erbt Rechte des Skriptordners). | ACL auf aktuellen Benutzer, Administratoren, SYSTEM (abschaltbar), Hinweis auf Vertraulichkeit im Bericht, `.gitignore`. | ✅ |
| SEC-08 | Mittel | Massenvorgänge konnten das eigene Konto, `krbtgt` und privilegierte Konten (`adminCount=1`) zurücksetzen. | Automatisches Überspringen inkl. Ausweis im Bericht; eigenes Kennwort/Deaktivieren des eigenen Kontos im Einzelmodus gesperrt. | ✅ |
| SEC-09 | Mittel | Kein Bestätigungsdialog beim Einzel-Reset und bei Kontooptionen. | Bestätigung (Standard „Nein“) vor jeder AD-Änderung, zusätzliche Warnung bei privilegierten Konten. | ✅ |
| SEC-10 | Mittel | ADSI-Fallback erzeugte fiktive Benutzerobjekte (`CN=…,DC=fallback,DC=local`), auf die anschließend Aktionen ausgeführt wurden. | Fallback entfernt; ohne ActiveDirectory-Modul startet das Tool mit Hinweis zur RSAT-Installation nicht. | ✅ |
| SEC-11 | Mittel | Beim Beenden wurden **alle** PowerShell-Jobs der Sitzung gestoppt/entfernt und temporäre Dateien gelöscht. | Entfernt; es werden nur eigene Ressourcen (RNG, Kennwortfelder) freigegeben. | ✅ |
| SEC-12 | Niedrig | Authenticode-Signatur nach Änderungen (PR #1) ungültig. | Ungültigen Signaturblock entfernt; Anleitung zum Signieren in `SECURITY.md`. | ⚠️ Signatur durch Maintainer erforderlich |
| SEC-13 | Niedrig | Footer-URL ohne Prüfung an `Start-Process` übergeben. | Nur absolute `http`/`https`-URIs werden geöffnet. | ✅ |
| SEC-14 | Niedrig | FGPP mit umkehrbarer Verschlüsselung ohne Warnung anlegbar. | Zusätzliche Warnung/Bestätigung, Bewertung „Kritisch“ in der Richtlinienansicht. | ✅ |
| SEC-15 | Niedrig | „Optionen übernehmen“ setzte immer `ChangePasswordAtLogon = $false` und entfernte damit stillschweigend eine erzwungene Kennwortänderung. | Nur geänderte Werte werden gesendet, Zustand wird aus dem AD gelesen. | ✅ |

## 2. Funktionen und Fehler

| ID | Schwere | Befund | Maßnahme | Status |
|---|---|---|---|---|
| FUN-01 | Hoch | `Reset-GroupPasswords` enthielt kopierte Entsperr-Logik; Bericht wurde nicht angeboten. | Gemeinsame Funktion `Invoke-BulkPasswordReset` für OU und Gruppe. | ✅ |
| FUN-02 | Hoch | `Edit-FGPP`: `[ref]$params.Precedence` schreibt nicht in die Hashtable (Priorität/Länge/Historie gingen verloren), `$minAgeDays` nicht initialisiert, `Compare-Object` scheitert bei leerem `AppliesTo`, Speichern wirkte auf die aktuell markierte Zeile. | `Read-FGPPForm` mit Validierung, Bearbeitungsziel wird beim Öffnen gespeichert, Delta der Zielgruppen über `-notcontains`. | ✅ |
| FUN-03 | Hoch | OU entsperren mit `Get-ADUser -Filter {LockedOut -eq $true}` – `LockedOut` ist nicht filterbar. | `Search-ADAccount -LockedOut -UsersOnly`. | ✅ |
| FUN-04 | Mittel | Kennwortablauf mit `FromFileTime($null)` berechnet (`pwdLastSet` nicht geladen), FGPP ignoriert. | `msDS-UserPasswordExpiryTimeComputed`. | ✅ |
| FUN-05 | Mittel | Skriptende: Nach dem Schließen des Fensters wurde das XAML erneut geladen und `return $window` ausgeführt; ca. 850 Zeilen toter bzw. defekter Code (`Initialize-GUI-Safe`, `Exit-Application`, Lokalisierung, `Register-ExitHandlers` mit `$MyInvocation…Module = $null`). | Entfernt; klarer Ablauf Initialisierung → `ShowDialog()` → Aufräumen. | ✅ |
| FUN-06 | Mittel | `Write-DebugMessage` doppelt definiert. | Eine zentrale Protokollfunktion `Write-AppLog`. | ✅ |
| FUN-07 | Mittel | `Show-PasswordPolicies` nutzte nicht definiertes `$fgppPolicies` und rief die Richtlinie doppelt ab. | Neu implementiert (`Show-DomainPasswordPolicy`). | ✅ |
| FUN-08 | Mittel | Gelöschte FGPP mit „Schutz vor versehentlichem Löschen“ schlugen fehl. | Schutz wird nach Bestätigung aufgehoben. | ✅ |
| FUN-09 | Niedrig | In `catch`-Blöcken der Massenvorgänge wurden Daten des vorherigen Benutzers protokolliert. | Fehler werden pro Benutzer erfasst. | ✅ |
| FUN-10 | Niedrig | Versionsangabe im Bericht hartcodiert (`0.2`), Log entfernte Umlaute. | `$script:AppVersion`, UTF-8-Log. | ✅ |
| FUN-11 | Niedrig | `ChangePasswordAtLogon` schlug bei „Kennwort läuft nie ab“ ohne Hinweis fehl. | Hinweis im Status und Bericht; Kombination in den Optionen blockiert. | ✅ |
| FUN-12 | Mittel | Gruppen wurden per Anzeigename gesucht (`-First 1`); bei gleichnamigen Gruppen in verschiedenen OUs konnte die falsche Gruppe verarbeitet werden. | Auswahl trägt den DN, Auflösung per `-Identity`; doppelte Namen werden mit Pfad angezeigt. | ✅ |
| FUN-13 | Mittel | War der Berichtsordner nicht beschreibbar, gingen beim Massen-Reset alle neuen Kennwörter verloren. | Ordner wird vor dem Reset geprüft, Fallback ins Benutzerprofil, sonst Abbruch vor Änderungen. | ✅ |

## 3. Performance

| ID | Befund | Maßnahme | Status |
|---|---|---|---|
| PERF-01 | OU-Baum: eine LDAP-Abfrage pro OU (rekursiv). | Eine Abfrage `Get-ADOrganizationalUnit -Filter *`, Baumaufbau über Parent-DN-Dictionary. | ✅ |
| PERF-02 | Gruppen-Reset/-Anzeige: `Get-ADUser` pro Mitglied (N+1). | Eine LDAP-Abfrage über `memberOf`/`primaryGroupID`. | ✅ |
| PERF-03 | Gruppenliste doppelt geladen, Einträge einzeln per `Items.Add`. | Einmal laden, zwischenspeichern, `ItemsSource` + Virtualisierung. | ✅ |
| PERF-04 | OU-Reset fragte jeden Benutzer erneut ab. | Alle benötigten Attribute in einer Abfrage. | ✅ |
| PERF-05 | Alle Registerkarten wurden beim Start geladen bzw. gar nicht. | Lazy Loading beim ersten Öffnen, „Aktualisieren“-Schaltflächen. | ✅ |
| PERF-06 | Import des AD-Moduls inkl. `AD:`-Laufwerk. | `ADPS_LoadDefaultDrive = 0`. | ✅ |
| PERF-07 | GUI friert bei langen Vorgängen ohne Rückmeldung ein. | Wartecursor, Fortschritt im Statusfeld, Sperre gegen Mehrfachausführung. | ✅ |
| PERF-08 | Benutzersuche mit führenden Platzhaltern über mehrere Attribute. | Exakte Suche, sonst indizierte ANR-Suche mit Trefferlimit. | ✅ |

## 4. GUI

| ID | Befund | Maßnahme | Status |
|---|---|---|---|
| GUI-01 | Referenzierte Steuerelemente (`btnSingleUser`, `btnOU`, `btnGroup`, `btnPolicies`, `btnFGPP`, `HeaderLogo`, `lblADStatus`) existierten nicht; dadurch luden Richtlinien- und FGPP-Tab nie automatisch. | XAML und Code abgeglichen; alle Steuerelemente werden automatisch gebunden, fehlende führen zu einem klaren Fehler. | ✅ |
| GUI-02 | Feste Fenstergröße 1250 × 950 (`CanMinimize`) – passt nicht auf 1366 × 768. | Skalierbar, Mindestgröße 1000 × 720. | ✅ |
| GUI-03 | Ungenutzte Styles mit `{Binding ThemeColor}`, leere Navigationsspalte, eingeklappte Tabs. | Entfernt; Theme-Farbe wird per Code gesetzt. | ✅ |
| GUI-04 | Keine Suche per Enter, kein Auswahl-Dialog-Besitzer, Schaltflächen ohne Benutzer aktiv. | Enter startet Suche, Dialoge mit Owner, Schaltflächen erst nach Auswahl aktiv. | ✅ |
| GUI-05 | Keine Anzeige des AD-Verbindungsstatus. | Domäne und PDC in der Kopfzeile. | ✅ |

## 5. Befehle und Kompatibilität

| ID | Befund | Maßnahme | Status |
|---|---|---|---|
| CMD-01 | Veraltete Aufrufe `[Reflection.Assembly]::LoadWithPartialName`, `Get-WmiObject` (nicht in PowerShell 7). | `Add-Type -AssemblyName`, Aufrufe entfernt. | ✅ |
| CMD-02 | Keine STA-/Windows-Prüfung. | Prüfung beim Start mit verständlicher Meldung. | ✅ |
| CMD-03 | Nicht freigegebene/zustandsändernde Verben ohne `ShouldProcess`. | Freigegebene Verben, `SupportsShouldProcess` für AD-ändernde Funktionen; PSScriptAnalyzer ohne Befund. | ✅ |

## 6. Verweise, Dokumentation und Repository

| ID | Befund | Maßnahme | Status |
|---|---|---|---|
| DOC-01 | README verwies auf das alte Repository `PS-easyIT/easyADPW` (Screenshot) und beschrieb nicht vorhandene Funktionen (mehrsprachige GUI, Logo-URL) sowie falsche Tab-Namen. | README neu, zweisprachig, korrekte Verweise auf `PS-PhinIT`. | ✅ |
| DOC-02 | RSAT-Installationsbefehl nur für Server. | Befehle für Client und Server. | ✅ |
| DOC-03 | Kein CHANGELOG, keine SECURITY-/CONTRIBUTING-Richtlinie, keine Vorlagen. | `CHANGELOG.md` (aus Git-Historie und PRs), `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, Issue-/PR-Vorlagen, `VERSION`. | ✅ |
| DOC-04 | Versionsnummer im Dateinamen, Screenshots in `# Screenshots/`. | Versionsordner `V0.1.0/`, alte Version und alle Screenshots gelöscht, `docs/screenshots/` für neue Screenshots. | ✅ |
| DOC-05 | `.gitignore` deckte nur `/Reports` ab. | `Reports/`, `Logs/`, `*.log`. | ✅ |

## 7. Prüfungen

- PowerShell-Parser: keine Fehler.
- PSScriptAnalyzer 1.25 (alle Standardregeln, Schweregrade Error/Warning/Information): keine Befunde.
- XAML: wohlgeformt, alle 63 benannten Steuerelemente werden im Code verwendet, keine Referenz auf nicht vorhandene Steuerelemente.
- Funktionstests (PowerShell 7): Filter-Maskierung, HTML-Kodierung, DN-Parsing, Kennwortablauf, Gleichverteilung des Zufallsgenerators, Kennwortlänge/-zeichengruppen/Eindeutigkeit, Richtlinienbewertung, Schutzkonten-Erkennung, Berichtserstellung.

**Offen:** Ausführung der WPF-Oberfläche in einer Windows-Testdomäne und Signatur des Skripts durch den Maintainer.
