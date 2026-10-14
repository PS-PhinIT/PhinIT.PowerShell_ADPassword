# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionierung an [Semantic Versioning](https://semver.org/lang/de/).
Die Einträge vor 0.1.0 wurden aus der Git-Historie und den Pull Requests des Repositorys rekonstruiert.

## [0.1.0] - 2026-10-14

Vollständiges Audit (Sicherheit, Performance, Funktionen, Verweise, GUI, Befehle) mit Neustrukturierung des Repositorys. Details zu allen Befunden: [docs/AUDIT.md](docs/AUDIT.md).

### Hinzugefügt
- Neue, konsolidierte Anwendung `V0.1.0/easyADPW.ps1` (Versionsordner statt Versionsnummer im Dateinamen).
- Parameter `-DebugLog` für zusätzliche Debug-Einträge (ohne Kennwörter).
- Schutz bei Massenvorgängen: eigenes Konto, `krbtgt`, integriertes Administratorkonto und Konten mit `adminCount=1` werden übersprungen und im Bericht ausgewiesen.
- Option „Unter-OUs einbeziehen“ und Schaltfläche „Aktualisieren“ für OU-/Gruppenvorgänge.
- Bestätigungsdialoge für Einzel-Reset, Kontooptionen, Massenvorgänge sowie FGPP erstellen/speichern/löschen.
- Anzeige des AD-Verbindungsstatus (Domäne, PDC) und der Version in der Kopfzeile.
- Bewertung der Domänenkennwortrichtlinie anhand aktueller Empfehlungen (Microsoft-Sicherheitsbaseline, NIST SP 800-63B).
- Bearbeiten von FGPP per Doppelklick, Validierung aller FGPP-Eingaben.
- Ordner `Reports\` wird per ACL auf aktuellen Benutzer, Administratoren und SYSTEM beschränkt.
- Logrotation (Standard 10 MB) und UTF-8-Protokollierung inklusive Umlauten.
- Dokumentation: `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md`, `VERSION`, `docs/AUDIT.md`, `docs/screenshots/README.md`, Issue- und Pull-Request-Vorlagen.

### Geändert
- `Readme.md` in `README.md` umbenannt und inhaltlich korrigiert (Registerkarten, Voraussetzungen, RSAT-Installation für Client und Server, Konfiguration, Log-/Berichtsordner, Verweise auf PS-PhinIT).
- Benutzersuche: exakte Suche nach Anmeldename/UPN, sonst Ambiguous Name Resolution (ANR) mit Trefferbegrenzung; Auswahl-Dialog bei mehreren Treffern.
- Kennwortablauf wird über `msDS-UserPasswordExpiryTimeComputed` ermittelt (berücksichtigt FGPP).
- Kontooptionen senden nur tatsächlich geänderte Werte; „Kennwort bei nächster Anmeldung ändern“ wird aus dem AD gelesen.
- Registerkarten laden ihre Daten erst beim ersten Öffnen (Lazy Loading).
- OU-Baum wird mit einer einzigen LDAP-Abfrage aufgebaut statt einer Abfrage pro OU.
- Gruppenmitglieder werden mit einer einzigen LDAP-Abfrage geladen (inkl. primärer Gruppe) statt einer Abfrage pro Mitglied.
- Gruppenliste wird einmal geladen und zwischengespeichert; Listen verwenden Virtualisierung.
- `ADPS_LoadDefaultDrive=0` beschleunigt den Import des ActiveDirectory-Moduls.
- Fenster ist skalierbar (Mindestgröße 1000 × 720) und passt auf kleinere Bildschirme.
- Zentrale Fehlerbehandlung für alle GUI-Aktionen mit Sperre gegen Mehrfachausführung und Wartecursor.
- Berichte: einheitlicher HTML-/TXT-Bericht mit Metadaten, UTF-8, Hinweis auf Vertraulichkeit, korrekte Versionsangabe.

### Behoben
- Gruppen-Reset enthielt kopierte Entsperr-Logik und bot den Bericht nicht an.
- FGPP-Bearbeiten: Priorität wurde nicht übernommen (`[ref]` auf Hashtable-Wert), nicht initialisierte Variable für das Mindestalter, Fehler bei FGPP ohne Zielgruppen, Speichern wirkte auf die aktuell markierte statt die bearbeitete Richtlinie.
- FGPP mit „Vor versehentlichem Löschen schützen“ konnten nicht gelöscht werden.
- Entsperren einer OU nutzte `-Filter {LockedOut -eq $true}` (nicht filterbar) – jetzt `Search-ADAccount -LockedOut`.
- Kennwortablauf wurde ohne geladenes `pwdLastSet` berechnet und war daher falsch.
- „Optionen übernehmen“ entfernte stillschweigend „Kennwort bei nächster Anmeldung ändern“.
- Veraltete Benutzerdaten in Fehlermeldungen von Massenvorgängen.
- `Show-PasswordPolicies` verwendete eine nicht definierte Variable und fragte die Richtlinie doppelt ab.
- Navigations-Schaltflächen, Logo und AD-Status-Label wurden referenziert, existierten aber nicht im XAML; Richtlinien- und FGPP-Registerkarten wurden daher nie automatisch geladen.
- Doppelt definierte Funktion `Write-DebugMessage`; nach dem Schließen des Fensters wurde das XAML erneut geladen (toter Code, defekte Exit-/Lokalisierungsfunktionen).
- Umlaute wurden im Log entfernt.

### Sicherheit
- Kennwörter werden mit `System.Security.Cryptography.RandomNumberGenerator` (ohne Modulo-Verzerrung) statt `Get-Random` erzeugt; keine schwachen Fallback-Kennwörter und kein hartcodiertes Standardkennwort mehr.
- Kennwörter erscheinen nicht mehr in MessageBoxen, Konsole oder Log; Anzeige nur maskiert bzw. auf Wunsch in einem schreibgeschützten Feld.
- Standardmäßig aktives ausführliches Debugging entfernt, das Aufrufstapel und Variableninhalte (inkl. möglicher Kennwörter) ausgab.
- Filter-Injection behoben: Werte in `-Filter`- und LDAP-Filtern werden maskiert (RFC 4515).
- HTML-Injection in Berichten behoben (HTML-Kodierung, Content-Security-Policy).
- ADSI-Fallback mit fiktiven Benutzerobjekten entfernt.
- Beenden entfernt nicht mehr alle PowerShell-Jobs der Sitzung und löscht keine fremden temporären Dateien.
- Website-Link im Footer wird nur für gültige `http`/`https`-URLs geöffnet.
- Eigenes Kennwort kann nicht zurückgesetzt und eigenes Konto nicht deaktiviert werden.
- Warnung bei umkehrbarer Verschlüsselung in FGPP.

### Entfernt
- Alte Version `easyADPW_V0.0.1.ps1`.
- Alle Screenshots (`# Screenshots/`); neue Screenshots werden unter `docs/screenshots/` abgelegt.
- Ungültig gewordener Authenticode-Signaturblock (das Skript wurde nach der Signierung geändert).
- Nicht verwendete Konfiguration (`DefaultPassword`, `HeaderLogoURL`), XAML-Styles und Navigationsspalte, veraltete Aufrufe (`LoadWithPartialName`, `Get-WmiObject`).

