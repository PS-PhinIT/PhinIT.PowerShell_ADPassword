#Requires -Version 5.1
<#
.SYNOPSIS
    easyADPW (easyPASSWORDRESET) - WPF-GUI zum Zuruecksetzen von Active-Directory-Kennwoertern.

.DESCRIPTION
    Grafische Oberflaeche fuer den Helpdesk / die AD-Administration:
      - Einzelbenutzer suchen, Kennwort zuruecksetzen, Konto entsperren, Kontooptionen setzen
      - Massenvorgaenge fuer Organisationseinheiten (OU) und Gruppen (Reset / Entsperren)
      - Anzeige der Standard-Domaenenkennwortrichtlinie
      - Verwaltung von Fine-Grained Password Policies (FGPP)
      - HTML-/TXT-Berichte fuer Benutzer und Administratoren

    Kennwoerter werden mit einem kryptografisch sicheren Zufallsgenerator erzeugt,
    ausschliesslich als SecureString verarbeitet und nur fuer Anzeige bzw. Bericht
    kurzzeitig in Klartext umgewandelt. Kennwoerter werden niemals protokolliert.

.PARAMETER DebugLog
    Schreibt zusaetzliche Debug-Eintraege in die Logdatei (enthaelt keine Kennwoerter).

.EXAMPLE
    powershell.exe -STA -ExecutionPolicy RemoteSigned -File .\easyADPW.ps1

.EXAMPLE
    .\easyADPW.ps1 -DebugLog

.NOTES
    Name    : easyADPW.ps1
    Version : 0.1.0
    Autor   : PHiNiT (https://www.phinit.de)
    Lizenz  : MIT
    Benoetigt: Windows, PowerShell 5.1 oder 7.x (STA), RSAT ActiveDirectory-Modul
#>
[CmdletBinding()]
param(
    [switch]$DebugLog
)

$script:AppVersion = '0.1.0'

#region Konfiguration
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

$script:Config = @{
    AppName                          = 'easyPASSWORDRESET'
    ThemeColor                       = '#0078D7'
    FooterText                       = 'easyPASSWORDRESET  |  PHiNiT'
    FooterWebsite                    = 'https://www.phinit.de'

    LogFolder                        = Join-Path $script:ScriptRoot 'Logs'
    LogFileName                      = 'easyPASSWORDRESET.log'
    LogMaxSizeMB                     = 10

    ReportFolder                     = Join-Path $script:ScriptRoot 'Reports'
    # Beschraenkt den Berichtsordner auf aktuellen Benutzer, Administratoren und SYSTEM
    RestrictReportFolderAcl          = $true

    DefaultPasswordLength            = 16
    MinimumPasswordLength            = 12
    UseUppercase                     = $true
    UseLowercase                     = $true
    UseNumbers                       = $true
    UseSpecialChars                  = $true
    SpecialChars                     = '!@#$%^&*()-_=+[]{};:,.<>/?'

    # Benutzer muss das Kennwort nach einem Reset bei der naechsten Anmeldung aendern
    RequirePasswordChangeAfterReset  = $true
    # Konten mit adminCount=1 werden bei OU-/Gruppen-Massenresets uebersprungen
    ExcludeProtectedAccountsFromBulk = $true
    MaxSearchResults                 = 200
    DebugLog                         = [bool]$DebugLog
}
#endregion

#region Voraussetzungen
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-Error 'easyADPW benötigt Windows (WPF und RSAT ActiveDirectory-Modul).'
    exit 1
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    Write-Error 'Die WPF-Oberfläche benötigt einen STA-Thread. Starten Sie das Skript mit: powershell.exe -STA -File .\easyADPW.ps1'
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
#endregion

#region Logging
$script:LogFile = $null

function Initialize-Logging {
    [CmdletBinding()]
    param()

    $folders = @($script:Config.LogFolder, (Join-Path ([System.IO.Path]::GetTempPath()) $script:Config.AppName))
    foreach ($folder in $folders) {
        try {
            if (-not (Test-Path -LiteralPath $folder)) {
                New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $candidate = Join-Path $folder $script:Config.LogFileName
            [System.IO.File]::AppendAllText($candidate, '', [System.Text.Encoding]::UTF8)
            $script:LogFile = $candidate
            return
        }
        catch {
            Write-Verbose "Logordner '$folder' nicht beschreibbar: $($_.Exception.Message)"
        }
    }
    Write-Warning 'Es konnte kein beschreibbarer Logordner gefunden werden. Protokollierung deaktiviert.'
}

function Write-AppLog {
    <#
    .SYNOPSIS
        Schreibt eine Zeile in die Logdatei. Niemals Kennwoerter uebergeben!
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    if ($Level -eq 'DEBUG' -and -not $script:Config.DebugLog) { return }

    $clean = ($Message -replace '[\r\n]+', ' ').Trim()
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $env:USERNAME, $clean
    Write-Verbose $line

    if (-not $script:LogFile) { return }
    try {
        $info = New-Object System.IO.FileInfo($script:LogFile)
        if ($info.Exists -and $info.Length -gt ($script:Config.LogMaxSizeMB * 1MB)) {
            $archive = [System.IO.Path]::ChangeExtension($script:LogFile, ('{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
            Move-Item -LiteralPath $script:LogFile -Destination $archive -Force -ErrorAction Stop
        }
        [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
    catch {
        Write-Verbose "Logeintrag konnte nicht geschrieben werden: $($_.Exception.Message)"
    }
}
#endregion

#region Allgemeine Hilfsfunktionen
function ConvertTo-ADFilterValue {
    <#
    .SYNOPSIS
        Maskiert einen Wert fuer die Verwendung in einem -Filter-Ausdruck (in einfachen Anfuehrungszeichen).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return $Value.Replace("'", "''")
}

function ConvertTo-LdapFilterValue {
    <#
    .SYNOPSIS
        Maskiert einen Wert gemaess RFC 4515 fuer LDAP-Filter.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        switch ([int]$ch) {
            0x5C { [void]$sb.Append('\5c') }
            0x2A { [void]$sb.Append('\2a') }
            0x28 { [void]$sb.Append('\28') }
            0x29 { [void]$sb.Append('\29') }
            0x00 { [void]$sb.Append('\00') }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

function ConvertTo-HtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-SafeFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = foreach ($c in $Name.ToCharArray()) { if ($invalid -contains $c -or $c -eq ' ') { '_' } else { $c } }
    $result = (-join $chars).Trim('_', '.')
    if ($result.Length -gt 60) { $result = $result.Substring(0, 60) }
    if ([string]::IsNullOrWhiteSpace($result)) { $result = 'Bericht' }
    return $result
}

function Get-ParentDistinguishedName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DistinguishedName)

    if ($DistinguishedName -match '^(?:\\.|[^,\\])+,(?<parent>.+)$') {
        return $Matches['parent']
    }
    return $null
}

function Get-PasswordExpiryText {
    <#
    .SYNOPSIS
        Wandelt msDS-UserPasswordExpiryTimeComputed in einen lesbaren Text um (FGPP-bewusst).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$ExpiryFileTime,
        [bool]$PasswordNeverExpires = $false,
        [AllowNull()][object]$LastSetDate
    )

    if ($PasswordNeverExpires) { return 'Läuft nie ab' }
    if ($null -eq $LastSetDate) { return 'Änderung bei nächster Anmeldung erforderlich' }
    if ($null -eq $ExpiryFileTime) { return 'Unbekannt' }

    $value = [int64]$ExpiryFileTime
    if ($value -le 0 -or $value -eq [int64]::MaxValue) { return 'Läuft nie ab' }

    try {
        $date = [DateTime]::FromFileTime($value)
    }
    catch {
        return 'Unbekannt'
    }
    $days = [math]::Floor(($date - (Get-Date)).TotalDays)
    if ($days -lt 0) { return ('{0:dd.MM.yyyy HH:mm} (abgelaufen)' -f $date) }
    return ('{0:dd.MM.yyyy HH:mm} (noch {1} Tage)' -f $date, $days)
}
#endregion

#region Kennwortfunktionen
$script:Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

function Get-SecureRandomIndex {
    <#
    .SYNOPSIS
        Liefert eine gleichverteilte Zufallszahl im Bereich [0, MaxExclusive) aus einem CSPRNG.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$MaxExclusive)

    $bytes = New-Object byte[] 4
    $range = [uint64]4294967296
    $limit = $range - ($range % [uint64]$MaxExclusive)
    do {
        $script:Rng.GetBytes($bytes)
        $value = [uint64][System.BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)
    return [int]($value % [uint64]$MaxExclusive)
}

function New-RandomPassword {
    <#
    .SYNOPSIS
        Erzeugt ein zufaelliges Kennwort als schreibgeschuetzten SecureString.
    .DESCRIPTION
        Mindestens ein Zeichen aus jeder aktivierten Zeichengruppe, Rest aus der Vereinigungsmenge,
        anschliessend Fisher-Yates-Mischung. Zufall stammt aus RandomNumberGenerator.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur einen Wert im Speicher.')]
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param(
        [ValidateRange(8, 128)][int]$Length = $script:Config.DefaultPasswordLength
    )

    if ($Length -lt $script:Config.MinimumPasswordLength) { $Length = $script:Config.MinimumPasswordLength }

    $sets = New-Object System.Collections.Generic.List[string]
    if ($script:Config.UseUppercase) { $sets.Add('ABCDEFGHJKLMNPQRSTUVWXYZ') }
    if ($script:Config.UseLowercase) { $sets.Add('abcdefghijkmnopqrstuvwxyz') }
    if ($script:Config.UseNumbers) { $sets.Add('23456789') }
    if ($script:Config.UseSpecialChars -and $script:Config.SpecialChars) { $sets.Add([string]$script:Config.SpecialChars) }
    if ($sets.Count -eq 0) { throw 'Keine Zeichengruppe für die Kennwortgenerierung aktiviert.' }
    if ($Length -lt $sets.Count) { $Length = $sets.Count }

    $all = -join $sets
    $chars = New-Object char[] $Length
    for ($i = 0; $i -lt $Length; $i++) {
        $source = if ($i -lt $sets.Count) { $sets[$i] } else { $all }
        $chars[$i] = $source[(Get-SecureRandomIndex -MaxExclusive $source.Length)]
    }
    for ($i = $Length - 1; $i -gt 0; $i--) {
        $j = Get-SecureRandomIndex -MaxExclusive ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $secure = New-Object System.Security.SecureString
    foreach ($c in $chars) { $secure.AppendChar($c) }
    [Array]::Clear($chars, 0, $chars.Length)
    $secure.MakeReadOnly()
    return $secure
}

function ConvertFrom-SecureStringToPlainText {
    <#
    .SYNOPSIS
        Wandelt einen SecureString nur fuer Anzeige/Bericht in Klartext um und gibt den Puffer sofort frei.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}
#endregion

#region GUI-Hilfsfunktionen
$script:Window = $null
$script:IsBusy = $false

function Show-MessageBox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = $script:Config.AppName,
        [System.Windows.MessageBoxButton]$Button = [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information,
        [System.Windows.MessageBoxResult]$DefaultResult = [System.Windows.MessageBoxResult]::None
    )

    if ($script:Window -and $script:Window.IsLoaded) {
        return [System.Windows.MessageBox]::Show($script:Window, $Message, $Title, $Button, $Icon, $DefaultResult)
    }
    return [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon, $DefaultResult)
}

function Confirm-Action {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'Bestätigung',
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Question
    )

    $result = Show-MessageBox -Message $Message -Title $Title -Button YesNo -Icon $Icon -DefaultResult No
    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-UIRefresh {
    <#
    .SYNOPSIS
        Laesst den WPF-Dispatcher ausstehende Render-Auftraege abarbeiten (Statusanzeige bei langen Vorgaengen).
    #>
    [CmdletBinding()]
    param()

    if ($script:Window) {
        $script:Window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action] {})
    }
}

function Write-StatusMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Bulk', 'Policy', 'FGPP')][string]$Area,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [switch]$NoLog
    )

    if (-not $NoLog) { Write-AppLog -Message ('[{0}] {1}' -f $Area, $Message) -Level $Level }

    $box = switch ($Area) {
        'User' { $script:txtStatus }
        'Bulk' { $script:txtStatus2 }
        'Policy' { $script:txtStatus3 }
        'FGPP' { $script:txtStatus4 }
    }
    if (-not $box) { return }

    $prefix = switch ($Level) { 'WARN' { 'WARNUNG: ' } 'ERROR' { 'FEHLER: ' } default { '' } }
    $line = '{0}  {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
    $text = if ([string]::IsNullOrEmpty($box.Text)) { $line } else { $box.Text + [Environment]::NewLine + $line }
    if ($text.Length -gt 20000) { $text = $text.Substring($text.Length - 20000) }
    $box.Text = $text
    $box.ScrollToEnd()
    Invoke-UIRefresh
}

