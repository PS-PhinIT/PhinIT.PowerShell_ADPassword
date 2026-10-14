# Sicherheitsrichtlinie

## Unterstützte Versionen

| Version | Unterstützt |
|---------|-------------|
| 0.1.x   | ✅ |
| < 0.1.0 | ❌ (entfernt, enthielt bekannte Schwachstellen – siehe [docs/AUDIT.md](docs/AUDIT.md)) |

## Schwachstellen melden

Bitte melden Sie Sicherheitslücken **nicht** über öffentliche Issues.

Nutzen Sie stattdessen die private Meldung über GitHub:
[Security Advisory erstellen](https://github.com/PS-PhinIT/PhinIT.PowerShell_ADPassword/security/advisories/new)
oder kontaktieren Sie den Maintainer über [www.phinit.de](https://www.phinit.de).

Bitte geben Sie an:

- betroffene Version und PowerShell-Version,
- Beschreibung und Auswirkung der Schwachstelle,
- Schritte zur Reproduktion (ohne echte Kennwörter oder personenbezogene Daten).

Sie erhalten eine Eingangsbestätigung in der Regel innerhalb von 7 Tagen.

## Sicherheitskonzept

- **Kennwortgenerierung:** `System.Security.Cryptography.RandomNumberGenerator` mit Rejection Sampling (keine Modulo-Verzerrung), mindestens ein Zeichen je aktivierter Zeichengruppe, Mischung per Fisher-Yates.
- **Kennwortverarbeitung:** ausschließlich als `SecureString`; Klartext nur kurzzeitig für Anzeige und Bericht (`SecureStringToBSTR`/`ZeroFreeBSTR`). Kennwörter werden nie protokolliert und nicht in Meldungsfenstern angezeigt.
- **Eingaben:** Werte in AD-`-Filter`-Ausdrücken und LDAP-Filtern werden maskiert (RFC 4515), Berichte werden HTML-kodiert und mit Content-Security-Policy erzeugt.
- **Massenvorgänge:** eigenes Konto, `krbtgt`, integriertes Administratorkonto und (konfigurierbar) Konten mit `adminCount=1` werden übersprungen; jeder Vorgang erfordert eine Bestätigung.
- **Berichte:** enthalten Kennwörter im Klartext. Der Ordner `Reports\` wird per ACL auf den aktuellen Benutzer, `VORDEFINIERT\Administratoren` und `SYSTEM` beschränkt. Berichte nach der Übergabe sicher löschen.
- **Protokoll:** `Logs\easyPASSWORDRESET.log` enthält Aktionen, Zielkonten und Fehler – keine Kennwörter.
- **Berechtigungen:** Das Tool nutzt die Rechte des angemeldeten Benutzers. Verwenden Sie delegierte Rechte nach dem Least-Privilege-Prinzip statt Domänen-Admin-Konten, wo möglich.

## Code-Signatur

Version 0.1.0 wird **unsigniert** ausgeliefert, weil die bisherige Signatur durch spätere Änderungen ungültig geworden war.
In Umgebungen mit `AllSigned` bitte vor dem Einsatz signieren, z. B.:

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Set-AuthenticodeSignature -FilePath .\V0.1.0\easyADPW.ps1 -Certificate $cert -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
```

Hinweise zum Zertifikat: [PS-PhinIT/PhinIT.Certificate](https://github.com/PS-PhinIT/PhinIT.Certificate).