### Bekannte Einschränkungen
- Die WPF-Oberfläche wurde im Rahmen des Audits statisch geprüft (Parser, PSScriptAnalyzer, XAML, Funktionstests der Hilfsfunktionen), aber nicht in einer Windows-Domäne ausgeführt.
- Das Skript ist nicht signiert (siehe [SECURITY.md](SECURITY.md)).

## [0.0.2] - 2026-10-12

Versionsnummer nachträglich vergeben; das Skript selbst trug weiterhin die Bezeichnung V0.0.1.

### Sicherheit
- Code-Scanning-Warnungen von PowerShell behoben ([#1](https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/pull/1)):
  - `Write-Host` durch passende Ausgabe-Streams ersetzt.
  - Leere `catch`-Blöcke um Diagnoseausgaben ergänzt.
  - `SupportsShouldProcess` für `Remove-GroupFromFGPP`.
  - Kennwörter in Berichtsfunktionen als `SecureString` übergeben, Klartext nur über `SecureStringToBSTR`/`ZeroFreeBSTR`.

## [0.0.1] - 2025-07-20

### Hinzugefügt
- Erste öffentliche Version `easyADPW_V0.0.1.ps1`: PowerShell-GUI zum Zurücksetzen von Active-Directory-Kennwörtern bzw. Anpassen von Optionen für Benutzer, OUs oder Gruppen, mit Benutzer- und Administratorberichten.
- Registerkarten für Einzelbenutzer, OU/Gruppen, Kennwortrichtlinien und Fine-Grained Password Policies.
- `Readme.md`, `LICENSE` (MIT), Screenshots.
- 2025-07-25: GitHub-Workflows für PSScriptAnalyzer und Codacy.

[0.1.0]: https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/compare/c2bf963...main
[0.0.2]: https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/pull/1
[0.0.1]: https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/commit/b02e5c2