function Invoke-UiAction {
    <#
    .SYNOPSIS
        Zentrale Fehlerbehandlung und Sperre gegen Mehrfachausfuehrung fuer GUI-Ereignisse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('User', 'Bulk', 'Policy', 'FGPP')][string]$Area,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if ($script:IsBusy) {
        Write-AppLog -Message "Aktion '$Name' ignoriert - es läuft bereits ein Vorgang." -Level DEBUG
        return
    }

    $script:IsBusy = $true
    if ($script:Window) { $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait }
    try {
        Write-AppLog -Message "Aktion gestartet: $Name" -Level DEBUG
        & $Action
    }
    catch {
        $msg = $_.Exception.Message
        Write-AppLog -Message ("Aktion '{0}' fehlgeschlagen: {1} | {2}" -f $Name, $msg, $_.InvocationInfo.PositionMessage) -Level ERROR
        Write-StatusMessage -Area $Area -Message "$Name fehlgeschlagen: $msg" -Level ERROR -NoLog
        Show-MessageBox -Message "$Name fehlgeschlagen:`n`n$msg" -Icon Error | Out-Null
    }
    finally {
        if ($script:Window) { $script:Window.Cursor = $null }
        $script:IsBusy = $false
    }
}
#endregion

#region Active Directory
$script:ADAvailable = $false
$script:Domain = $null
$script:CurrentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:GroupCache = $null

function Initialize-ActiveDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Verhindert das (langsame) Anlegen des AD:-PSDrives beim Modulimport
    $env:ADPS_LoadDefaultDrive = 0

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-AppLog -Message 'ActiveDirectory-Modul nicht gefunden.' -Level ERROR
        return $false
    }

    Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
    Write-AppLog -Message 'ActiveDirectory-Modul geladen.'

    try {
        $script:Domain = Get-ADDomain -ErrorAction Stop
        $script:ADAvailable = $true
        Write-AppLog -Message ("Verbunden mit Domäne {0} (PDC: {1})." -f $script:Domain.DNSRoot, $script:Domain.PDCEmulator)
    }
    catch {
        $script:ADAvailable = $false
        Write-AppLog -Message "Domäne nicht erreichbar: $($_.Exception.Message)" -Level WARN
    }
    return $true
}

function Assert-ADAvailable {
    [CmdletBinding()]
    param()

    if ($script:ADAvailable) { return }
    try {
        $script:Domain = Get-ADDomain -ErrorAction Stop
        $script:ADAvailable = $true
        Update-ADStatusDisplay
    }
    catch {
        throw "Keine Verbindung zum Active Directory: $($_.Exception.Message)"
    }
}

function Update-ADStatusDisplay {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Aktualisiert nur die GUI-Anzeige.')]
    [CmdletBinding()]
    param()

    if (-not $script:txtADStatus) { return }
    if ($script:ADAvailable -and $script:Domain) {
        $script:txtADStatus.Text = 'Domäne: {0}  |  DC: {1}' -f $script:Domain.DNSRoot, $script:Domain.PDCEmulator
    }
    else {
        $script:txtADStatus.Text = 'Active Directory nicht erreichbar'
    }
}

function Get-ProtectedAccountReason {
    <#
    .SYNOPSIS
        Liefert einen Grund, warum ein Konto von Massenvorgaengen ausgeschlossen wird, sonst $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$User)

    $sid = if ($User.SID) { $User.SID.Value } else { $null }
    if ($sid -and $sid -eq $script:CurrentUserSid) { return 'Eigenes Konto' }
    if ($User.SamAccountName -eq 'krbtgt') { return 'krbtgt-Konto' }
    if ($sid -and $sid -match '-500$') { return 'Integriertes Administratorkonto' }
    if ($script:Config.ExcludeProtectedAccountsFromBulk -and $User.adminCount -eq 1) { return 'Geschütztes Konto (adminCount=1)' }
    return $null
}

function Get-GroupList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch]$Refresh)

    if ($Refresh -or $null -eq $script:GroupCache) {
        Assert-ADAvailable
        $groups = @(Get-ADGroup -Filter * -ErrorAction Stop | Sort-Object -Property Name, DistinguishedName)
        # CN ist nur je Container eindeutig - doppelte Namen werden mit dem Pfad angezeigt
        $duplicates = @($groups | Group-Object -Property Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $script:GroupCache = @(foreach ($g in $groups) {
                $display = $g.Name
                if ($duplicates -contains $g.Name) {
                    $display = '{0}  ({1})' -f $g.Name, (Get-ParentDistinguishedName -DistinguishedName $g.DistinguishedName)
                }
                [pscustomobject]@{ Display = $display; Name = $g.Name; DistinguishedName = $g.DistinguishedName }
            })
        Write-AppLog -Message ("{0} Gruppen geladen." -f $script:GroupCache.Count) -Level DEBUG
    }
    return , $script:GroupCache
}

function Get-GroupMemberUser {
    <#
    .SYNOPSIS
        Liefert alle direkten Benutzer-Mitglieder einer Gruppe mit einer einzigen LDAP-Abfrage
        (inkl. Benutzer, deren primaere Gruppe diese Gruppe ist).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [string[]]$Property = @()
    )

    Assert-ADAvailable
    $group = Get-ADGroup -Identity $Identity -ErrorAction Stop

    # primaryGroupToken entspricht der RID der Gruppen-SID (konstruiertes Attribut, nur per Base-Suche lesbar)
    $rid = $group.SID.Value.Split('-')[-1]
    $ldap = '(&(objectCategory=person)(objectClass=user)(|(memberOf={0})(primaryGroupID={1})))' -f (ConvertTo-LdapFilterValue $group.DistinguishedName), $rid
    $props = @('DisplayName', 'adminCount', 'Enabled') + $Property | Select-Object -Unique
    return @(Get-ADUser -LDAPFilter $ldap -Properties $props -ErrorAction Stop | Sort-Object -Property SamAccountName)
}
#endregion

#region Berichte
$script:ReportFolderReady = $false
$script:ReportFolderPath = $null

function Initialize-ReportFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:ReportFolderReady) { return $script:ReportFolderPath }

    # Fallback auf das Benutzerprofil, falls der Skriptordner nicht beschreibbar ist (z. B. Program Files, Share)
    $candidates = @(
        $script:Config.ReportFolder,
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) (Join-Path $script:Config.AppName 'Reports'))
    )
    $folder = $null
    foreach ($candidate in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $candidate)) {
                New-Item -Path $candidate -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $probe = Join-Path $candidate ('.write-test_{0}' -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($probe, '')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $folder = $candidate
            break
        }
        catch {
            Write-AppLog -Message "Berichtsordner nicht beschreibbar: $candidate ($($_.Exception.Message))" -Level WARN
        }
    }
    if (-not $folder) { throw 'Es konnte kein beschreibbarer Berichtsordner gefunden werden. Vorgang abgebrochen.' }

    if ($script:Config.RestrictReportFolderAcl) {
        try {
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sidValue in @($script:CurrentUserSid, 'S-1-5-32-544', 'S-1-5-18')) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $folder -AclObject $acl -ErrorAction Stop
            Write-AppLog -Message "Berechtigungen des Berichtsordners eingeschränkt: $folder" -Level DEBUG
        }
        catch {
            Write-AppLog -Message "Berechtigungen des Berichtsordners konnten nicht gesetzt werden: $($_.Exception.Message)" -Level WARN
        }
    }

    $script:ReportFolderPath = $folder
    $script:ReportFolderReady = $true
    return $folder
}

function Save-OperationReport {
    <#
    .SYNOPSIS
        Schreibt einen HTML- und einen TXT-Bericht. Spalten mit SecureString-Werten werden erst hier
        in Klartext umgewandelt.
    .OUTPUTS
        Pfad der HTML-Datei.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$FileNamePrefix,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Metadata,
        [Parameter(Mandatory)][string[]]$Column,
        [AllowEmptyCollection()][object[]]$Row = @()
    )

    $folder = Initialize-ReportFolder
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $baseName = '{0}_{1}' -f (Get-SafeFileName $FileNamePrefix), $stamp
    $htmlPath = Join-Path $folder ($baseName + '.html')
    $txtPath = Join-Path $folder ($baseName + '.txt')

    $meta = New-Object System.Collections.Specialized.OrderedDictionary
    $meta['Erstellt'] = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'
    $meta['Ausgeführt von'] = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $meta['Computer'] = $env:COMPUTERNAME
    if ($script:Domain) { $meta['Domäne'] = $script:Domain.DNSRoot }
    foreach ($key in $Metadata.Keys) { $meta[$key] = $Metadata[$key] }
    $meta['Version'] = '{0} {1}' -f $script:Config.AppName, $script:AppVersion

    $html = New-Object System.Text.StringBuilder
    $txt = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="de"><head><meta charset="utf-8">')
    [void]$html.AppendLine('<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">')
    [void]$html.AppendLine(('<title>{0}</title>' -f (ConvertTo-HtmlText $Title)))
    [void]$html.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{color:' + $script:Config.ThemeColor + ';font-size:22px}table{border-collapse:collapse;margin:12px 0;width:100%}th,td{border:1px solid #ccc;padding:6px 8px;text-align:left;font-size:13px}th{background:#f0f0f0}.pw{font-family:Consolas,monospace;font-size:14px}.warn{background:#fff4ce;border:1px solid #e0c060;padding:8px;margin:12px 0}</style>')
    [void]$html.AppendLine('</head><body>')
    [void]$html.AppendLine(('<h1>{0}</h1>' -f (ConvertTo-HtmlText $Title)))
    [void]$html.AppendLine('<div class="warn">Vertraulich: Dieser Bericht kann Kennwörter enthalten. Nach der Übergabe sicher löschen.</div>')
    [void]$html.AppendLine('<table>')

    [void]$txt.AppendLine($Title)
    [void]$txt.AppendLine(('=' * $Title.Length))
    [void]$txt.AppendLine('VERTRAULICH - kann Kennwörter enthalten. Nach der Übergabe sicher löschen.')
    [void]$txt.AppendLine()

    foreach ($key in $meta.Keys) {
        [void]$html.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (ConvertTo-HtmlText $key), (ConvertTo-HtmlText $meta[$key])))
        [void]$txt.AppendLine(('{0}: {1}' -f $key, $meta[$key]))
    }
    [void]$html.AppendLine('</table>')
    [void]$txt.AppendLine()

    if ($Row.Count -gt 0) {
        [void]$html.AppendLine('<table><tr>')
        foreach ($col in $Column) { [void]$html.Append(('<th>{0}</th>' -f (ConvertTo-HtmlText $col))) }
        [void]$html.AppendLine('</tr>')
        foreach ($item in $Row) {
            [void]$html.Append('<tr>')
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($col in $Column) {
                $value = $item.$col
                $cssClass = ''
                if ($value -is [System.Security.SecureString]) {
                    $value = ConvertFrom-SecureStringToPlainText -SecureString $value
                    $cssClass = ' class="pw"'
                }
                [void]$html.Append(('<td{0}>{1}</td>' -f $cssClass, (ConvertTo-HtmlText $value)))
                $parts.Add(('{0}: {1}' -f $col, $value))
            }
            [void]$html.AppendLine('</tr>')
            [void]$txt.AppendLine(($parts -join ' | '))
        }
        [void]$html.AppendLine('</table>')
    }
    [void]$html.AppendLine('</body></html>')

    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($htmlPath, $html.ToString(), $encoding)
    [System.IO.File]::WriteAllText($txtPath, $txt.ToString(), $encoding)
    [void]$html.Clear()
    [void]$txt.Clear()

    Write-AppLog -Message "Bericht erstellt: $htmlPath"
    return $htmlPath
}

