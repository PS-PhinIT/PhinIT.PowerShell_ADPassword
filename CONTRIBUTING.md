# Mitwirken

Vielen Dank für Ihr Interesse an easyADPW! Beiträge sind willkommen.

## Fehler melden und Wünsche äußern

- Fehler und Funktionswünsche bitte über [Issues](https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/issues) mit den Vorlagen melden.
- Sicherheitslücken **nicht** öffentlich melden – siehe [SECURITY.md](SECURITY.md).
- Niemals echte Kennwörter, Berichte, Logdateien oder personenbezogene Daten anhängen.

## Entwicklung

1. Repository forken und einen Branch anlegen (`feature/...` oder `fix/...`).
2. Änderungen in der aktuellen Versionsdatei `V<Version>/easyADPW.ps1` vornehmen.
3. Vor dem Pull Request lokal prüfen:

   ```powershell
   Install-Module PSScriptAnalyzer -Scope CurrentUser
   Invoke-ScriptAnalyzer -Path .\V0.1.0\easyADPW.ps1 -Severity Error,Warning
   ```

4. In einer Testdomäne (nicht in Produktion!) die betroffenen Funktionen ausprobieren.
5. `CHANGELOG.md` ergänzen (Abschnitte: Hinzugefügt, Geändert, Behoben, Sicherheit, Entfernt).

## Richtlinien

- Kompatibel mit Windows PowerShell 5.1 und PowerShell 7.x.
- Dateien in UTF-8 **mit** BOM speichern (Umlaute in Windows PowerShell 5.1).
- Freigegebene Verben (`Get-Verb`), keine Aliase, kein `Write-Host`, keine leeren `catch`-Blöcke.
- Kennwörter nur als `SecureString` verarbeiten und niemals protokollieren.
- Benutzereingaben in `-Filter`/LDAP-Filtern immer maskieren (`ConvertTo-ADFilterValue`, `ConvertTo-LdapFilterValue`), HTML immer kodieren.
- AD-ändernde Funktionen mit `SupportsShouldProcess` und Bestätigung in der GUI.
- Oberflächentexte auf Deutsch.

## Versionierung und Releases

- [Semantic Versioning](https://semver.org/lang/de/); die aktuelle Version steht in `VERSION` und `$script:AppVersion`.
- Neue Versionen werden in einem eigenen Ordner `V<Version>/` abgelegt, alte Versionsordner entfernt.
- Im CHANGELOG werden nur veröffentlichte Versionen mit Datum geführt.
- Screenshots der aktuellen Version liegen in `docs/screenshots/`.