function Show-ReportPrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Confirm-Action -Message "Der Bericht wurde gespeichert:`n$Path`n`nJetzt öffnen?" -Title 'Bericht') {
        Invoke-Item -LiteralPath $Path
    }
}
#endregion

#region Einzelbenutzer
$script:CurrentUser = $null
$script:UserProperties = @(
    'DisplayName', 'EmailAddress', 'Description', 'Department', 'Enabled', 'LockedOut', 'LastLogonDate',
    'PasswordLastSet', 'PasswordNeverExpires', 'CannotChangePassword', 'msDS-UserPasswordExpiryTimeComputed',
    'adminCount', 'UserPrincipalName'
)

function Find-ADUserAccount {
    <#
    .SYNOPSIS
        Sucht Benutzer: zuerst exakt (sAMAccountName/UPN), danach per Ambiguous Name Resolution (ANR).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$SearchText)

    Assert-ADAvailable
    $term = $SearchText.Trim()
    $filterValue = ConvertTo-ADFilterValue $term

    $exact = @(Get-ADUser -Filter ("SamAccountName -eq '{0}' -or UserPrincipalName -eq '{0}'" -f $filterValue) -Properties $script:UserProperties -ErrorAction Stop)
    if ($exact.Count -gt 0) { return $exact }

    $ldap = '(&(objectCategory=person)(objectClass=user)(anr={0}))' -f (ConvertTo-LdapFilterValue $term)
    return @(Get-ADUser -LDAPFilter $ldap -Properties $script:UserProperties -ResultSetSize $script:Config.MaxSearchResults -ErrorAction Stop |
            Sort-Object -Property SamAccountName)
}

function Get-ADUserDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)

    return Get-ADUser -Identity $Identity -Properties $script:UserProperties -ErrorAction Stop
}

function Select-ADUserFromList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$User)

    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Benutzer auswählen" Width="760" Height="460" MinWidth="500" MinHeight="300"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
    <DockPanel Margin="10">
        <TextBlock DockPanel.Dock="Top" Margin="0,0,0,8" Text="Mehrere Benutzer gefunden. Bitte wählen Sie einen Eintrag aus:"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="btnOk" Content="Auswählen" Width="100" Margin="0,0,8,0" IsDefault="True"/>
            <Button Content="Abbrechen" Width="100" IsCancel="True"/>
        </StackPanel>
        <ListView x:Name="lstUsers" SelectionMode="Single">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="Anmeldename" Width="150" DisplayMemberBinding="{Binding SamAccountName}"/>
                    <GridViewColumn Header="Anzeigename" Width="220" DisplayMemberBinding="{Binding DisplayName}"/>
                    <GridViewColumn Header="UPN" Width="240" DisplayMemberBinding="{Binding UserPrincipalName}"/>
                    <GridViewColumn Header="Status" Width="90" DisplayMemberBinding="{Binding Status}"/>
                </GridView>
            </ListView.View>
        </ListView>
    </DockPanel>
</Window>
'@

    $dialog = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dialogXaml))
    if ($script:Window) { $dialog.Owner = $script:Window }
    $list = $dialog.FindName('lstUsers')
    $list.ItemsSource = @(foreach ($u in $User) {
            [pscustomobject]@{
                SamAccountName    = $u.SamAccountName
                DisplayName       = $u.DisplayName
                UserPrincipalName = $u.UserPrincipalName
                Status            = if ($u.Enabled) { 'Aktiv' } else { 'Deaktiviert' }
                Identity          = $u.DistinguishedName
            }
        })
    $list.SelectedIndex = 0

    $dialog.FindName('btnOk').Add_Click({
            if ($null -ne [System.Windows.Window]::GetWindow($this).FindName('lstUsers').SelectedItem) {
                [System.Windows.Window]::GetWindow($this).DialogResult = $true
            }
        })
    $list.Add_MouseDoubleClick({
            if ($null -ne $this.SelectedItem) { [System.Windows.Window]::GetWindow($this).DialogResult = $true }
        })

    if ($dialog.ShowDialog() -and $list.SelectedItem) {
        $selected = $list.SelectedItem.Identity
        return ($User | Where-Object { $_.DistinguishedName -eq $selected } | Select-Object -First 1)
    }
    return $null
}

function Clear-GeneratedPassword {
    [CmdletBinding()]
    param()

    if ($script:txtGeneratedPassword) { $script:txtGeneratedPassword.Clear() }
    if ($script:txtGeneratedPasswordVisible) { $script:txtGeneratedPasswordVisible.Clear() }
}

function Clear-UserDetail {
    [CmdletBinding()]
    param()

    $script:CurrentUser = $null
    foreach ($box in @($script:txtUserDisplayName, $script:txtUserEmail, $script:txtSamAccountName, $script:txtUserDescription,
            $script:txtUserDepartment, $script:txtUserStatus, $script:txtUserLastLogon, $script:txtUserPwdExpiry)) {
        if ($box) { $box.Text = '' }
    }
    foreach ($chk in @($script:chkPasswordNeverExpires, $script:chkCannotChangePassword, $script:chkAccountEnabled, $script:chkMustChangePassword)) {
        if ($chk) { $chk.IsChecked = $false }
    }
    Clear-GeneratedPassword
    foreach ($btn in @($script:btnReset, $script:btnUnlock, $script:btnApplyOptions)) { if ($btn) { $btn.IsEnabled = $false } }
}

function Show-UserDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$User,
        [switch]$KeepPassword
    )

    $script:CurrentUser = $User
    $script:txtUserDisplayName.Text = [string]$User.DisplayName
    $script:txtUserEmail.Text = [string]$User.EmailAddress
    $script:txtSamAccountName.Text = [string]$User.SamAccountName
    $script:txtUserDescription.Text = [string]$User.Description
    $script:txtUserDepartment.Text = [string]$User.Department

    $state = New-Object System.Collections.Generic.List[string]
    $state.Add($(if ($User.Enabled) { 'Aktiv' } else { 'Deaktiviert' }))
    if ($User.LockedOut) { $state.Add('Gesperrt') }
    if ($User.adminCount -eq 1) { $state.Add('Geschütztes Konto') }
    $script:txtUserStatus.Text = $state -join ', '

    $script:txtUserLastLogon.Text = if ($User.LastLogonDate) { '{0:dd.MM.yyyy HH:mm} (ca.)' -f $User.LastLogonDate } else { 'Nie / unbekannt' }
    $script:txtUserPwdExpiry.Text = Get-PasswordExpiryText -ExpiryFileTime $User.'msDS-UserPasswordExpiryTimeComputed' -PasswordNeverExpires ([bool]$User.PasswordNeverExpires) -LastSetDate $User.PasswordLastSet

    $script:chkPasswordNeverExpires.IsChecked = [bool]$User.PasswordNeverExpires
    $script:chkCannotChangePassword.IsChecked = [bool]$User.CannotChangePassword
    $script:chkAccountEnabled.IsChecked = [bool]$User.Enabled
    $script:chkMustChangePassword.IsChecked = ($null -eq $User.PasswordLastSet)

    if (-not $KeepPassword) { Clear-GeneratedPassword }
    $script:btnReset.IsEnabled = $true
    $script:btnApplyOptions.IsEnabled = $true
    $script:btnUnlock.IsEnabled = [bool]$User.LockedOut
}

function Invoke-UserSearch {
    [CmdletBinding()]
    param()

    $text = $script:txtUsername.Text
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-StatusMessage -Area User -Message 'Bitte einen Benutzernamen, UPN oder Namen eingeben.' -Level WARN -NoLog
        return
    }

    Clear-UserDetail
    Write-StatusMessage -Area User -Message "Suche nach '$($text.Trim())' ..." -NoLog
    $users = @(Find-ADUserAccount -SearchText $text)

    if ($users.Count -eq 0) {
        Write-StatusMessage -Area User -Message 'Kein Benutzer gefunden.' -Level WARN
        return
    }
    if ($users.Count -ge $script:Config.MaxSearchResults) {
        Write-StatusMessage -Area User -Message ("Mehr als {0} Treffer - bitte Suche eingrenzen." -f $script:Config.MaxSearchResults) -Level WARN -NoLog
    }

    $user = if ($users.Count -eq 1) { $users[0] } else { Select-ADUserFromList -User $users }
    if (-not $user) {
        Write-StatusMessage -Area User -Message 'Keine Auswahl getroffen.' -NoLog
        return
    }

    Show-UserDetail -User $user
    Write-StatusMessage -Area User -Message ("Benutzer geladen: {0}" -f $user.SamAccountName)
}

function Reset-ADUserPassword {
    <#
    .SYNOPSIS
        Setzt das Kennwort eines Benutzers zurueck und optional "Kennwort bei naechster Anmeldung aendern".
    .OUTPUTS
        Hinweistext (leer, wenn keine Besonderheiten).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$User,
        [Parameter(Mandatory)][System.Security.SecureString]$NewPassword,
        [bool]$MustChange = $script:Config.RequirePasswordChangeAfterReset,
        [switch]$Unlock
    )

    $notes = New-Object System.Collections.Generic.List[string]
    if (-not $PSCmdlet.ShouldProcess($User.SamAccountName, 'Kennwort zurücksetzen')) { return 'Übersprungen' }

    Set-ADAccountPassword -Identity $User.DistinguishedName -Reset -NewPassword $NewPassword -ErrorAction Stop

    if ($MustChange) {
        if ($User.PasswordNeverExpires) {
            $notes.Add('"Kennwort läuft nie ab" ist gesetzt - Änderung bei Anmeldung nicht erzwungen')
        }
        else {
            try {
                Set-ADUser -Identity $User.DistinguishedName -ChangePasswordAtLogon $true -ErrorAction Stop
                $notes.Add('Änderung bei nächster Anmeldung erforderlich')
            }
            catch {
                $notes.Add("Änderung bei Anmeldung nicht gesetzt: $($_.Exception.Message)")
            }
        }
    }

    if ($Unlock -and $User.LockedOut) {
        try {
            Unlock-ADAccount -Identity $User.DistinguishedName -ErrorAction Stop
            $notes.Add('Konto entsperrt')
        }
        catch {
            $notes.Add("Entsperren fehlgeschlagen: $($_.Exception.Message)")
        }
    }

    Write-AppLog -Message ("Kennwort zurückgesetzt: {0}. {1}" -f $User.SamAccountName, ($notes -join '; '))
    return ($notes -join '; ')
}

function Invoke-UserPasswordReset {
    [CmdletBinding()]
    param()

    $user = $script:CurrentUser
    if (-not $user) {
        Write-StatusMessage -Area User -Message 'Bitte zuerst einen Benutzer suchen.' -Level WARN -NoLog
        return
    }
    if ($user.SID.Value -eq $script:CurrentUserSid) {
        Show-MessageBox -Message 'Das eigene Kennwort kann hier nicht zurückgesetzt werden. Bitte über STRG+ALT+ENTF ändern.' -Icon Warning | Out-Null
        return
    }

    $message = "Kennwort für '{0}' ({1}) zurücksetzen?" -f $user.DisplayName, $user.SamAccountName
    if ($user.adminCount -eq 1) { $message += "`n`nAchtung: Es handelt sich um ein geschütztes/privilegiertes Konto." }
    if (-not (Confirm-Action -Message $message -Icon Warning)) { return }

    $password = New-RandomPassword
    $note = Reset-ADUserPassword -User $user -NewPassword $password -Unlock -Confirm:$false

    $plain = ConvertFrom-SecureStringToPlainText -SecureString $password
    $script:txtGeneratedPassword.Password = $plain
    if ($script:chkShowPassword.IsChecked) { $script:txtGeneratedPasswordVisible.Text = $plain }
    $plain = $null

    Write-StatusMessage -Area User -Message ("Kennwort für {0} zurückgesetzt. {1}" -f $user.SamAccountName, $note) -NoLog

    $meta = New-Object System.Collections.Specialized.OrderedDictionary
    $meta['Vorgang'] = 'Kennwort-Reset (Einzelbenutzer)'
    $meta['Benutzer'] = $user.SamAccountName
    $reportPath = Save-OperationReport -Title 'Kennwort-Reset' -FileNamePrefix ('PasswordReset_' + $user.SamAccountName) -Metadata $meta `
        -Column @('Benutzer', 'Anzeigename', 'UPN', 'Kennwort', 'Hinweis') `
        -Row @([pscustomobject]@{ Benutzer = $user.SamAccountName; Anzeigename = $user.DisplayName; UPN = $user.UserPrincipalName; Kennwort = $password; Hinweis = $note })

    $password.Dispose()
    Show-UserDetail -User (Get-ADUserDetail -Identity $user.DistinguishedName) -KeepPassword
    Show-ReportPrompt -Path $reportPath
}

function Invoke-UserUnlock {
    [CmdletBinding()]
    param()

    $user = $script:CurrentUser
    if (-not $user) {
        Write-StatusMessage -Area User -Message 'Bitte zuerst einen Benutzer suchen.' -Level WARN -NoLog
        return
    }

    $fresh = Get-ADUserDetail -Identity $user.DistinguishedName
    if (-not $fresh.LockedOut) {
        Show-UserDetail -User $fresh -KeepPassword
        Write-StatusMessage -Area User -Message ("{0} ist nicht gesperrt." -f $fresh.SamAccountName) -NoLog
        return
    }

    Unlock-ADAccount -Identity $fresh.DistinguishedName -ErrorAction Stop
    Write-StatusMessage -Area User -Message ("Konto entsperrt: {0}" -f $fresh.SamAccountName)
    Show-UserDetail -User (Get-ADUserDetail -Identity $fresh.DistinguishedName) -KeepPassword
}

function Set-UserAccountOption {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][hashtable]$Change
    )

    if (-not $PSCmdlet.ShouldProcess($Identity, 'Kontooptionen setzen')) { return }

    $remaining = @{} + $Change
    # "Kennwort bei Anmeldung aendern" zuerst entfernen bzw. zuletzt setzen, damit AD keine Konflikte meldet
    if ($remaining.ContainsKey('ChangePasswordAtLogon') -and -not $remaining['ChangePasswordAtLogon']) {
        Set-ADUser -Identity $Identity -ChangePasswordAtLogon $false -ErrorAction Stop
        $remaining.Remove('ChangePasswordAtLogon')
    }
    $mustChange = $null
    if ($remaining.ContainsKey('ChangePasswordAtLogon')) {
        $mustChange = $remaining['ChangePasswordAtLogon']
        $remaining.Remove('ChangePasswordAtLogon')
    }
    if ($remaining.Count -gt 0) { Set-ADUser -Identity $Identity @remaining -ErrorAction Stop }
    if ($mustChange) { Set-ADUser -Identity $Identity -ChangePasswordAtLogon $true -ErrorAction Stop }
}

function Invoke-UserOptionApply {
    [CmdletBinding()]
    param()

    $user = $script:CurrentUser
    if (-not $user) {
        Write-StatusMessage -Area User -Message 'Bitte zuerst einen Benutzer suchen.' -Level WARN -NoLog
        return
    }

    $neverExpires = [bool]$script:chkPasswordNeverExpires.IsChecked
    $cannotChange = [bool]$script:chkCannotChangePassword.IsChecked
    $enabled = [bool]$script:chkAccountEnabled.IsChecked
    $mustChange = [bool]$script:chkMustChangePassword.IsChecked

    if ($neverExpires -and $mustChange) {
        Show-MessageBox -Message '"Kennwort läuft nie ab" und "Kennwort bei nächster Anmeldung ändern" können nicht gleichzeitig gesetzt werden.' -Icon Warning | Out-Null
        return
    }

    $change = @{}
    $text = New-Object System.Collections.Generic.List[string]
    if ($neverExpires -ne [bool]$user.PasswordNeverExpires) { $change['PasswordNeverExpires'] = $neverExpires; $text.Add("Kennwort läuft nie ab = $neverExpires") }
    if ($cannotChange -ne [bool]$user.CannotChangePassword) { $change['CannotChangePassword'] = $cannotChange; $text.Add("Benutzer kann Kennwort nicht ändern = $cannotChange") }
    if ($mustChange -ne ($null -eq $user.PasswordLastSet)) { $change['ChangePasswordAtLogon'] = $mustChange; $text.Add("Kennwort bei nächster Anmeldung ändern = $mustChange") }
    if ($enabled -ne [bool]$user.Enabled) {
        if (-not $enabled -and $user.SID.Value -eq $script:CurrentUserSid) {
            Show-MessageBox -Message 'Das eigene Konto kann nicht deaktiviert werden.' -Icon Warning | Out-Null
            return
        }
        $change['Enabled'] = $enabled
        $text.Add("Konto aktiviert = $enabled")
    }

    if ($change.Count -eq 0) {
        Write-StatusMessage -Area User -Message 'Keine Änderungen vorhanden.' -NoLog
        return
    }

    $icon = if ($change.ContainsKey('Enabled') -and -not $enabled) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question }
    if (-not (Confirm-Action -Message ("Folgende Änderungen für '{0}' übernehmen?`n`n- {1}" -f $user.SamAccountName, ($text -join "`n- ")) -Icon $icon)) { return }

    Set-UserAccountOption -Identity $user.DistinguishedName -Change $change -Confirm:$false
    Write-StatusMessage -Area User -Message ("Optionen für {0} gesetzt: {1}" -f $user.SamAccountName, ($text -join '; '))
    Show-UserDetail -User (Get-ADUserDetail -Identity $user.DistinguishedName) -KeepPassword
}
#endregion

#region OU- und Gruppenvorgaenge
$script:BulkTabLoaded = $false

function Import-OUTree {
    <#
    .SYNOPSIS
        Laedt alle OUs mit einer einzigen Abfrage und baut den Baum ueber die Parent-DNs auf.
    #>
    [CmdletBinding()]
    param()

    Assert-ADAvailable
    $script:treeViewOUs.Items.Clear()

    $root = New-Object System.Windows.Controls.TreeViewItem
    $root.Header = $script:Domain.DNSRoot
    $root.Tag = $null
    $root.IsExpanded = $true
    [void]$script:treeViewOUs.Items.Add($root)

    $ous = @(Get-ADOrganizationalUnit -Filter * -Properties Name -ErrorAction Stop | Sort-Object -Property Name)
    $nodes = New-Object 'System.Collections.Generic.Dictionary[string,System.Windows.Controls.TreeViewItem]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ou in $ous) {
        $node = New-Object System.Windows.Controls.TreeViewItem
        $node.Header = $ou.Name
        $node.Tag = $ou.DistinguishedName
        $node.ToolTip = $ou.DistinguishedName
        $nodes[$ou.DistinguishedName] = $node
    }
    foreach ($ou in $ous) {
        $parentDn = Get-ParentDistinguishedName -DistinguishedName $ou.DistinguishedName
        $parent = $root
        if ($parentDn -and $nodes.ContainsKey($parentDn)) { $parent = $nodes[$parentDn] }
        [void]$parent.Items.Add($nodes[$ou.DistinguishedName])
    }
    Write-StatusMessage -Area Bulk -Message ("{0} Organisationseinheiten geladen." -f $ous.Count)
}

function Initialize-BulkTab {
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:BulkTabLoaded -and -not $Force) { return }
    Import-OUTree
    $script:cmbGroups.ItemsSource = Get-GroupList -Refresh:$Force
    $script:BulkTabLoaded = $true
}

function Get-SelectedOU {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $item = $script:treeViewOUs.SelectedItem
    if (-not $item -or -not $item.Tag) {
        Write-StatusMessage -Area Bulk -Message 'Bitte eine Organisationseinheit auswählen.' -Level WARN -NoLog
        return $null
    }
    return [string]$item.Tag
}

function Get-BulkTarget {
    <#
    .SYNOPSIS
        Ermittelt Zielbezeichnung und Benutzer fuer OU- oder Gruppenvorgaenge.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('OU', 'Group')][string]$Source,
        [string[]]$Property = @()
    )

    if ($Source -eq 'OU') {
        $dn = Get-SelectedOU
        if (-not $dn) { return $null }
        $scope = if ($script:chkIncludeSubOUs.IsChecked) { 'Subtree' } else { 'OneLevel' }
        $props = @('DisplayName', 'adminCount', 'Enabled') + $Property | Select-Object -Unique
        $users = @(Get-ADUser -Filter * -SearchBase $dn -SearchScope $scope -Properties $props -ErrorAction Stop | Sort-Object -Property SamAccountName)
        $label = if ($scope -eq 'Subtree') { "OU $dn (inkl. Unter-OUs)" } else { "OU $dn" }
        return [pscustomobject]@{ Label = $label; Name = $script:treeViewOUs.SelectedItem.Header; Users = $users }
    }

    $group = $script:cmbGroups.SelectedItem
    if (-not $group) {
        Write-StatusMessage -Area Bulk -Message 'Bitte eine Gruppe auswählen.' -Level WARN -NoLog
        return $null
    }
    return [pscustomobject]@{ Label = ('Gruppe {0}' -f $group.DistinguishedName); Name = $group.Name; Users = @(Get-GroupMemberUser -Identity $group.DistinguishedName -Property $Property) }
}

function Update-GroupMemberList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Aktualisiert nur die GUI-Anzeige.')]
    [CmdletBinding()]
    param()

    $script:lstGroupMembers.ItemsSource = $null
    $group = $script:cmbGroups.SelectedItem
    if (-not $group) { return }

    $members = Get-GroupMemberUser -Identity $group.DistinguishedName
    $script:lstGroupMembers.ItemsSource = @(foreach ($m in $members) {
            if ($m.DisplayName) { '{0}  ({1})' -f $m.SamAccountName, $m.DisplayName } else { $m.SamAccountName }
        })
    Write-StatusMessage -Area Bulk -Message ("Gruppe '{0}': {1} Benutzer." -f $group.Display, $members.Count) -NoLog
}

function Invoke-BulkPasswordReset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('OU', 'Group')][string]$Source)

    $target = Get-BulkTarget -Source $Source -Property @('PasswordNeverExpires', 'LockedOut')
    if (-not $target) { return }
    if ($target.Users.Count -eq 0) {
        Write-StatusMessage -Area Bulk -Message ("Keine Benutzer in {0} gefunden." -f $target.Label) -Level WARN
        return
    }

    $eligible = New-Object System.Collections.Generic.List[object]
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($u in $target.Users) {
        $reason = Get-ProtectedAccountReason -User $u
        if ($reason) {
            $rows.Add([pscustomobject]@{ Benutzer = $u.SamAccountName; Anzeigename = $u.DisplayName; Kennwort = ''; Status = 'Übersprungen'; Hinweis = $reason })
        }
        else {
            $eligible.Add($u)
        }
    }

    if ($eligible.Count -eq 0) {
        Write-StatusMessage -Area Bulk -Message ("Alle {0} Konten in {1} sind geschützt und werden übersprungen." -f $rows.Count, $target.Label) -Level WARN
        return
    }

    # Berichtsordner vor dem Reset pruefen - die neuen Kennwoerter existieren nur im Bericht
    $null = Initialize-ReportFolder

    $msg = "Für {0} Benutzer in {1} werden neue Kennwörter gesetzt.`n{2} geschützte Konten werden übersprungen.`n`nDieser Vorgang kann nicht rückgängig gemacht werden. Fortfahren?" -f $eligible.Count, $target.Label, $rows.Count
    if (-not (Confirm-Action -Message $msg -Title 'Massen-Kennwortreset' -Icon Warning)) { return }

    Write-AppLog -Message ("Massen-Kennwortreset gestartet: {0}, {1} Benutzer." -f $target.Label, $eligible.Count)
    $ok = 0; $failed = 0; $i = 0
    $secrets = New-Object System.Collections.Generic.List[System.Security.SecureString]
    try {
        foreach ($u in $eligible) {
            $i++
            try {
                $password = New-RandomPassword
                $secrets.Add($password)
                $note = Reset-ADUserPassword -User $u -NewPassword $password -Confirm:$false
                if (-not $u.Enabled) { $note = (@('Konto deaktiviert', $note) | Where-Object { $_ }) -join '; ' }
                $rows.Add([pscustomobject]@{ Benutzer = $u.SamAccountName; Anzeigename = $u.DisplayName; Kennwort = $password; Status = 'OK'; Hinweis = $note })
                $ok++
            }
            catch {
                $failed++
                Write-AppLog -Message ("Kennwort-Reset fehlgeschlagen für {0}: {1}" -f $u.SamAccountName, $_.Exception.Message) -Level ERROR
                $rows.Add([pscustomobject]@{ Benutzer = $u.SamAccountName; Anzeigename = $u.DisplayName; Kennwort = ''; Status = 'Fehler'; Hinweis = $_.Exception.Message })
            }
            if ($i % 10 -eq 0) { Write-StatusMessage -Area Bulk -Message ("{0}/{1} verarbeitet ..." -f $i, $eligible.Count) -NoLog }
        }

        $meta = New-Object System.Collections.Specialized.OrderedDictionary
        $meta['Vorgang'] = 'Massen-Kennwortreset'
        $meta['Ziel'] = $target.Label
        $meta['Erfolgreich'] = $ok
        $meta['Fehler'] = $failed
        $meta['Übersprungen'] = $rows.Count - $ok - $failed
        $reportPath = Save-OperationReport -Title ('Massen-Kennwortreset - {0}' -f $target.Name) -FileNamePrefix ('BulkReset_' + $target.Name) -Metadata $meta `
            -Column @('Benutzer', 'Anzeigename', 'Kennwort', 'Status', 'Hinweis') -Row $rows.ToArray()
    }
    finally {
        foreach ($s in $secrets) { $s.Dispose() }
    }

    $level = if ($failed -gt 0) { 'WARN' } else { 'INFO' }
    Write-StatusMessage -Area Bulk -Message ("Massen-Kennwortreset {0}: {1} erfolgreich, {2} Fehler, {3} übersprungen." -f $target.Label, $ok, $failed, ($rows.Count - $ok - $failed)) -Level $level
    Show-ReportPrompt -Path $reportPath
}

function Invoke-BulkUnlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('OU', 'Group')][string]$Source)

    Assert-ADAvailable
    if ($Source -eq 'OU') {
        $dn = Get-SelectedOU
        if (-not $dn) { return }
        $scope = if ($script:chkIncludeSubOUs.IsChecked) { 'Subtree' } else { 'OneLevel' }
        $label = "OU $dn"
        $locked = @(Search-ADAccount -LockedOut -UsersOnly -SearchBase $dn -SearchScope $scope -ErrorAction Stop)
    }
    else {
        $target = Get-BulkTarget -Source Group -Property @('LockedOut')
        if (-not $target) { return }
        $label = $target.Label
        $locked = @($target.Users | Where-Object { $_.LockedOut })
    }

    if ($locked.Count -eq 0) {
        Write-StatusMessage -Area Bulk -Message ("Keine gesperrten Konten in {0}." -f $label)
        return
    }
    if (-not (Confirm-Action -Message ("{0} gesperrte Konten in {1} entsperren?" -f $locked.Count, $label))) { return }

    $ok = 0; $failed = 0
    foreach ($u in $locked) {
        try {
            Unlock-ADAccount -Identity $u.DistinguishedName -ErrorAction Stop
            Write-AppLog -Message ("Konto entsperrt: {0}" -f $u.SamAccountName)
            $ok++
        }
        catch {
            $failed++
            Write-AppLog -Message ("Entsperren fehlgeschlagen für {0}: {1}" -f $u.SamAccountName, $_.Exception.Message) -Level ERROR
        }
    }
    $level = if ($failed -gt 0) { 'WARN' } else { 'INFO' }
    Write-StatusMessage -Area Bulk -Message ("Entsperren {0}: {1} erfolgreich, {2} Fehler." -f $label, $ok, $failed) -Level $level
}
#endregion

#region Kennwortrichtlinien
$script:PolicyTabLoaded = $false

function Format-TimeSpanText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'Nicht gesetzt' }
    $ts = [TimeSpan]$Value
    if ($ts.Ticks -eq 0 -or [math]::Abs($ts.TotalDays) -gt 36500) { return 'Unbegrenzt / 0' }
    if ($ts.TotalDays -ge 1) { return ('{0:N0} Tage' -f $ts.TotalDays) }
    return ('{0:N0} Minuten' -f $ts.TotalMinutes)
}

function Get-PasswordPolicyRow {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object]$Policy, [int]$FGPPCount = 0)

    $maxAge = [TimeSpan]$Policy.MaxPasswordAge
    $minAge = [TimeSpan]$Policy.MinPasswordAge
    $lockDuration = [TimeSpan]$Policy.LockoutDuration
    $observation = [TimeSpan]$Policy.LockoutObservationWindow

    $evaluate = { param([bool]$Condition, [string]$Bad = 'Prüfen') if ($Condition) { 'OK' } else { $Bad } }

    return @(
        [pscustomobject]@{ Einstellung = 'Minimale Kennwortlänge'; Wert = $Policy.MinPasswordLength; Empfehlung = 'Mind. 14 Zeichen (Microsoft-Baseline), 15 ohne MFA (NIST SP 800-63B)'; Bewertung = (& $evaluate ($Policy.MinPasswordLength -ge 14) 'Erhöhen') }
        [pscustomobject]@{ Einstellung = 'Komplexität erforderlich'; Wert = $(if ($Policy.ComplexityEnabled) { 'Ja' } else { 'Nein' }); Empfehlung = 'Aktiviert (zusätzlich Sperrliste für bekannte Kennwörter)'; Bewertung = (& $evaluate ([bool]$Policy.ComplexityEnabled)) }
        [pscustomobject]@{ Einstellung = 'Kennwortchronik'; Wert = $Policy.PasswordHistoryCount; Empfehlung = '24 Kennwörter'; Bewertung = (& $evaluate ($Policy.PasswordHistoryCount -ge 24) 'Erhöhen') }
        [pscustomobject]@{ Einstellung = 'Maximales Kennwortalter'; Wert = (Format-TimeSpanText $maxAge); Empfehlung = 'Kein periodischer Wechsel (NIST), Wechsel nur bei Verdacht auf Kompromittierung'; Bewertung = 'Info' }
        [pscustomobject]@{ Einstellung = 'Minimales Kennwortalter'; Wert = (Format-TimeSpanText $minAge); Empfehlung = '1 Tag'; Bewertung = (& $evaluate ($minAge.TotalDays -ge 1)) }
        [pscustomobject]@{ Einstellung = 'Umkehrbare Verschlüsselung'; Wert = $(if ($Policy.ReversibleEncryptionEnabled) { 'Ja' } else { 'Nein' }); Empfehlung = 'Deaktiviert'; Bewertung = (& $evaluate (-not $Policy.ReversibleEncryptionEnabled) 'Kritisch') }
        [pscustomobject]@{ Einstellung = 'Kontosperrungsschwelle'; Wert = $Policy.LockoutThreshold; Empfehlung = '5 bis 10 Fehlversuche (0 = keine Sperre)'; Bewertung = (& $evaluate ($Policy.LockoutThreshold -ge 1 -and $Policy.LockoutThreshold -le 10)) }
        [pscustomobject]@{ Einstellung = 'Kontosperrdauer'; Wert = (Format-TimeSpanText $lockDuration); Empfehlung = 'Mind. 15 Minuten'; Bewertung = (& $evaluate ($lockDuration.TotalMinutes -ge 15 -or $lockDuration.Ticks -eq 0)) }
        [pscustomobject]@{ Einstellung = 'Sperrzähler zurücksetzen nach'; Wert = (Format-TimeSpanText $observation); Empfehlung = 'Mind. 15 Minuten'; Bewertung = (& $evaluate ($observation.TotalMinutes -ge 15)) }
        [pscustomobject]@{ Einstellung = 'Fine-Grained Password Policies'; Wert = $FGPPCount; Empfehlung = 'Strengere FGPP für privilegierte Konten'; Bewertung = 'Info' }
    )
}

function Show-DomainPasswordPolicy {
    [CmdletBinding()]
    param()

    Assert-ADAvailable
    $policy = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
    $fgppCount = @(Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction Stop).Count
    $script:dgPasswordPolicies.ItemsSource = @(Get-PasswordPolicyRow -Policy $policy -FGPPCount $fgppCount)
    $script:PolicyTabLoaded = $true
    Write-StatusMessage -Area Policy -Message 'Standard-Domänenkennwortrichtlinie geladen.'
}
#endregion

#region Fine-Grained Password Policies
$script:FGPPTabLoaded = $false
$script:FGPPEditTarget = $null

function Get-RdnValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DistinguishedName)

    if ($DistinguishedName -match '^[A-Za-z]+=(?<v>(?:\\.|[^,\\])+)') {
        return ($Matches['v'] -replace '\\(.)', '$1')
    }
    return $DistinguishedName
}

function Import-FGPPList {
    [CmdletBinding()]
    param()

    Assert-ADAvailable
    $policies = @(Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction Stop | Sort-Object -Property Precedence)
    $script:dgFGPP.ItemsSource = @(foreach ($p in $policies) {
            [pscustomobject]@{
                Name                 = $p.Name
                Precedence           = $p.Precedence
                MinPasswordLength    = $p.MinPasswordLength
                PasswordHistoryCount = $p.PasswordHistoryCount
                ComplexityEnabled    = $(if ($p.ComplexityEnabled) { 'Ja' } else { 'Nein' })
                MaxPasswordAge       = Format-TimeSpanText $p.MaxPasswordAge
                AppliesTo            = (@($p.AppliesTo) | Where-Object { $_ } | ForEach-Object { Get-RdnValue $_ }) -join ', '
                DistinguishedName    = $p.DistinguishedName
            }
        })
    Write-StatusMessage -Area FGPP -Message ("{0} FGPP geladen." -f $policies.Count) -NoLog
}

function Initialize-FGPPTab {
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:FGPPTabLoaded -and -not $Force) { return }
    Import-FGPPList
    $script:cmbFGPPGroups.ItemsSource = Get-GroupList -Refresh:$Force
    $script:FGPPTabLoaded = $true
}

function Reset-FGPPForm {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Setzt nur Formularfelder zurück.')]
    [CmdletBinding()]
    param()

    $script:FGPPEditTarget = $null
    $script:txtFGPPName.Text = ''
    $script:txtFGPPName.IsReadOnly = $false
    $script:txtFGPPPrecedence.Text = '10'
    $script:txtFGPPMinLength.Text = '14'
    $script:txtFGPPHistory.Text = '24'
    $script:txtFGPPMinAge.Text = '1'
    $script:txtFGPPMaxAge.Text = '0'
    $script:chkFGPPComplexity.IsChecked = $true
    $script:chkFGPPReversibleEncryption.IsChecked = $false
    $script:lstFGPPAppliedGroups.Items.Clear()
    $script:NewFGPPBox.Header = 'Neue FGPP erstellen'
    $script:btnCreateFGPP.Visibility = [System.Windows.Visibility]::Visible
    $script:btnSaveFGPP.Visibility = [System.Windows.Visibility]::Collapsed
    $script:btnCancelFGPP.Visibility = [System.Windows.Visibility]::Collapsed
}

function Read-FGPPForm {
    <#
    .SYNOPSIS
        Validiert das FGPP-Formular und liefert die Parameter als Hashtable (wirft bei ungueltigen Werten).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $readInt = {
        param([string]$Text, [string]$Label, [int]$Min, [int]$Max)
        $value = 0
        if (-not [int]::TryParse($Text.Trim(), [ref]$value) -or $value -lt $Min -or $value -gt $Max) {
            throw ("'{0}' muss eine ganze Zahl zwischen {1} und {2} sein." -f $Label, $Min, $Max)
        }
        $value
    }

    $name = $script:txtFGPPName.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Bitte einen Namen für die FGPP angeben.' }
    if ($name -match '[,\\/#+<>;"=]') { throw 'Der Name enthält unzulässige Zeichen ( , \ / # + < > ; " = ).' }

    $precedence = & $readInt $script:txtFGPPPrecedence.Text 'Priorität' 1 ([int]::MaxValue)
    $minLength = & $readInt $script:txtFGPPMinLength.Text 'Minimale Länge' 0 255
    $history = & $readInt $script:txtFGPPHistory.Text 'Kennwortchronik' 0 1024
    $minAge = & $readInt $script:txtFGPPMinAge.Text 'Minimales Alter (Tage)' 0 998
    $maxAge = & $readInt $script:txtFGPPMaxAge.Text 'Maximales Alter (Tage)' 0 999
    if ($maxAge -gt 0 -and $minAge -ge $maxAge) { throw 'Das minimale Kennwortalter muss kleiner als das maximale sein.' }

    return @{
        Name                        = $name
        Precedence                  = $precedence
        MinPasswordLength           = $minLength
        PasswordHistoryCount        = $history
        MinPasswordAge              = [TimeSpan]::FromDays($minAge)
        MaxPasswordAge              = [TimeSpan]::FromDays($maxAge)
        ComplexityEnabled           = [bool]$script:chkFGPPComplexity.IsChecked
        ReversibleEncryptionEnabled = [bool]$script:chkFGPPReversibleEncryption.IsChecked
    }
}

function Get-FGPPFormSubject {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(foreach ($item in $script:lstFGPPAppliedGroups.Items) { [string]$item.Tag })
}

function Add-FGPPFormGroup {
    [CmdletBinding()]
    param()

    $selected = $script:cmbFGPPGroups.SelectedItem
    if (-not $selected) {
        Write-StatusMessage -Area FGPP -Message 'Bitte eine Gruppe auswählen.' -Level WARN -NoLog
        return
    }
    $group = Get-ADGroup -Identity $selected.DistinguishedName -ErrorAction Stop
    if ((Get-FGPPFormSubject) -contains $group.DistinguishedName) { return }

    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = $group.Name
    $item.Tag = $group.DistinguishedName
    $item.ToolTip = $group.DistinguishedName
    [void]$script:lstFGPPAppliedGroups.Items.Add($item)
}

function Remove-FGPPFormGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Entfernt nur einen Eintrag aus dem Formular.')]
    [CmdletBinding()]
    param()

    $selected = $script:lstFGPPAppliedGroups.SelectedItem
    if ($selected) { $script:lstFGPPAppliedGroups.Items.Remove($selected) }
}

function New-FGPP {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][hashtable]$Setting,
        [string[]]$Subject = @()
    )

    $Subject = @($Subject | Where-Object { $_ })
    if (-not $PSCmdlet.ShouldProcess($Setting.Name, 'FGPP erstellen')) { return }
    New-ADFineGrainedPasswordPolicy @Setting -ErrorAction Stop
    if ($Subject.Count -gt 0) {
        Add-ADFineGrainedPasswordPolicySubject -Identity $Setting.Name -Subjects $Subject -ErrorAction Stop
    }
    Write-AppLog -Message ("FGPP erstellt: {0} (Priorität {1}, Ziele: {2})" -f $Setting.Name, $Setting.Precedence, ($Subject -join '; '))
}

function Set-FGPP {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][hashtable]$Setting,
        [string[]]$Subject = @()
    )

    $Subject = @($Subject | Where-Object { $_ })
    if (-not $PSCmdlet.ShouldProcess($Identity, 'FGPP ändern')) { return }

    $params = @{} + $Setting
    $params.Remove('Name')
    Set-ADFineGrainedPasswordPolicy -Identity $Identity @params -ErrorAction Stop

    $current = @((Get-ADFineGrainedPasswordPolicy -Identity $Identity -ErrorAction Stop).AppliesTo | Where-Object { $_ })
    $toAdd = @($Subject | Where-Object { $current -notcontains $_ })
    $toRemove = @($current | Where-Object { $Subject -notcontains $_ })
    if ($toAdd.Count -gt 0) { Add-ADFineGrainedPasswordPolicySubject -Identity $Identity -Subjects $toAdd -ErrorAction Stop }
    if ($toRemove.Count -gt 0) { Remove-ADFineGrainedPasswordPolicySubject -Identity $Identity -Subjects $toRemove -Confirm:$false -ErrorAction Stop }
    Write-AppLog -Message ("FGPP geändert: {0} (+{1} / -{2} Ziele)" -f $Identity, $toAdd.Count, $toRemove.Count)
}

function Remove-FGPP {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Identity)

    if (-not $PSCmdlet.ShouldProcess($Identity, 'FGPP löschen')) { return }
    $policy = Get-ADFineGrainedPasswordPolicy -Identity $Identity -Properties ProtectedFromAccidentalDeletion -ErrorAction Stop
    if ($policy.ProtectedFromAccidentalDeletion) {
        Set-ADFineGrainedPasswordPolicy -Identity $Identity -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
    }
    Remove-ADFineGrainedPasswordPolicy -Identity $Identity -Confirm:$false -ErrorAction Stop
    Write-AppLog -Message ("FGPP gelöscht: {0}" -f $Identity)
}

function Invoke-FGPPCreate {
    [CmdletBinding()]
    param()

    Assert-ADAvailable
    $setting = Read-FGPPForm
    if ($setting.ReversibleEncryptionEnabled -and -not (Confirm-Action -Message 'Umkehrbare Verschlüsselung speichert Kennwörter faktisch im Klartext und wird nicht empfohlen. Trotzdem aktivieren?' -Icon Warning)) { return }
    $subject = Get-FGPPFormSubject
    if (-not (Confirm-Action -Message ("FGPP '{0}' mit Priorität {1} für {2} Gruppe(n) erstellen?" -f $setting.Name, $setting.Precedence, $subject.Count))) { return }

    New-FGPP -Setting $setting -Subject $subject -Confirm:$false
    Write-StatusMessage -Area FGPP -Message ("FGPP '{0}' erstellt." -f $setting.Name) -NoLog
    Reset-FGPPForm
    Import-FGPPList
}

function Invoke-FGPPEdit {
    [CmdletBinding()]
    param()

    $row = $script:dgFGPP.SelectedItem
    if (-not $row) {
        Write-StatusMessage -Area FGPP -Message 'Bitte eine FGPP in der Liste auswählen.' -Level WARN -NoLog
        return
    }

    $policy = Get-ADFineGrainedPasswordPolicy -Identity $row.DistinguishedName -ErrorAction Stop
    Reset-FGPPForm
    $script:FGPPEditTarget = $policy.DistinguishedName
    $script:txtFGPPName.Text = $policy.Name
    $script:txtFGPPName.IsReadOnly = $true
    $script:txtFGPPPrecedence.Text = [string]$policy.Precedence
    $script:txtFGPPMinLength.Text = [string]$policy.MinPasswordLength
    $script:txtFGPPHistory.Text = [string]$policy.PasswordHistoryCount
    $script:txtFGPPMinAge.Text = [string][math]::Floor(([TimeSpan]$policy.MinPasswordAge).TotalDays)
    $maxDays = [math]::Floor(([TimeSpan]$policy.MaxPasswordAge).TotalDays)
    $script:txtFGPPMaxAge.Text = if ($maxDays -lt 0 -or $maxDays -gt 999) { '0' } else { [string]$maxDays }
    $script:chkFGPPComplexity.IsChecked = [bool]$policy.ComplexityEnabled
    $script:chkFGPPReversibleEncryption.IsChecked = [bool]$policy.ReversibleEncryptionEnabled

    foreach ($dn in @($policy.AppliesTo | Where-Object { $_ })) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = Get-RdnValue $dn
        $item.Tag = [string]$dn
        $item.ToolTip = [string]$dn
        [void]$script:lstFGPPAppliedGroups.Items.Add($item)
    }

    $script:NewFGPPBox.Header = "FGPP bearbeiten: $($policy.Name)"
    $script:btnCreateFGPP.Visibility = [System.Windows.Visibility]::Collapsed
    $script:btnSaveFGPP.Visibility = [System.Windows.Visibility]::Visible
    $script:btnCancelFGPP.Visibility = [System.Windows.Visibility]::Visible
    Write-StatusMessage -Area FGPP -Message ("Bearbeitungsmodus für '{0}'." -f $policy.Name) -NoLog
}

function Invoke-FGPPSave {
    [CmdletBinding()]
    param()

    if (-not $script:FGPPEditTarget) {
        Write-StatusMessage -Area FGPP -Message 'Keine FGPP im Bearbeitungsmodus.' -Level WARN -NoLog
        return
    }
    $setting = Read-FGPPForm
    if ($setting.ReversibleEncryptionEnabled -and -not (Confirm-Action -Message 'Umkehrbare Verschlüsselung speichert Kennwörter faktisch im Klartext und wird nicht empfohlen. Trotzdem aktivieren?' -Icon Warning)) { return }
    if (-not (Confirm-Action -Message ("Änderungen an FGPP '{0}' speichern?" -f $setting.Name))) { return }

    Set-FGPP -Identity $script:FGPPEditTarget -Setting $setting -Subject (Get-FGPPFormSubject) -Confirm:$false
    Write-StatusMessage -Area FGPP -Message ("FGPP '{0}' gespeichert." -f $setting.Name) -NoLog
    Reset-FGPPForm
    Import-FGPPList
}

function Invoke-FGPPDelete {
    [CmdletBinding()]
    param()

    $row = $script:dgFGPP.SelectedItem
    if (-not $row) {
        Write-StatusMessage -Area FGPP -Message 'Bitte eine FGPP in der Liste auswählen.' -Level WARN -NoLog
        return
    }
    if (-not (Confirm-Action -Message ("FGPP '{0}' endgültig löschen?`n`nBetroffene Ziele: {1}" -f $row.Name, $row.AppliesTo) -Title 'FGPP löschen' -Icon Warning)) { return }

    Remove-FGPP -Identity $row.DistinguishedName -Confirm:$false
    Write-StatusMessage -Area FGPP -Message ("FGPP '{0}' gelöscht." -f $row.Name) -NoLog
    if ($script:FGPPEditTarget -eq $row.DistinguishedName) { Reset-FGPPForm }
    Import-FGPPList
}
#endregion

#region XAML
$script:XamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="easyPASSWORDRESET" Height="900" Width="1250" MinHeight="720" MinWidth="1000"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize" FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="12,5"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="MinWidth" Value="110"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Margin" Value="0,0,10,10"/>
            <Setter Property="Padding" Value="8"/>
        </Style>
        <Style x:Key="ReadOnlyBox" TargetType="TextBox">
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="Margin" Value="0,2,0,2"/>
            <Setter Property="Background" Value="#F5F5F5"/>
        </Style>
        <Style x:Key="StatusBox" TargetType="TextBox">
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Height" Value="110"/>
            <Setter Property="Margin" Value="0,6,0,0"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border x:Name="HeaderBackground" Grid.Row="0" Background="#0078D7" Padding="16,10">
            <DockPanel LastChildFill="False">
                <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="HeaderAppName" Text="easyPASSWORDRESET" Foreground="White" FontSize="22" FontWeight="Bold"/>
                    <TextBlock x:Name="HeaderVersion" Foreground="White" FontSize="13" Margin="12,0,0,2" VerticalAlignment="Bottom"/>
                </StackPanel>
                <TextBlock x:Name="txtADStatus" DockPanel.Dock="Right" Foreground="White" VerticalAlignment="Center"/>
            </DockPanel>
        </Border>

        <TabControl x:Name="mainTabControl" Grid.Row="1" Margin="10">
            <!-- Einzelbenutzer -->
            <TabItem Header="Einzelbenutzer">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <GroupBox Header="Benutzersuche" Grid.Row="0" Grid.ColumnSpan="2">
                        <DockPanel>
                            <Button x:Name="btnSearchUser" DockPanel.Dock="Right" Content="Suchen" Margin="8,0,0,0" IsDefault="False"/>
                            <TextBox x:Name="txtUsername" VerticalContentAlignment="Center" Padding="4"
                                     ToolTip="Anmeldename, UPN, Vor-/Nachname oder Anzeigename (Enter startet die Suche)"/>
                        </DockPanel>
                    </GroupBox>

                    <GroupBox Header="Benutzerinformationen" Grid.Row="1" Grid.Column="0">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="160"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="Anzeigename:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserDisplayName" Grid.Row="0" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="1" Text="E-Mail:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserEmail" Grid.Row="1" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="2" Text="Anmeldename:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtSamAccountName" Grid.Row="2" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="3" Text="Beschreibung:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserDescription" Grid.Row="3" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="4" Text="Abteilung:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserDepartment" Grid.Row="4" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="5" Text="Status:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserStatus" Grid.Row="5" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="6" Text="Letzte Anmeldung:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserLastLogon" Grid.Row="6" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                            <TextBlock Grid.Row="7" Text="Kennwort läuft ab:" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtUserPwdExpiry" Grid.Row="7" Grid.Column="1" Style="{StaticResource ReadOnlyBox}"/>
                        </Grid>
                    </GroupBox>

                    <StackPanel Grid.Row="1" Grid.Column="1">
                        <GroupBox Header="Kennwort zurücksetzen">
                            <StackPanel>
                                <TextBlock Text="Neues Kennwort (wird zufällig erzeugt):" Margin="0,0,0,4"/>
                                <Grid>
                                    <PasswordBox x:Name="txtGeneratedPassword" Padding="4" IsHitTestVisible="False" Focusable="False" Background="#F5F5F5"/>
                                    <TextBox x:Name="txtGeneratedPasswordVisible" Padding="4" IsReadOnly="True" FontFamily="Consolas" FontSize="15" Visibility="Collapsed"/>
                                </Grid>
                                <CheckBox x:Name="chkShowPassword" Content="Kennwort anzeigen" Margin="0,6,0,8"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="btnReset" Content="Kennwort zurücksetzen" IsEnabled="False"/>
                                    <Button x:Name="btnUnlock" Content="Konto entsperren" IsEnabled="False"/>
                                </StackPanel>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="Kontooptionen">
                            <StackPanel>
                                <CheckBox x:Name="chkMustChangePassword" Content="Benutzer muss Kennwort bei nächster Anmeldung ändern" Margin="0,2"/>
                                <CheckBox x:Name="chkPasswordNeverExpires" Content="Kennwort läuft nie ab" Margin="0,2"/>
                                <CheckBox x:Name="chkCannotChangePassword" Content="Benutzer kann Kennwort nicht ändern" Margin="0,2"/>
                                <CheckBox x:Name="chkAccountEnabled" Content="Konto aktiviert" Margin="0,2,0,8"/>
                                <Button x:Name="btnApplyOptions" Content="Optionen übernehmen" HorizontalAlignment="Left" IsEnabled="False"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>

                    <TextBox x:Name="txtStatus" Grid.Row="2" Grid.ColumnSpan="2" Style="{StaticResource StatusBox}"/>
                </Grid>
            </TabItem>

            <!-- OU / Gruppe -->
            <TabItem Header="OU / Gruppe">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <GroupBox Header="Organisationseinheiten" Grid.Column="0">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                                <CheckBox x:Name="chkIncludeSubOUs" Content="Unter-OUs einbeziehen" Margin="0,0,0,8"/>
                                <WrapPanel>
                                    <Button x:Name="btnResetOU" Content="Kennwörter zurücksetzen" Margin="0,0,8,4"/>
                                    <Button x:Name="btnUnlockOU" Content="Konten entsperren" Margin="0,0,8,4"/>
                                    <Button x:Name="btnRefreshOU" Content="Aktualisieren" Margin="0,0,8,4"/>
                                </WrapPanel>
                            </StackPanel>
                            <TreeView x:Name="treeViewOUs" VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"/>
                        </DockPanel>
                    </GroupBox>

                    <GroupBox Header="Gruppen" Grid.Column="1">
                        <DockPanel>
                            <ComboBox x:Name="cmbGroups" DockPanel.Dock="Top" IsTextSearchEnabled="True" DisplayMemberPath="Display" TextSearch.TextPath="Display" Margin="0,0,0,8">
                                <ComboBox.ItemsPanel>
                                    <ItemsPanelTemplate>
                                        <VirtualizingStackPanel/>
                                    </ItemsPanelTemplate>
                                </ComboBox.ItemsPanel>
                            </ComboBox>
                            <WrapPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                                <Button x:Name="btnResetGroup" Content="Kennwörter zurücksetzen" Margin="0,0,8,4"/>
                                <Button x:Name="btnUnlockGroup" Content="Konten entsperren" Margin="0,0,8,4"/>
                            </WrapPanel>
                            <TextBlock DockPanel.Dock="Top" Text="Direkte Benutzer-Mitglieder:" Margin="0,0,0,4"/>
                            <ListBox x:Name="lstGroupMembers" VirtualizingStackPanel.IsVirtualizing="True"/>
                        </DockPanel>
                    </GroupBox>

                    <TextBox x:Name="txtStatus2" Grid.Row="1" Grid.ColumnSpan="2" Style="{StaticResource StatusBox}"/>
                </Grid>
            </TabItem>

            <!-- Kennwortrichtlinie -->
            <TabItem Header="Kennwortrichtlinie">
                <DockPanel Margin="10">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
                        <Button x:Name="btnRefreshPolicies" Content="Aktualisieren"/>
                    </StackPanel>
                    <TextBox x:Name="txtStatus3" DockPanel.Dock="Bottom" Style="{StaticResource StatusBox}"/>
                    <DataGrid x:Name="dgPasswordPolicies" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                              HeadersVisibility="Column" GridLinesVisibility="Horizontal">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Einstellung" Binding="{Binding Einstellung}" Width="220"/>
                            <DataGridTextColumn Header="Aktueller Wert" Binding="{Binding Wert}" Width="160"/>
                            <DataGridTextColumn Header="Empfehlung" Binding="{Binding Empfehlung}" Width="*"/>
                            <DataGridTextColumn Header="Bewertung" Binding="{Binding Bewertung}" Width="110"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>

            <!-- FGPP -->
            <TabItem Header="Fine-Grained Password Policies">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
                        <Button x:Name="btnRefreshFGPP" Content="Aktualisieren"/>
                        <Button x:Name="btnEditFGPP" Content="Bearbeiten"/>
                        <Button x:Name="btnDeleteFGPP" Content="Löschen"/>
                    </StackPanel>
                    <DataGrid x:Name="dgFGPP" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                              SelectionMode="Single" HeadersVisibility="Column" MinHeight="120">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="180"/>
                            <DataGridTextColumn Header="Priorität" Binding="{Binding Precedence}" Width="80"/>
                            <DataGridTextColumn Header="Min. Länge" Binding="{Binding MinPasswordLength}" Width="90"/>
                            <DataGridTextColumn Header="Chronik" Binding="{Binding PasswordHistoryCount}" Width="80"/>
                            <DataGridTextColumn Header="Komplexität" Binding="{Binding ComplexityEnabled}" Width="90"/>
                            <DataGridTextColumn Header="Max. Alter" Binding="{Binding MaxPasswordAge}" Width="110"/>
                            <DataGridTextColumn Header="Gilt für" Binding="{Binding AppliesTo}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <GroupBox x:Name="NewFGPPBox" Grid.Row="2" Header="Neue FGPP erstellen" Margin="0,10,0,0">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid Grid.Column="0" Margin="0,0,16,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="200"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <TextBlock Grid.Row="0" Text="Name:" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPName" Grid.Row="0" Grid.Column="1" Margin="0,2"/>
                                <TextBlock Grid.Row="1" Text="Priorität (1 = höchste):" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPPrecedence" Grid.Row="1" Grid.Column="1" Margin="0,2"/>
                                <TextBlock Grid.Row="2" Text="Minimale Länge:" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPMinLength" Grid.Row="2" Grid.Column="1" Margin="0,2"/>
                                <TextBlock Grid.Row="3" Text="Kennwortchronik:" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPHistory" Grid.Row="3" Grid.Column="1" Margin="0,2"/>
                                <TextBlock Grid.Row="4" Text="Minimales Alter (Tage):" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPMinAge" Grid.Row="4" Grid.Column="1" Margin="0,2"/>
                                <TextBlock Grid.Row="5" Text="Maximales Alter (Tage, 0 = nie):" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPMaxAge" Grid.Row="5" Grid.Column="1" Margin="0,2"/>
                                <StackPanel Grid.Row="6" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,6,0,0">
                                    <CheckBox x:Name="chkFGPPComplexity" Content="Komplexität erforderlich" Margin="0,0,16,0"/>
                                    <CheckBox x:Name="chkFGPPReversibleEncryption" Content="Umkehrbare Verschlüsselung (nicht empfohlen)"/>
                                </StackPanel>
                            </Grid>
                            <DockPanel Grid.Column="1">
                                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                                    <Button x:Name="btnAddGroup" DockPanel.Dock="Right" Content="Hinzufügen" Margin="8,0,0,0"/>
                                    <ComboBox x:Name="cmbFGPPGroups" IsTextSearchEnabled="True" DisplayMemberPath="Display" TextSearch.TextPath="Display">
                                        <ComboBox.ItemsPanel>
                                            <ItemsPanelTemplate>
                                                <VirtualizingStackPanel/>
                                            </ItemsPanelTemplate>
                                        </ComboBox.ItemsPanel>
                                    </ComboBox>
                                </DockPanel>
                                <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,6,0,0">
                                    <Button x:Name="btnRemoveGroup" Content="Entfernen"/>
                                    <Button x:Name="btnCreateFGPP" Content="FGPP erstellen"/>
                                    <Button x:Name="btnSaveFGPP" Content="Speichern" Visibility="Collapsed"/>
                                    <Button x:Name="btnCancelFGPP" Content="Abbrechen" Visibility="Collapsed"/>
                                </StackPanel>
                                <ListBox x:Name="lstFGPPAppliedGroups" MinHeight="90"/>
                            </DockPanel>
                        </Grid>
                    </GroupBox>

                    <TextBox x:Name="txtStatus4" Grid.Row="3" Style="{StaticResource StatusBox}"/>
                </Grid>
            </TabItem>
        </TabControl>

        <Border x:Name="FooterBackground" Grid.Row="2" Background="#0078D7" Padding="16,6">
            <DockPanel>
                <TextBlock x:Name="FooterWebsite" DockPanel.Dock="Right" Foreground="White" Cursor="Hand" TextDecorations="Underline"/>
                <TextBlock x:Name="FooterText" Foreground="White"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
'@
#endregion

#region Fenster und Ereignisse
function Initialize-MainWindow {
    [CmdletBinding()]
    param()

    [xml]$xml = $script:XamlText
    $script:Window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))

    foreach ($match in [regex]::Matches($script:XamlText, 'x:Name="(\w+)"')) {
        $controlName = $match.Groups[1].Value
        $control = $script:Window.FindName($controlName)
        if ($null -eq $control) { throw "Steuerelement '$controlName' wurde nicht gefunden." }
        Set-Variable -Name $controlName -Value $control -Scope Script
    }

    $brush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($script:Config.ThemeColor)
    $script:HeaderBackground.Background = $brush
    $script:FooterBackground.Background = $brush
    $script:Window.Title = '{0} {1}' -f $script:Config.AppName, $script:AppVersion
    $script:HeaderAppName.Text = $script:Config.AppName
    $script:HeaderVersion.Text = 'Version {0}' -f $script:AppVersion
    $script:FooterText.Text = $script:Config.FooterText
    $script:FooterWebsite.Text = $script:Config.FooterWebsite
}

function Open-WebsiteLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    $uri = $null
    if ([System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -and ($uri.Scheme -eq 'https' -or $uri.Scheme -eq 'http')) {
        Start-Process -FilePath $uri.AbsoluteUri
    }
    else {
        Write-AppLog -Message "Ungültige Website-URL in der Konfiguration: $Url" -Level WARN
    }
}

function Register-EventHandler {
    [CmdletBinding()]
    param()

    # Einzelbenutzer
    $script:btnSearchUser.Add_Click({ Invoke-UiAction -Name 'Benutzersuche' -Area User -Action { Invoke-UserSearch } })
    $script:txtUsername.Add_KeyDown({
            if ($_.Key -eq [System.Windows.Input.Key]::Return) {
                $_.Handled = $true
                Invoke-UiAction -Name 'Benutzersuche' -Area User -Action { Invoke-UserSearch }
            }
        })
    $script:btnReset.Add_Click({ Invoke-UiAction -Name 'Kennwort zurücksetzen' -Area User -Action { Invoke-UserPasswordReset } })
    $script:btnUnlock.Add_Click({ Invoke-UiAction -Name 'Konto entsperren' -Area User -Action { Invoke-UserUnlock } })
    $script:btnApplyOptions.Add_Click({ Invoke-UiAction -Name 'Optionen übernehmen' -Area User -Action { Invoke-UserOptionApply } })
    $script:chkShowPassword.Add_Checked({
            $script:txtGeneratedPasswordVisible.Text = $script:txtGeneratedPassword.Password
            $script:txtGeneratedPasswordVisible.Visibility = [System.Windows.Visibility]::Visible
            $script:txtGeneratedPassword.Visibility = [System.Windows.Visibility]::Collapsed
        })
    $script:chkShowPassword.Add_Unchecked({
            $script:txtGeneratedPasswordVisible.Clear()
            $script:txtGeneratedPasswordVisible.Visibility = [System.Windows.Visibility]::Collapsed
            $script:txtGeneratedPassword.Visibility = [System.Windows.Visibility]::Visible
        })

    # OU / Gruppe
    $script:btnRefreshOU.Add_Click({ Invoke-UiAction -Name 'OUs und Gruppen laden' -Area Bulk -Action { Initialize-BulkTab -Force } })
    $script:cmbGroups.Add_SelectionChanged({ Invoke-UiAction -Name 'Gruppenmitglieder laden' -Area Bulk -Action { Update-GroupMemberList } })
    $script:btnResetOU.Add_Click({ Invoke-UiAction -Name 'Kennwort-Reset (OU)' -Area Bulk -Action { Invoke-BulkPasswordReset -Source OU } })
    $script:btnUnlockOU.Add_Click({ Invoke-UiAction -Name 'Entsperren (OU)' -Area Bulk -Action { Invoke-BulkUnlock -Source OU } })
    $script:btnResetGroup.Add_Click({ Invoke-UiAction -Name 'Kennwort-Reset (Gruppe)' -Area Bulk -Action { Invoke-BulkPasswordReset -Source Group } })
    $script:btnUnlockGroup.Add_Click({ Invoke-UiAction -Name 'Entsperren (Gruppe)' -Area Bulk -Action { Invoke-BulkUnlock -Source Group } })

    # Kennwortrichtlinie
    $script:btnRefreshPolicies.Add_Click({ Invoke-UiAction -Name 'Kennwortrichtlinie laden' -Area Policy -Action { Show-DomainPasswordPolicy } })

    # FGPP
    $script:btnRefreshFGPP.Add_Click({ Invoke-UiAction -Name 'FGPP laden' -Area FGPP -Action { Initialize-FGPPTab -Force } })
    $script:btnEditFGPP.Add_Click({ Invoke-UiAction -Name 'FGPP bearbeiten' -Area FGPP -Action { Invoke-FGPPEdit } })
    $script:dgFGPP.Add_MouseDoubleClick({ Invoke-UiAction -Name 'FGPP bearbeiten' -Area FGPP -Action { Invoke-FGPPEdit } })
    $script:btnDeleteFGPP.Add_Click({ Invoke-UiAction -Name 'FGPP löschen' -Area FGPP -Action { Invoke-FGPPDelete } })
    $script:btnCreateFGPP.Add_Click({ Invoke-UiAction -Name 'FGPP erstellen' -Area FGPP -Action { Invoke-FGPPCreate } })
    $script:btnSaveFGPP.Add_Click({ Invoke-UiAction -Name 'FGPP speichern' -Area FGPP -Action { Invoke-FGPPSave } })
    $script:btnCancelFGPP.Add_Click({ Invoke-UiAction -Name 'FGPP-Bearbeitung abbrechen' -Area FGPP -Action { Reset-FGPPForm } })
    $script:btnAddGroup.Add_Click({ Invoke-UiAction -Name 'Gruppe hinzufügen' -Area FGPP -Action { Add-FGPPFormGroup } })
    $script:btnRemoveGroup.Add_Click({ Invoke-UiAction -Name 'Gruppe entfernen' -Area FGPP -Action { Remove-FGPPFormGroup } })

    # Tabs erst beim ersten Oeffnen laden (SelectionChanged anderer Steuerelemente wird durchgereicht und ignoriert)
    $script:mainTabControl.Add_SelectionChanged({
            if (-not [object]::ReferenceEquals($_.OriginalSource, $script:mainTabControl)) { return }
            switch ($script:mainTabControl.SelectedIndex) {
                1 { Invoke-UiAction -Name 'OUs und Gruppen laden' -Area Bulk -Action { Initialize-BulkTab } }
                2 { if (-not $script:PolicyTabLoaded) { Invoke-UiAction -Name 'Kennwortrichtlinie laden' -Area Policy -Action { Show-DomainPasswordPolicy } } }
                3 { Invoke-UiAction -Name 'FGPP laden' -Area FGPP -Action { Initialize-FGPPTab } }
            }
        })

    # Footer und Fenster
    $script:FooterWebsite.Add_MouseLeftButtonUp({ Open-WebsiteLink -Url $script:Config.FooterWebsite })
    $script:Window.Add_ContentRendered({ $script:txtUsername.Focus() | Out-Null })
    $script:Window.Add_Closed({ Clear-GeneratedPassword })
}
#endregion

#region Hauptprogramm
Initialize-Logging
Write-AppLog -Message ("{0} {1} gestartet (PowerShell {2})." -f $script:Config.AppName, $script:AppVersion, $PSVersionTable.PSVersion)

try {
    $adModuleLoaded = Initialize-ActiveDirectory
}
catch {
    $adModuleLoaded = $false
    Write-AppLog -Message "ActiveDirectory-Modul konnte nicht geladen werden: $($_.Exception.Message)" -Level ERROR
}

if (-not $adModuleLoaded) {
    Show-MessageBox -Icon Error -Message ("Das PowerShell-Modul 'ActiveDirectory' (RSAT) ist nicht verfügbar.`n`n" +
        "Windows 10/11:`nAdd-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`n`n" +
        "Windows Server:`nInstall-WindowsFeature RSAT-AD-PowerShell") | Out-Null
    $script:Rng.Dispose()
    exit 1
}

try {
    Initialize-MainWindow
    Register-EventHandler
    Clear-UserDetail
    Reset-FGPPForm
    Update-ADStatusDisplay
    if (-not $script:ADAvailable) {
        Write-StatusMessage -Area User -Message 'Die Domäne ist derzeit nicht erreichbar. Vorgänge versuchen erneut, eine Verbindung herzustellen.' -Level WARN
    }
    [void]$script:Window.ShowDialog()
}
catch {
    Write-AppLog -Message ("Unerwarteter Fehler: {0} | {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) -Level ERROR
    Show-MessageBox -Icon Error -Message "Unerwarteter Fehler:`n`n$($_.Exception.Message)" | Out-Null
}
finally {
    $script:Rng.Dispose()
    Write-AppLog -Message ("{0} beendet." -f $script:Config.AppName)
}
#endregion
