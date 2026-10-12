# easyPASSWORDRESET.ps1

<#
.SYNOPSIS
    Tool zum sicheren Zurücksetzen oder Entsperren von Active Directory-Passwörtern.
.DESCRIPTION
    Dieses Skript bietet eine GUI für Administratoren, um Benutzerpasswörter einzeln, OU-weit, gruppenweit oder für eine Benutzerliste
    zurückzusetzen oder zu entsperren. Es bietet zusätzlich die Möglichkeit, HTML- und TXT-Berichte zu generieren.
.NOTES
    Autor: Andreas Hepp
    Version: 0.0.1
    Voraussetzungen:
    - Active Directory-Modul für Windows PowerShell
    - Ausführung mit Administratorrechten für AD-Operationen
#>
# BASISVARIABLEN MIT GARANTIERTEN STANDARDWERTEN INITIALISIEREN
# Kritische Dateipfade und Variablen
$script:CurrentDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:CurrentDir)) {
    $script:CurrentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($script:CurrentDir)) {
        $script:CurrentDir = $PWD.Path
    }
}

# Temporären Logpfad setzen für die initiale Phase
$script:TempLogFile = "$env:TEMP\easyPASSWORD_temp.log"
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') - [STARTUP] Script gestartet mit Pfad: $script:CurrentDir" | Out-File -FilePath $script:TempLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue

# ABSOLUT NOTWENDIGES LOGGING MIT GARANTIERTER AUSFÜHRUNG
function Write-StartupLog {
    param (
        [string]$Message,
        [string]$Type = "ERROR" # Typ: DEBUG, INFO, WARNING, ERROR, CRITICAL
    )

    # Direkte Ausgabe in Temp-Datei ohne Fehlerbehandlung
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logEntry = "[$timestamp] [$Type] $Message"

        # 1. Direkte Ausgabe auf Konsole
        Write-Host $logEntry -ForegroundColor Cyan

        # 2. In temporäre Datei schreiben
        $logEntry | Out-File -FilePath $script:TempLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {
        # Absoluter Fallback bei Fehler - Konsole
        try { Write-Information -MessageData "[CRITICAL] Logging failed: $($_.Exception.Message)" -InformationAction Continue } catch {}
    }
}

# Direkt ausgeführter Systemcheck
try {
    Write-StartupLog "SYSTEM CHECK: Initialisierungsphase gestartet" "DEBUG"

    # Kritische Assemblies prüfen/laden
    $assembliesOK = $true
    $requiredAssemblies = @("PresentationFramework", "PresentationCore", "WindowsBase")

    foreach ($assembly in $requiredAssemblies) {
        try {
            [void][System.Reflection.Assembly]::LoadWithPartialName($assembly)
            Write-StartupLog "Assembly $assembly erfolgreich geladen" "DEBUG"
        } catch {
            $assembliesOK = $false
            Write-StartupLog "FEHLER: Assembly $assembly konnte nicht geladen werden: $($_.Exception.Message)" "ERROR"
        }
    }

    if (-not $assembliesOK) {
        Write-StartupLog "KRITISCH: Einige benötigte Assemblies konnten nicht geladen werden!" "ERROR"
    }

    # Prüfung der Existenz des aktuellen Verzeichnisses
    if (-not (Test-Path -Path $script:CurrentDir)) {
        Write-StartupLog "KRITISCH: Aktuelles Verzeichnis existiert nicht: $script:CurrentDir" "ERROR"
    } else {
        Write-StartupLog "Aktuelles Verzeichnis gefunden: $script:CurrentDir" "DEBUG"
    }

    # Alle Environment-Variablen überprüfen
    Write-StartupLog "Aktuelle PowerShell Version: $($PSVersionTable.PSVersion)" "DEBUG"
    Write-StartupLog "Ausführender Benutzer: $($env:USERNAME)" "DEBUG"
    Write-StartupLog "Computername: $($env:COMPUTERNAME)" "DEBUG"

} catch {
    # Absoluter Fallback
    try {
        "[CRITICAL] Systemcheck failed: $($_.Exception.Message)" | Out-File -FilePath "$env:TEMP\easyPASSWORD_startup_error.log" -Append
    } catch {}
}

# GARANTIERTE DIREKTE DEBUG FUNKTIONEN - SOFORT VERFÜGBAR VOR CONFIG
# Diese Funktionen sind unabhängig von der Config-Struktur und arbeiten immer
function Write-GuaranteedDebug {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Component = "CORE",
        [string]$Level = "ERROR"
    )

    try {
        # Timestamp immer mit Millisekunden
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $debugMessage = "[$timestamp] [$Level] [$Component] $Message"

        # 1. Direkte Konsolenausgabe - IMMER
        $foregroundColor = switch ($Level.ToUpper()) {
            "INFO" { "Cyan" }
            "WARNING" { "Yellow" }
            "ERROR" { "Red" }
            "CRITICAL" { "Magenta" }
            default { "Gray" }
        }

        # Direkte Write-Host ohne try/catch
        Write-Host $debugMessage -ForegroundColor $foregroundColor

        # 2. In temporäre Datei schreiben
        $debugMessage | Out-File -FilePath $script:TempLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue

        # 3. Auch direkt in Standard-Ausgabekanal für Pipe-Weiterleitung
        Write-Output $debugMessage

        # 4. Für spätere Zugriffe und PowerShell-Standard-Tracing
        if ($Level.ToUpper() -eq "DEBUG") {
            $DebugMessage = $debugMessage  # Für PSDebug
            Write-Debug $debugMessage
        } elseif ($Level.ToUpper() -eq "INFO" -or $Level.ToUpper() -eq "VERBOSE") {
            Write-Verbose $debugMessage
        } elseif ($Level.ToUpper() -eq "WARNING") {
            Write-Warning $debugMessage
        } elseif ($Level.ToUpper() -eq "ERROR" -or $Level.ToUpper() -eq "CRITICAL") {
            Write-Error $debugMessage -ErrorAction Continue
        }
    } catch {
        # Absoluter Fallback - direkte Konsolenausgabe ohne jegliche Formatierung
        try {
            $rawMessage = "[CRITICAL-FALLBACK] $Message | Error: $($_.Exception.Message)"
            [Console]::WriteLine($rawMessage)
            $rawMessage | Out-File -FilePath "$env:TEMP\easyPASSWORD_debug_critical.log" -Append
        } catch {
            Write-Debug "Failed to write the emergency diagnostic log: $($_.Exception.Message)"
        }
    }
}
# Das garantiert, dass selbst bei Fehlern im Config-Block die Variable nicht NULL wird
$tempConfig = @{
    # Debug-Einstellungen - direkte Zuweisung mit Standardwerten
    Debug                 = 0  # 0 = Aus, 1 = An (Standardwert 1 für Debugging)
    VerboseDebug          = $true  # Noch detaillierteres Debugging

    # Allgemeine Einstellungen
    AppName               = "easyPASSWORDRESET"
    ThemeColor            = "#0078D7"  # Standard Windows 11 Blau
    LogFile               = "$PSScriptRoot\easyPASSWORDRESET.log"
    ReportFolder          = "$PSScriptRoot\Reports"

    # Webseiten und URLs
    HeaderLogoURL         = "https://www.phinit.de"
    FooterWebseite        = "www.phinit.de"
    FooterText            = "© $(Get-Date -Format 'yyyy') PhinIT easyPASSWORDRESET"

    # Passwortgenerator-Einstellungen
    DefaultPasswordLength = 12
    UseSpecialChars       = $true
    UseNumbers            = $true
    UseUppercase          = $true
    UseLowercase          = $true

    # Standard-Werte
    DefaultPassword       = "Passwort1!"  # Für manuelle Passwort-Resets

    # Tab-Namen für die Navigation
    TabNames              = @{
        SingleUser = "Einzelne User"
        OUGroup    = "OU/Gruppe Auswählen"
        Policies   = "Passwort-Richtlinien"
        FGPP       = "FGPP-Verwaltung"
    }

    # Performance-Optimierungen
    MaxItemsPerJob        = 50  # Maximale Anzahl an Benutzern pro Job
    MaxJobs               = 10         # Maximale Anzahl paralleler Jobs
}

# Globale Config zuweisen - selbst bei Fehlern ist die Variable jetzt nicht NULL
$script:Config = $tempConfig
Write-GuaranteedDebug -Message "Konfiguration geladen mit Debug = $($script:Config.Debug)" -Level "INFO"

# Variablen (aus Config) mit Absicherung gegen NULL-Werte
$script:AppName = $script:Config.AppName
$script:ThemeColor = $script:Config.ThemeColor
$script:LogFile = Join-Path -Path $script:CurrentDir -ChildPath "easyPASSWORDRESET.log"
$script:HeaderLogoURL = $script:Config.HeaderLogoURL
$script:FooterWebseite = $script:Config.FooterWebseite
$script:ReportFolder = Join-Path -Path $script:CurrentDir -ChildPath "Reports"

# FINAL DEBUG FUNCTION SETUP - Nach der Config
# Erweiterte Debug-Funktion, die vom Debug-Flag abhängig ist
function Write-DebugMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Component = "General",
        [ValidateSet("Info", "Warning", "Error", "Critical", "Debug")]
        [string]$Level = "Info",
        [string]$FunctionName = $null,
        [int]$LineNumber = 0,
        [switch]$ToFile = $false
    )

    # Direkte Ausgabe unabhängig von Debug-Einstellung!
    try {
        # Wenn FunctionName nicht angegeben wurde, versuche den aktuellen Funktionsnamen zu ermitteln
        if ([string]::IsNullOrEmpty($FunctionName)) {
            $callStack = Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 1
            if ($null -ne $callStack) {
                $FunctionName = $callStack.Command
                if ($LineNumber -eq 0) {
                    $LineNumber = $callStack.ScriptLineNumber
                }
            }
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $debugMessage = "[$timestamp] [DEBUG] [$Component] "

        # Funktions- und Zeilennummer hinzufügen, wenn verfügbar
        if (-not [string]::IsNullOrEmpty($FunctionName)) {
            $debugMessage += "[$FunctionName"
            if ($LineNumber -gt 0) {
                $debugMessage += ":$LineNumber"
            }
            $debugMessage += "] "
        }

        $debugMessage += "[$Level] $Message"

        # Zeichenfilterung für sichere Ausgabe
        $filteredMessage = [regex]::Replace($debugMessage, '[^\x20-\x7E]', '')

        # In die Konsole schreiben mit unterschiedlichen Farben je nach Level
        $foregroundColor = switch ($Level) {
            "Info" { "Cyan" }
            "Warning" { "Yellow" }
            "Error" { "Red" }
            "Critical" { "Magenta" }
            "Debug" { "Green" }
            default { "White" }
        }

        # DIREKTE AUSGABE
        # 1. Write-Host - immer ausführen!
        Write-Host $filteredMessage -ForegroundColor $foregroundColor

        # 2. Auch in den Temp-Log schreiben
        $filteredMessage | Out-File -FilePath $script:TempLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue

        # 3. In das reguläre Log schreiben, falls existiert
        if ($null -ne $script:LogFile -and (Test-Path -Path (Split-Path -Path $script:LogFile -Parent))) {
            try {
                $filteredMessage | Out-File -FilePath $script:LogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
            } catch {
                Write-Debug "Failed to write the regular log: $($_.Exception.Message)"
            }
        }

        # 4. In separate Debug-Datei schreiben
        if ($ToFile -or $script:Config.VerboseDebug) {
            try {
                $debugLogFile = Join-Path -Path $script:CurrentDir -ChildPath "easyPASSWORDRESET_debug.log"
                $filteredMessage | Out-File -FilePath $debugLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
            } catch {
                # Fallback zur temporären Datei
                $tempDebugLog = "$env:TEMP\easyPASSWORD_debug_file.log"
                "$(Get-Date) - $filteredMessage" | Out-File -FilePath $tempDebugLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
            }
        }

        # 5. Wenn zusätzliches verbose Debugging aktiviert ist, mehr Details ausgeben
        if ($script:Config.VerboseDebug) {
            try {
                $callStack = Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 3
                $callerInfo = "Call Stack:"
                foreach ($call in $callStack) {
                    $callerInfo += "`n  → $($call.Command) at line $($call.ScriptLineNumber) in $($call.ScriptName)"
                }
                Write-Host $callerInfo -ForegroundColor DarkGray

                # Bei kritischen Fehlern auch Stack Trace ausgeben
                if ($Level -eq "Critical" -or $Level -eq "Error") {
                    try {
                        # Aktuelle Variablen im Kontext ausgeben (nur wenn kritisch)
                        $contextVars = Get-Variable -Scope 1 | Where-Object {
                            -not [string]::IsNullOrEmpty($_.Name) -and
                            $_.Name -notmatch '^(\?|\^|_|PSItem|args|true|false|null)$' -and
                            -not ($_.Value -is [ScriptBlock])
                        } | ForEach-Object { "$($_.Name) = $(if ($null -eq $_.Value) { 'null' } else { $_.Value.ToString() })" }

                        if ($contextVars.Count -gt 0) {
                            Write-Host "Context Variables:" -ForegroundColor DarkGray
                            $contextVars | ForEach-Object { Write-Information -MessageData "  → $_" -InformationAction Continue }
                        }
                    } catch {
                        Write-Information -MessageData "Fehler beim Ausgeben der Kontextvariablen: $($_.Exception.Message)" -InformationAction Continue
                    }
                }
            } catch {
                Write-Host "Fehler beim Ausgeben des Call Stacks: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } catch {
        # Absoluter Fallback - direkte Ausgabe ohne try/catch
        try {
            $rawMessage = "[CRITICAL-FALLBACK] $Message | Error: $($_.Exception.Message)"
            [Console]::WriteLine($rawMessage)
            $rawMessage | Out-File -FilePath "$env:TEMP\easyPASSWORD_debug_critical.log" -Append
        } catch {
            Write-Debug "Failed to write the critical fallback log: $($_.Exception.Message)"
        }
    }
}

# Hilfsfunktionen für Logging und Fehlerbehandlung

# Logging-Funktion mit Zeichenfilterung und Fehlerbehandlung
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "Error" # Info, Warning, Error, Debug
    )
    try {
        # Zeichenfilterung: Nur druckbare ASCII-Zeichen erlauben (32-126)
        $filteredMessage = [regex]::Replace($Message, '[^\x20-\x7E]', '')

        # Längenbegrenzung
        if ($filteredMessage.Length -gt 1000) {
            $filteredMessage = $filteredMessage.Substring(0, 1000) + "... (gekürzt)"
        }

        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $LogEntry = "$Timestamp - [$Level] $filteredMessage"

        # Prüfen, ob die Logdatei zu groß wird (>10MB)
        if ((Test-Path -Path $script:LogFile) -and ((Get-Item -Path $script:LogFile).Length -gt 10MB)) {
            # Logdatei rotieren
            if (Test-Path -Path "$script:LogFile.old") {
                Remove-Item -Path "$script:LogFile.old" -Force
            }
            Rename-Item -Path $script:LogFile -NewName "$script:LogFile.old" -Force
        }

        Add-Content -Path $script:LogFile -Value $LogEntry -ErrorAction Stop
    } catch {
        # Fallback bei Fehler beim Schreiben des Logs
        $FallbackLog = "$env:TEMP\easyPASSWORDRESET_fallback.log"
        try {
            $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $LogEntry = "$Timestamp - FALLBACK: [$Level] $filteredMessage"
            Add-Content -Path $FallbackLog -Value $LogEntry -ErrorAction SilentlyContinue
        } catch {
            # Stille Verarbeitung des Fallback-Fehlers
        }
    }
}

# Erweiterte Version von Write-Debug
function Write-DebugLog {
    param (
        [string]$Message
    )
    try {
        Write-Debug $Message
        Write-Log "DEBUG: $Message" -Level "Debug"
    } catch {
        # Fehler still behandeln
    }
}

# Erweiterte Debug-Funktion, die vom Debug-Flag abhängig ist
function Write-DebugMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Component = "General",
        [ValidateSet("Info", "Warning", "Error", "Critical", "Debug")]
        [string]$Level = "Info",
        [string]$FunctionName = $null,
        [int]$LineNumber = 0,
        [switch]$ToFile = $false
    )

    # Direkter Zugriff auf Debug ohne try/catch, damit Fehler sichtbar werden
    # Sicherstellen, dass Debug immer einen Wert hat (Standardwert 1)
    if ($null -eq $script:Config -or $null -eq $script:Config.Debug) {
        # Debug ist nicht definiert, setze Standardwert
        $debugEnabled = 1
        Write-Host "DEBUG-CONFIG nicht gefunden - DEBUG wird erzwungen!" -ForegroundColor Red
    } else {
        $debugEnabled = $script:Config.Debug
    }

    # Immer ausführen, unabhängig vom Debug-Flag - bei Problemen als Fallback
    # Wenn FunctionName nicht angegeben wurde, versuche den aktuellen Funktionsnamen zu ermitteln
    if ([string]::IsNullOrEmpty($FunctionName)) {
        $callStack = Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 1
        if ($null -ne $callStack) {
            $FunctionName = $callStack.Command
            if ($LineNumber -eq 0) {
                $LineNumber = $callStack.ScriptLineNumber
            }
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $debugMessage = "[$timestamp] [DEBUG] [$Component] "

    # Funktions- und Zeilennummer hinzufügen, wenn verfügbar
    if (-not [string]::IsNullOrEmpty($FunctionName)) {
        $debugMessage += "[$FunctionName"
        if ($LineNumber -gt 0) {
            $debugMessage += ":$LineNumber"
        }
        $debugMessage += "] "
    }

    $debugMessage += "[$Level] $Message"

    # Zeichenfilterung für sichere Ausgabe
    $filteredMessage = [regex]::Replace($debugMessage, '[^\x20-\x7E]', '')

    # In die Konsole schreiben mit unterschiedlichen Farben je nach Level
    $foregroundColor = switch ($Level) {
        "Info" { "Cyan" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Critical" { "Magenta" }
        "Debug" { "Green" }
        default { "White" }
    }

    # DIREKTE AUSGABE
    # 1. Write-Host - immer ausführen!
    Write-Information -MessageData $filteredMessage -InformationAction Continue

    # 2. Auch in den Temp-Log schreiben
    $filteredMessage | Out-File -FilePath $script:TempLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue

    # 3. In das reguläre Log schreiben, falls existiert
    if ($null -ne $script:LogFile -and (Test-Path -Path (Split-Path -Path $script:LogFile -Parent))) {
        try {
            $filteredMessage | Out-File -FilePath $script:LogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
        } catch {
            # Fehler beim Loggen ignorieren
        }
    }

    # 4. In separate Debug-Datei schreiben
    if ($ToFile -or $script:Config.VerboseDebug) {
        try {
            $debugLogFile = Join-Path -Path $script:CurrentDir -ChildPath "easyPASSWORDRESET_debug.log"
            $filteredMessage | Out-File -FilePath $debugLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
        } catch {
            # Fallback zur temporären Datei
            $tempDebugLog = "$env:TEMP\easyPASSWORD_debug_file.log"
            "$(Get-Date) - $filteredMessage" | Out-File -FilePath $tempDebugLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }

    # 5. Wenn zusätzliches verbose Debugging aktiviert ist, mehr Details ausgeben
    if ($script:Config.VerboseDebug) {
        try {
            $callStack = Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 3
            $callerInfo = "Call Stack:"
            foreach ($call in $callStack) {
                $callerInfo += "`n  → $($call.Command) at line $($call.ScriptLineNumber) in $($call.ScriptName)"
            }
            Write-Host $callerInfo -ForegroundColor DarkGray

            # Bei kritischen Fehlern auch Stack Trace ausgeben
            if ($Level -eq "Critical" -or $Level -eq "Error") {
                try {
                    # Aktuelle Variablen im Kontext ausgeben (nur wenn kritisch)
                    $contextVars = Get-Variable -Scope 1 | Where-Object {
                        -not [string]::IsNullOrEmpty($_.Name) -and
                        $_.Name -notmatch '^(\?|\^|_|PSItem|args|true|false|null)$' -and
                        -not ($_.Value -is [ScriptBlock])
                    } | ForEach-Object { "$($_.Name) = $(if ($null -eq $_.Value) { 'null' } else { $_.Value.ToString() })" }

                    if ($contextVars.Count -gt 0) {
                        Write-Host "Context Variables:" -ForegroundColor DarkGray
                        $contextVars | ForEach-Object { Write-Information -MessageData "  → $_" -InformationAction Continue }
                    }
                } catch {
                    Write-Host "Fehler beim Ausgeben der Kontextvariablen: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "Fehler beim Ausgeben des Call Stacks: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Absoluter Fallback bei Fehlern
    try {
        # Standard PowerShell Debug-Ausgabe falls gewünscht
        if ($Level -eq "Debug") {
            Write-Debug $filteredMessage
        }
    } catch {
        # Fehler beim Debug-Output ignorieren
        [Console]::WriteLine("[FALLBACK] $Message")
    }
}

# Funktion zum späteren Logging definieren (wird früh benötigt, um Startup-Fehler zu erfassen)
function Write-TemporaryLog {
    param (
        [string]$Message,
        [string]$Level = "Info"
    )
    try {
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $LogEntry = "$Timestamp - [$Level] $Message"
        $TempLogFile = "$env:TEMP\easyPASSWORDRESET_startup.log"
        Add-Content -Path $TempLogFile -Value $LogEntry -ErrorAction SilentlyContinue
    } catch {
        Write-Debug "Failed to write the temporary startup log: $($_.Exception.Message)"
    }
}

# Lade benötigte Assemblies vor der Konfiguration, um Startfehler zu vermeiden
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    Write-TemporaryLog "WPF-Assemblies erfolgreich geladen"
} catch {
    Write-Error "Fehler beim Laden der WPF-Assemblies: $($_)"
    Write-TemporaryLog "Fehler beim Laden der WPF-Assemblies: $($_)" -Level "Error"
    exit
}

# Kritischen Pfad mit absoluter Pfadangabe sichern
$script:CurrentDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:CurrentDir)) {
    $script:CurrentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($script:CurrentDir)) {
        $script:CurrentDir = $PWD.Path
    }
}

# Skriptname aus dem Aufruf extrahieren
$scriptName = $MyInvocation.MyCommand.Name
if ([string]::IsNullOrWhiteSpace($scriptName)) {
    $scriptName = "easyADPW_V0.0.1.ps1"
}

# Stelle sicher, dass die benötigten Ordner existieren
if (-not (Test-Path -Path $script:ReportFolder)) {
    try {
        New-Item -Path $script:ReportFolder -ItemType Directory -Force | Out-Null
    } catch {
        Write-Error "Fehler beim Erstellen des Report-Ordners: $($_)"
        # Fallback zum Skriptordner
        $script:ReportFolder = $script:CurrentDir
    }
}

# XAML-Inhalt wird direkt im Skript als Here-String definiert.
# Dieser Block kann durch die finale XAML-Struktur ersetzt werden.
$script:XamlContent = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="easyPASSWORDRESET" Height="950" Width="1250"
    WindowStartupLocation="CenterScreen"
    Background="#F0F0F0" ResizeMode="CanMinimize">

    <Window.Resources>
        <!-- Button Style -->
        <Style x:Key="ButtonStyle" TargetType="Button">
            <Setter Property="Height" Value="30" />
            <Setter Property="Width" Value="150" />
            <Setter Property="Margin" Value="5" />
            <Setter Property="Background" Value="{Binding ThemeColor}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="#0078D7"
                                BorderThickness="1"
                                CornerRadius="3">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#005A9E" />
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="#003C6A" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- TextBox Style -->
        <Style x:Key="TextBoxStyle" TargetType="TextBox">
            <Setter Property="Height" Value="25" />
            <Setter Property="Margin" Value="5" />
            <Setter Property="Padding" Value="5,2" />
            <Setter Property="BorderBrush" Value="#CCCCCC" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <!-- Required TextBox Style -->
        <Style x:Key="RequiredTextBoxStyle" TargetType="TextBox" BasedOn="{StaticResource TextBoxStyle}">
            <Style.Triggers>
                <Trigger Property="Text" Value="">
                    <Setter Property="BorderBrush" Value="Red" />
                    <Setter Property="ToolTip" Value="Dieses Feld ist erforderlich." />
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- ComboBox Style -->
        <Style x:Key="ComboBoxStyle" TargetType="ComboBox">
            <Setter Property="Height" Value="25" />
            <Setter Property="Margin" Value="5" />
            <Setter Property="Padding" Value="5,2" />
            <Setter Property="BorderBrush" Value="#CCCCCC" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <!-- GroupBox Style -->
        <Style x:Key="GroupBoxStyle" TargetType="GroupBox">
            <Setter Property="Margin" Value="5" />
            <Setter Property="BorderBrush" Value="#0078D7" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="5" />
            <Setter Property="HeaderTemplate">
                <Setter.Value>
                    <DataTemplate>
                        <TextBlock Text="{Binding}" Foreground="#0078D7" FontWeight="Bold" />
                    </DataTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Nav Button Style -->
        <Style x:Key="NavButtonStyle" TargetType="Button">
            <Setter Property="Height" Value="40" />
            <Setter Property="Width" Value="200" />
            <Setter Property="Margin" Value="5,2" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Foreground" Value="#333333" />
            <Setter Property="HorizontalContentAlignment" Value="Left" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="Transparent"
                                BorderThickness="0"
                                CornerRadius="0">
                            <ContentPresenter Margin="10,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#E5F1FB" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#CCE4F7" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="75" />
            <!-- Header -->
            <RowDefinition Height="*" />
            <!-- Content -->
            <RowDefinition Height="60" />
            <!-- Footer -->
        </Grid.RowDefinitions>

        <!-- Header -->
        <Rectangle x:Name="HeaderBackground" Fill="#0078D7" Grid.Row="0"/>
        <TextBlock x:Name="HeaderAppName" Text="easyPwdRESET" Foreground="White" FontSize="24" FontWeight="Bold" VerticalAlignment="Center" HorizontalAlignment="Left" Margin="20,0,0,0"/>

        <!-- Content Area -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Navigation Panel -->

            <!-- Main Content -->
            <TabControl x:Name="mainTabControl" Margin="0,5,5,5" BorderThickness="0" Background="Transparent" Grid.ColumnSpan="2">
                <!-- Tab: Einzelne User -->
                <TabItem Header="Einzelne User" Visibility="Collapsed">
                    <Grid Margin="10">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>

                        <!-- User Search -->
                        <GroupBox Grid.Row="0" Header="Benutzer auswählen" Padding="10" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBox x:Name="txtUsername" Grid.Column="0" Height="30" Margin="0,0,10,0" VerticalContentAlignment="Center"/>
                                <Button x:Name="btnSearchUser" Grid.Column="1" Content="Suchen" Width="100" Height="30"/>
                            </Grid>
                        </GroupBox>

                        <!-- User Info -->
                        <GroupBox Grid.Row="1" Header="Benutzerinformationen" Padding="10" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <TextBlock Grid.Row="0" Grid.Column="0" Text="Name:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserDisplayName" Grid.Row="0" Grid.Column="1" IsReadOnly="True" Height="30" Margin="0,0,20,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="0" Grid.Column="2" Text="E-Mail:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserEmail" Grid.Row="0" Grid.Column="3" IsReadOnly="True" Height="30" Margin="0,0,0,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="1" Grid.Column="0" Text="SamAccountName:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtSamAccountName" Grid.Row="1" Grid.Column="1" IsReadOnly="True" Height="30" Margin="0,0,20,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="1" Grid.Column="2" Text="Beschreibung:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserDescription" Grid.Row="1" Grid.Column="3" IsReadOnly="True" Height="30" Margin="0,0,0,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="2" Grid.Column="0" Text="Abteilung:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserDepartment" Grid.Row="2" Grid.Column="1" IsReadOnly="True" Height="30" Margin="0,0,20,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="2" Grid.Column="2" Text="Status:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserStatus" Grid.Row="2" Grid.Column="3" IsReadOnly="True" Height="30" Margin="0,0,0,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="3" Grid.Column="0" Text="Letzter Login:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserLastLogon" Grid.Row="3" Grid.Column="1" IsReadOnly="True" Height="30" Margin="0,0,20,5" VerticalContentAlignment="Center"/>

                                <TextBlock Grid.Row="3" Grid.Column="2" Text="Passwort läuft ab:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtUserPwdExpiry" Grid.Row="3" Grid.Column="3" IsReadOnly="True" Height="30" Margin="0,0,0,5" VerticalContentAlignment="Center"/>
                            </Grid>
                        </GroupBox>

                        <!-- Password Actions -->
                        <GroupBox Grid.Row="2" Header="Aktionen" Padding="10" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <!-- Password Reset Section -->
                                <GroupBox Grid.Row="0" Grid.Column="0" Header="Passwort zurücksetzen" Padding="10" Margin="0,0,5,5">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>

                                        <TextBlock Grid.Row="0" Text="Neues Passwort:" Margin="0,0,0,5"/>
                                        <PasswordBox x:Name="txtGeneratedPassword" Grid.Row="1" Height="30" PasswordChar="*" Margin="0,0,0,5"/>
                                        <CheckBox x:Name="chkShowPassword" Grid.Row="2" Content="Passwort anzeigen" Margin="0,0,0,5"/>
                                    </Grid>
                                </GroupBox>

                                <!-- Account Options -->
                                <GroupBox Grid.Row="0" Grid.Column="1" Header="Konto-Optionen" Padding="10" Margin="5,0,0,5">
                                    <StackPanel>
                                        <CheckBox x:Name="chkPasswordNeverExpires" Content="Passwort läuft nie ab" Margin="0,5"/>
                                        <CheckBox x:Name="chkCannotChangePassword" Content="Benutzer kann Passwort nicht ändern" Margin="0,5"/>
                                        <CheckBox x:Name="chkAccountEnabled" Content="Konto ist aktiviert" Margin="0,5"/>
                                        <CheckBox x:Name="chkMustChangePassword" Content="Muss Passwort bei nächster Anmeldung ändern" Margin="0,5"/>
                                    </StackPanel>
                                </GroupBox>

                                <!-- Action Buttons -->
                                <UniformGrid Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Rows="1" Margin="0,10">
                                    <Button x:Name="btnReset" Content="Passwort zurücksetzen" Height="40" Margin="5"/>
                                    <Button x:Name="btnUnlock" Content="Konto entsperren" Height="40" Margin="5"/>
                                    <Button x:Name="btnApplyOptions" Content="Optionen anwenden" Height="40" Margin="5"/>
                                </UniformGrid>
                            </Grid>
                        </GroupBox>

                        <!-- Status Section -->
                        <GroupBox Grid.Row="3" Header="Status" Padding="10" Margin="0,0,0,0">
                            <TextBox x:Name="txtStatus" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
                        </GroupBox>
                    </Grid>
                </TabItem>

                <!-- Tab: OU/Gruppe Auswählen -->
                <TabItem Header="OU/Gruppe Auswählen" Visibility="Collapsed">
                    <Grid Margin="10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- OU Section -->
                        <GroupBox Grid.Row="0" Grid.Column="0" Header="Organisationseinheiten" Padding="10" Margin="0,0,5,0">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <TreeView x:Name="treeViewOUs" Grid.Row="0" Margin="0,0,0,10"/>

                                <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Center">
                                    <Button x:Name="btnResetOU" Content="Passwörter zurücksetzen" Height="30" Width="180" Margin="5"/>
                                    <Button x:Name="btnUnlockOU" Content="Konten entsperren" Height="30" Width="150" Margin="5"/>
                                </StackPanel>
                            </Grid>
                        </GroupBox>

                        <!-- Group Section -->
                        <GroupBox Grid.Row="0" Grid.Column="1" Header="Gruppen" Padding="10" Margin="5,0,0,0">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <ComboBox x:Name="cmbGroups" Grid.Row="0" Height="30" Margin="0,0,0,10"/>

                                <ListBox x:Name="lstGroupMembers" Grid.Row="1" Margin="0,0,0,10"/>

                                <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center">
                                    <Button x:Name="btnResetGroup" Content="Passwörter zurücksetzen" Height="30" Width="180" Margin="5"/>
                                    <Button x:Name="btnUnlockGroup" Content="Konten entsperren" Height="30" Width="150" Margin="5"/>
                                </StackPanel>
                            </Grid>
                        </GroupBox>

                        <!-- Status Section -->
                        <GroupBox Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Header="Status" Padding="10" Margin="0,10,0,0">
                            <TextBox x:Name="txtStatus2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True" Height="100"/>
                        </GroupBox>
                    </Grid>
                </TabItem>

                <!-- Tab: Passwort-Richtlinien -->
                <TabItem Header="Passwort-Richtlinien" Visibility="Collapsed">
                    <Grid Margin="10">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                            <Button x:Name="btnRefreshPolicies" Content="Richtlinien aktualisieren" Height="30" Width="180"/>
                        </StackPanel>

                        <DataGrid x:Name="dgPasswordPolicies" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" Margin="0,0,0,10">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Richtlinie" Binding="{Binding Policy}" Width="*"/>
                                <DataGridTextColumn Header="Wert" Binding="{Binding Value}" Width="*"/>
                                <DataGridTextColumn Header="Empfehlung" Binding="{Binding Recommendation}" Width="*"/>
                            </DataGrid.Columns>
                        </DataGrid>

                        <!-- Status Section -->
                        <GroupBox Grid.Row="2" Header="Status" Padding="10">
                            <TextBox x:Name="txtStatus3" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True" Height="100"/>
                        </GroupBox>
                    </Grid>
                </TabItem>

                <!-- Tab: FGPP-Verwaltung -->
                <TabItem Header="FGPP-Verwaltung" Visibility="Collapsed">
                    <Grid Margin="10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- FGPP List -->
                        <GroupBox Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Header="FGPP-Richtlinien" Padding="10" Margin="0,0,0,10">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>

                                <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                    <Button x:Name="btnRefreshFGPP" Content="Aktualisieren" Height="30" Width="100" Margin="0,0,10,0"/>
                                    <Button x:Name="btnEditFGPP" Content="Bearbeiten" Height="30" Width="100" Margin="0,0,10,0"/>
                                    <Button x:Name="btnDeleteFGPP" Content="Löschen" Height="30" Width="100" Margin="0,0,10,0"/>
                                </StackPanel>

                                <DataGrid x:Name="dgFGPP" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" Height="150">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="*"/>
                                        <DataGridTextColumn Header="Präzedenz" Binding="{Binding Precedence}" Width="100"/>
                                        <DataGridTextColumn Header="Min. Länge" Binding="{Binding MinPasswordLength}" Width="100"/>
                                        <DataGridTextColumn Header="Komplexität" Binding="{Binding ComplexityEnabled}" Width="100"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </Grid>
                        </GroupBox>

                        <!-- FGPP Editor -->
                        <GroupBox x:Name="NewFGPPBox" Grid.Row="1" Grid.Column="0" Header="Neue FGPP erstellen" Padding="10" Margin="0,0,5,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <TextBlock Grid.Row="0" Grid.Column="0" Text="Name:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPName" Grid.Row="0" Grid.Column="1" Height="25" Margin="0,0,0,5"/>

                                <TextBlock Grid.Row="1" Grid.Column="0" Text="Präzedenz:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPPrecedence" Grid.Row="1" Grid.Column="1" Height="25" Margin="0,0,0,5"/>

                                <TextBlock Grid.Row="2" Grid.Column="0" Text="Min. Länge:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPMinLength" Grid.Row="2" Grid.Column="1" Height="25" Margin="0,0,0,5"/>

                                <TextBlock Grid.Row="3" Grid.Column="0" Text="Passwort-Historie:" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPHistory" Grid.Row="3" Grid.Column="1" Height="25" Margin="0,0,0,5"/>

                                <TextBlock Grid.Row="4" Grid.Column="0" Text="Min. Alter (Tage):" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPMinAge" Grid.Row="4" Grid.Column="1" Height="25" Margin="0,0,0,5"/>

                                <TextBlock Grid.Row="5" Grid.Column="0" Text="Max. Alter (Tage):" Margin="0,0,10,5" VerticalAlignment="Center"/>
                                <TextBox x:Name="txtFGPPMaxAge" Grid.Row="5" Grid.Column="1" Height="25" Margin="0,0,0,5"/>

                                <CheckBox x:Name="chkFGPPComplexity" Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="2" Content="Komplexität" Margin="0,5"/>
                                <CheckBox x:Name="chkFGPPReversibleEncryption" Grid.Row="7" Grid.Column="0" Grid.ColumnSpan="2" Content="Reversible Verschlüsselung" Margin="0,5"/>

                                <StackPanel Grid.Row="8" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0">
                                    <Button x:Name="btnCreateFGPP" Content="Erstellen" Height="30" Width="100" Margin="5"/>
                                    <Button x:Name="btnSaveFGPP" Content="Speichern" Height="30" Width="100" Margin="5" Visibility="Collapsed"/>
                                    <Button x:Name="btnCancelFGPP" Content="Abbrechen" Height="30" Width="100" Margin="5"/>
                                </StackPanel>
                            </Grid>
                        </GroupBox>

                        <!-- FGPP Group Management -->
                        <GroupBox Grid.Row="1" Grid.Column="1" Header="Angewandte Gruppen" Padding="10" Margin="5,0,0,0">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <TextBlock Grid.Row="0" Text="Verfügbare Gruppen:" Margin="0,0,0,5"/>
                                <ComboBox x:Name="cmbFGPPGroups" Grid.Row="1" Height="25" Margin="0,0,0,10"/>

                                <ListBox x:Name="lstFGPPAppliedGroups" Grid.Row="2" Margin="0,0,0,10"/>

                                <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Center">
                                    <Button x:Name="btnAddGroup" Content="Hinzufügen" Height="30" Width="100" Margin="5"/>
                                    <Button x:Name="btnRemoveGroup" Content="Entfernen" Height="30" Width="100" Margin="5"/>
                                </StackPanel>
                            </Grid>
                        </GroupBox>

                        <!-- Status Section -->
                        <GroupBox Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2" Header="Status" Padding="10" Margin="0,10,0,0">
                            <TextBox x:Name="txtStatus4" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True" Height="100"/>
                        </GroupBox>
                    </Grid>
                </TabItem>
            </TabControl>
        </Grid>

        <!-- Footer -->
        <Rectangle Fill="#0078D7" Grid.Row="2"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
            <TextBlock x:Name="FooterText" Text="© 2025 PhinIT easyPwdReset" Foreground="White" Margin="0,0,20,0"/>
            <TextBlock x:Name="FooterWebsite" Text="www.phinit.de" Foreground="White" Cursor="Hand" TextDecorations="Underline"/>
        </StackPanel>
    </Grid>
</Window>
'@

# Funktion zur Aktualisierung der Statusleiste mit Fehlerbehandlung
function Update-Status {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$StatusType = "Info"
    )

    try {
        # Logge die Nachricht immer, unabhängig von der GUI
        Write-Log -Message $Message -Level $StatusType

        # Prüfe, ob das Fenster-Objekt und sein Dispatcher existieren
        if ($null -eq $script:Window -or $null -eq $script:Window.Dispatcher) {
            # Fallback zur Konsole, wenn keine GUI vorhanden ist
            $color = switch ($StatusType) {
                "Success" { "Green" }
                "Warning" { "Yellow" }
                "Error" { "Red" }
                default { "Cyan" }
            }
            Write-Host "STATUS [$StatusType]: $Message" -ForegroundColor $color
            return
        }

        # UI-Aktualisierungen müssen auf dem UI-Thread ausgeführt werden
        $script:Window.Dispatcher.Invoke([Action] {
                try {
                    # Bestimme die richtige Status-TextBox basierend auf dem aktiven Tab
                    $activeStatusBox = $null
                    if ($null -ne $script:mainTabControl -and $script:mainTabControl.SelectedIndex -ge 0) {
                        $selectedIndex = $script:mainTabControl.SelectedIndex
                        # Tabs sind 0-basiert. txtStatus ist für Tab 0, txtStatus2 für Tab 1, etc.
                        $statusBoxName = if ($selectedIndex -eq 0) { "txtStatus" } else { "txtStatus$($selectedIndex + 1)" }
                        $activeStatusBox = $script:Window.FindName($statusBoxName)
                    }

                    # Fallback auf die erste Statusbox, wenn keine spezifische gefunden wird oder kein TabControl existiert
                    if ($null -eq $activeStatusBox) {
                        $activeStatusBox = $script:Window.FindName("txtStatus")
                    }

                    if ($null -ne $activeStatusBox) {
                        # Setze die Farbe basierend auf dem Statustyp
                        $color = switch ($StatusType) {
                            "Success" { "#2ECC71" } # Grün
                            "Warning" { "#F39C12" } # Orange
                            "Error" { "#E74C3C" } # Rot
                            default { "#3498DB" } # Blau
                        }
                        $brush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($color))

                        # Aktualisiere Text und Farbe
                        $activeStatusBox.Foreground = $brush
                        $activeStatusBox.Text = "$(Get-Date -Format 'HH:mm:ss') - $Message"

                        # Scrolle zum Ende der TextBox, um die neueste Nachricht anzuzeigen
                        $activeStatusBox.ScrollToEnd()
                    } else {
                        Write-Log "Keine aktive Status-TextBox gefunden." "Warning"
                    }
                } catch {
                    # Fehler innerhalb des Dispatcher-Aufrufs protokollieren
                    Write-Log "Fehler beim Aktualisieren der GUI-Statusleiste: $($_)" "Error"
                }
            })
    } catch {
        # Allgemeiner Fehler in der Update-Status Funktion
        Write-Log "Allgemeiner Fehler in der Update-Status Funktion: $($_)" "Error"
    }
}

# Funktion zur Anzeige eines Auswahlfensters, wenn mehrere Benutzer gefunden werden
function Show-UserSelectionDialog {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Users
    )

    try {
        Add-Type -AssemblyName PresentationFramework

        # XAML für das Auswahlfenster
        $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Benutzer auswählen" Height="400" Width="600"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="Mehrere Benutzer gefunden. Bitte wählen Sie den gewünschten Benutzer aus:" Margin="0,0,0,10" FontWeight="Bold"/>

        <DataGrid x:Name="UserGrid" Grid.Row="1" ItemsSource="{Binding}" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Anzeigename" Binding="{Binding DisplayName}" Width="*"/>
                <DataGridTextColumn Header="Benutzername" Binding="{Binding SamAccountName}" Width="*"/>
                <DataGridTextColumn Header="DN" Binding="{Binding DistinguishedName}" Width="2*"/>
            </DataGrid.Columns>
        </DataGrid>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="SelectButton" Content="Auswählen" Width="100" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button x:Name="CancelButton" Content="Abbrechen" Width="100" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

        $reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)

        $userGrid = $dialog.FindName("UserGrid")
        $selectButton = $dialog.FindName("SelectButton")
        $cancelButton = $dialog.FindName("CancelButton")

        # Daten an das DataGrid binden
        $userGrid.ItemsSource = $Users

        # Event-Handler für die Buttons
        $selectButton.Add_Click({
                if ($userGrid.SelectedItem -ne $null) {
                    $dialog.Tag = $userGrid.SelectedItem
                    $dialog.DialogResult = $true
                    $dialog.Close()
                } else {
                    [System.Windows.MessageBox]::Show("Bitte wählen Sie einen Benutzer aus.", "Keine Auswahl", "OK", "Warning")
                }
            })

        $cancelButton.Add_Click({
                $dialog.DialogResult = $false
                $dialog.Close()
            })

        # Dialog anzeigen und auf Ergebnis warten
        if ($dialog.ShowDialog()) {
            return $dialog.Tag
        } else {
            return $null
        }

    } catch {
        Write-GuaranteedDebug -Message "Fehler im Benutzerauswahl-Dialog: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

# Sichere AD-Zugriffsmethoden mit Fallbacks
# Fallback-Methode, wenn reguläre AD-Abfrage fehlschlägt
function Get-ADUserFallback {
    param (
        [string]$Identity,
        [string]$Filter
    )

    try {
        Write-GuaranteedDebug -Message "Führe Fallback AD-Benutzerabfrage aus für: $Identity" -Level "INFO"

        # Versuche ADSI als Fallback
        try {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.PageSize = 1000

            if (-not [string]::IsNullOrEmpty($Identity)) {
                # Annahme: Identity ist entweder SamAccountName oder UPN
                if ($Identity -match "@") {
                    # Wahrscheinlich UPN
                    $searcher.Filter = "(&(objectClass=user)(userPrincipalName=$Identity))"
                } else {
                    # Wahrscheinlich SamAccountName
                    $searcher.Filter = "(&(objectClass=user)(samAccountName=$Identity))"
                }
            } elseif (-not [string]::IsNullOrEmpty($Filter)) {
                # Einfache Konvertierung von PowerShell-Filter zu LDAP-Filter
                $ldapFilter = $Filter -replace "SamAccountName -eq '([^']*)'", "samAccountName=`$1"
                $ldapFilter = $ldapFilter -replace "Enabled -eq (.*)", "userAccountControl:1.2.840.113556.1.4.803:=`$1"
                $searcher.Filter = "(&(objectClass=user)$ldapFilter)"
            } else {
                $searcher.Filter = "(objectClass=user)"
            }

            $searcher.PropertiesToLoad.AddRange(@("samAccountName", "distinguishedName", "displayName", "mail", "department", "title", "manager"))

            $results = $searcher.FindAll()

            if ($results.Count -eq 0) {
                Write-GuaranteedDebug -Message "Keine Benutzer im Fallback gefunden" -Level "WARNING"
                return $null
            }

            # Konvertiere DirectoryEntry zu PSObject für Konsistenz
            $users = @()

            foreach ($result in $results) {
                $user = New-Object PSObject -Property @{
                    SamAccountName    = $result.Properties["samAccountName"][0]
                    DistinguishedName = $result.Properties["distinguishedName"][0]
                    DisplayName       = if ($result.Properties["displayName"].Count -gt 0) { $result.Properties["displayName"][0] } else { "" }
                    EmailAddress      = if ($result.Properties["mail"].Count -gt 0) { $result.Properties["mail"][0] } else { "" }
                    Department        = if ($result.Properties["department"].Count -gt 0) { $result.Properties["department"][0] } else { "" }
                    Title             = if ($result.Properties["title"].Count -gt 0) { $result.Properties["title"][0] } else { "" }
                    Manager           = if ($result.Properties["manager"].Count -gt 0) { $result.Properties["manager"][0] } else { "" }
                }

                $users += $user
            }

            Write-GuaranteedDebug -Message "Fallback-Methode hat $($users.Count) Benutzer gefunden" -Level "INFO"

            # Wenn nur ein einzelner Benutzer gesucht wurde, gebe nur diesen zurück
            if (-not [string]::IsNullOrEmpty($Identity) -and $users.Count -eq 1) {
                return $users[0]
            }

            return $users
        } catch {
            Write-GuaranteedDebug -Message "ADSI-Fallback fehlgeschlagen: $($_.Exception.Message)" -Level "ERROR"

            # Minimaler Fallback: Gib ein Dummy-Benutzerobjekt zurück
            if (-not [string]::IsNullOrEmpty($Identity)) {
                Write-GuaranteedDebug -Message "Erstelle Dummy-Benutzerobjekt für $Identity" -Level "WARNING"

                $dummyUser = New-Object PSObject -Property @{
                    SamAccountName    = $Identity
                    DistinguishedName = "CN=$Identity,DC=fallback,DC=local"
                    DisplayName       = $Identity
                    EmailAddress      = "$Identity@fallback.local"
                    Department        = "Nicht verfügbar"
                    Title             = "Nicht verfügbar"
                    Manager           = $null
                    IsDummyObject     = $true # Markierung für Dummy-Objekt
                }

                return $dummyUser
            }
        }

        return $null
    } catch {
        Write-GuaranteedDebug -Message "Kritischer Fehler bei Fallback-AD-Benutzerabfrage: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

# Verbesserte sichere Get-ADUser Implementierung mit Fallbacks und Auswahlfenster
function Get-ADUserSafe {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Identity,
        [string]$Filter,
        [string[]]$Properties = @("*"),
        [string]$SearchBase,
        [switch]$NoFallback
    )

    try {
        Write-GuaranteedDebug -Message "Führe sichere AD-Benutzerabfrage aus..." -Level "INFO"

        # Überprüfen der AD-Verbindung
        if ($script:ADConnectionStatus -eq "Error" -and -not $NoFallback) {
            Write-GuaranteedDebug -Message "AD-Verbindung nicht verfügbar, verwende Fallback-Methode" -Level "WARNING"
            return Get-ADUserFallback -Identity $Identity -Filter $Filter
        }

        # Parameter für AD-Abfrage vorbereiten
        $adParams = @{
            ErrorAction = "Stop"
            Properties  = $Properties
        }

        # Prioritize Identity over Filter if both are provided
        if (-not [string]::IsNullOrEmpty($Identity)) {
            # Build a robust filter to find the user by various common attributes
            $adParams.Add("Filter", "SamAccountName -eq '$Identity' -or UserPrincipalName -eq '$Identity' -or Name -like '*$Identity*' -or DisplayName -like '*$Identity*'")
        } elseif (-not [string]::IsNullOrEmpty($Filter)) {
            $adParams.Add("Filter", $Filter)
        } else {
            # If neither is provided, this is an invalid call for this function's logic
            throw "Get-ADUserSafe requires either -Identity or -Filter to be specified."
        }


        if (-not [string]::IsNullOrEmpty($SearchBase)) {
            $adParams.Add("SearchBase", $SearchBase)
        }

        # AD-Abfrage ausführen
        $results = $null
        try {
            $results = Get-ADUser @adParams
        } catch {
            # If the query fails, the original error is more relevant
            throw
        }


        if ($null -eq $results) {
            Write-GuaranteedDebug -Message "Keine Benutzer gefunden" -Level "WARNING"
            return $null
        }

        # Prüfen, ob mehrere Benutzer gefunden wurden
        if ($results -is [array] -and $results.Count -gt 1) {
            Write-GuaranteedDebug -Message "Mehrere Benutzer gefunden ($($results.Count)). Zeige Auswahlfenster." -Level "INFO"
            # Auswahlfenster aufrufen und den ausgewählten Benutzer zurückgeben
            return Show-UserSelectionDialog -Users $results
        }

        Write-GuaranteedDebug -Message "Ein einzelner AD-Benutzer wurde erfolgreich gefunden." -Level "INFO"
        return $results
    } catch {
        $errorMsg = "Fehler bei AD-Benutzerabfrage: $($_.Exception.Message)"
        Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"

        if (-not $NoFallback) {
            Write-GuaranteedDebug -Message "Versuche Fallback-Methode für AD-Benutzerabfrage" -Level "INFO"
            return Get-ADUserFallback -Identity $Identity -Filter $Filter
        }

        return $null
    }
}

# Funktion zum Exportieren eines Passwort-Reset-Berichts für einen einzelnen Benutzer
function Export-PasswordResetReport {
    param (
        [string]$Username,
        [System.Security.SecureString]$NewPassword
    )
    try {
        Write-DebugMessage "Starte Export-PasswordResetReport für Benutzer: $Username" -Component "PasswordReporting"

        if ([string]::IsNullOrWhiteSpace($Username)) {
            Write-Log "Benutzername für Berichtserstellung ist leer." -Level "Warning"
            Write-DebugMessage "Benutzername ist leer, Berichterstellung wird abgebrochen" -Component "PasswordReporting" -Level "Warning"
            return $false
        }

        if ($null -eq $NewPassword -or $NewPassword.Length -eq 0) {
            Write-Log "Passwort für Berichtserstellung ist leer." -Level "Warning"
            Write-DebugMessage "Passwort ist leer, setze Standardwert für Bericht" -Component "PasswordReporting" -Level "Warning"
            $plainPassword = "[Passwort nicht verfügbar]"
        } else {
            $passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword)
            try {
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
            }
        }

        Write-Log "Erstelle Bericht für Passwort-Reset von Benutzer $Username." -Level "Info"
        Write-DebugMessage "Bereite Berichterstellung vor" -Component "PasswordReporting"

        # Prüfe, ob ReportFolder existiert und erstelle es ggf.
        if (-not (Test-Path -Path $script:ReportFolder -ErrorAction SilentlyContinue)) {
            try {
                Write-DebugMessage "ReportFolder existiert nicht, erstelle Verzeichnis: $script:ReportFolder" -Component "PasswordReporting"
                New-Item -Path $script:ReportFolder -ItemType Directory -Force | Out-Null
            } catch {
                Write-DebugMessage "Fehler beim Erstellen des ReportFolder: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Error"
                $script:ReportFolder = $env:TEMP
                Write-DebugMessage "Verwende Fallback-Verzeichnis: $script:ReportFolder" -Component "PasswordReporting" -Level "Warning"
            }
        }

        # Benutzerinformationen abrufen mit vollständiger Fehlerbehandlung
        $user = $null
        try {
            Write-DebugMessage "Rufe AD-Benutzerinformationen ab für: $Username" -Component "PasswordReporting"
            $user = Get-ADUser -Identity $Username -Properties DisplayName, EmailAddress, SamAccountName, Description, Department, Title, Manager -ErrorAction Stop

            if ($null -eq $user) {
                throw "Get-ADUser gab NULL zurück"
            }

            Write-DebugMessage "AD-Benutzerinformationen erfolgreich abgerufen" -Component "PasswordReporting"
        } catch {
            Write-Log "Fehler beim Abrufen der Benutzerinformationen für $Username`: $($_)" -Level "Error"
            Write-DebugMessage "AD-Fehler: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Error"

            # Erstelle ein minimales Benutzerobjekt als Fallback
            Write-DebugMessage "Erstelle Fallback-Benutzerobjekt" -Component "PasswordReporting"
            $user = [PSCustomObject]@{
                SamAccountName = $Username
                DisplayName    = $Username
                EmailAddress   = "Nicht verfügbar"
                Department     = "Nicht verfügbar"
                Title          = "Nicht verfügbar"
                Manager        = $null
            }
        }

        # Berichte-Ordner und Dateinamen vorbereiten
        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $reportFile = Join-Path -Path $script:ReportFolder -ChildPath "User_PasswordReset_${Username}_$reportTime.html"
        $txtReportFile = Join-Path -Path $script:ReportFolder -ChildPath "User_PasswordReset_${Username}_$reportTime.txt"

        Write-DebugMessage "Berichtsdateien definiert: HTML=$reportFile, TXT=$txtReportFile" -Component "PasswordReporting"

        # Manager-Informationen abrufen (falls vorhanden)
        $managerInfo = "Nicht angegeben"
        if ($null -ne $user.Manager) {
            try {
                Write-DebugMessage "Rufe Manager-Informationen ab für: $($user.Manager)" -Component "PasswordReporting"
                $manager = Get-ADUser -Identity $user.Manager -Properties DisplayName -ErrorAction Stop
                if ($null -ne $manager -and -not [string]::IsNullOrWhiteSpace($manager.DisplayName)) {
                    $managerInfo = $manager.DisplayName
                    Write-DebugMessage "Manager gefunden: $managerInfo" -Component "PasswordReporting"
                }
            } catch {
                Write-Log "Fehler beim Abrufen des Managers für $Username`: $($_)" -Level "Warning"
                Write-DebugMessage "Fehler bei Manager-Abfrage: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Warning"
            }
        } else {
            Write-DebugMessage "Kein Manager für Benutzer definiert" -Component "PasswordReporting"
        }

        # Sicherstellen, dass alle Eigenschaften einen Wert haben (NULL-Schutz)
        $displayName = if ([string]::IsNullOrWhiteSpace($user.DisplayName)) { $Username } else { $user.DisplayName }
        $emailAddress = if ([string]::IsNullOrWhiteSpace($user.EmailAddress)) { "Nicht angegeben" } else { $user.EmailAddress }
        $department = if ([string]::IsNullOrWhiteSpace($user.Department)) { "Nicht angegeben" } else { $user.Department }
        $title = if ([string]::IsNullOrWhiteSpace($user.Title)) { "Nicht angegeben" } else { $user.Title }

        Write-DebugMessage "Benutzerdetails für Bericht vorbereitet" -Component "PasswordReporting"

        # HTML-Report erstellen
        $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Passwort-Reset Bericht - $Username</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0078D7; color: white; }
        h1, h2 { color: #0078D7; }
        .password { font-family: monospace; font-weight: bold; color: #d70000; }
        .info { background-color: #f0f7ff; padding: 15px; border-left: 5px solid #0078D7; margin: 10px 0; }
    </style>
</head>
<body>
    <h1>Passwort-Reset Bericht</h1>
    <p><b>Datum und Zeit:</b> $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</p>

    <div class="info">
        <p>Passwörter sind vertrauliche Informationen. Bitte behandeln Sie diesen Bericht entsprechend
        und löschen Sie ihn nach der Änderung des Passworts.</p>
    </div>

    <h2>Benutzerinformationen</h2>
    <table>
        <tr><th>Benutzername</th><td>$($user.SamAccountName)</td></tr>
        <tr><th>Anzeigename</th><td>$displayName</td></tr>
        <tr><th>E-Mail</th><td>$emailAddress</td></tr>
        <tr><th>Abteilung</th><td>$department</td></tr>
        <tr><th>Position</th><td>$title</td></tr>
        <tr><th>Vorgesetzter</th><td>$managerInfo</td></tr>
    </table>

    <h2>Passwort-Reset Details</h2>
    <table>
        <tr><th>Zurückgesetzt von</th><td>$($env:USERNAME)</td></tr>
        <tr><th>Neues Passwort</th><td class="password">$plainPassword</td></tr>
        <tr><th>Reset-Zeitpunkt</th><td>$(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</td></tr>
    </table>

    <p style="margin-top: 30px; font-style: italic;">
        Erstellt mit $($script:AppName) - Version 0.2<br>
        Bericht für interne Dokumentation und Notfallwiederherstellung
    </p>
</body>
</html>
"@

        # TXT-Bericht erstellen
        $txtContent = @"
Passwort-Reset Bericht
======================
Datum und Zeit: $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")

WARNUNG: Passwörter sind vertrauliche Informationen. Bitte behandeln Sie diesen
Bericht entsprechend und löschen Sie ihn zeitnah.

Benutzerinformationen:
---------------------
Benutzername: $($user.SamAccountName)
Anzeigename: $displayName
E-Mail: $emailAddress
Abteilung: $department
Position: $title
Vorgesetzter: $managerInfo

Passwort-Reset Details:
---------------------
Zurückgesetzt von: $($env:USERNAME)
Neues Passwort: $plainPassword
Reset-Zeitpunkt: $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")

Erstellt mit $($script:AppName)
"@

        Write-DebugMessage "HTML- und TXT-Berichte generiert" -Component "PasswordReporting"

        # Berichte speichern
        try {
            Write-DebugMessage "Speichere HTML-Bericht: $reportFile" -Component "PasswordReporting"
            $htmlContent | Out-File -FilePath $reportFile -Encoding utf8 -Force -ErrorAction Stop

            Write-DebugMessage "Speichere TXT-Bericht: $txtReportFile" -Component "PasswordReporting"
            $txtContent | Out-File -FilePath $txtReportFile -Encoding utf8 -Force -ErrorAction Stop

            Write-Log "Passwort-Reset Berichte wurden gespeichert." -Level "Info"
            if ($null -ne $script:Window) {
                Update-Status "Passwort-Reset Bericht wurde gespeichert unter: $reportFile" "Success"
            }

            # Bericht öffnen anbieten
            try {
                Write-DebugMessage "Zeige MessageBox für Berichtsöffnung an" -Component "PasswordReporting"
                $openReport = [System.Windows.MessageBox]::Show(
                    "Passwort-Reset für Benutzer $Username wurde durchgeführt. Möchten Sie den Bericht jetzt öffnen?",
                    "Passwort-Reset abgeschlossen",
                    "YesNo",
                    "Information"
                )

                if ($openReport -eq "Yes") {
                    try {
                        Write-DebugMessage "Öffne Bericht: $reportFile" -Component "PasswordReporting"
                        Start-Process -FilePath $reportFile -ErrorAction Stop
                        Write-DebugMessage "Bericht wurde geöffnet" -Component "PasswordReporting"
                    } catch {
                        Write-Log "Fehler beim Öffnen des Berichts: $($_)" -Level "Warning"
                        Write-DebugMessage "Fehler beim Öffnen des Berichts: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Error"

                        # Alternative Methode versuchen
                        try {
                            Write-DebugMessage "Versuche alternative Methode zum Öffnen des Berichts" -Component "PasswordReporting"
                            Invoke-Item -Path $reportFile -ErrorAction Stop
                        } catch {
                            Write-DebugMessage "Auch alternative Methode fehlgeschlagen: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Error"
                            if ($null -ne $script:Window) {
                                Update-Status "Fehler beim Öffnen des Berichts: $($_)" "Error"
                            }
                        }
                    }
                } else {
                    Write-DebugMessage "Benutzer hat entschieden, den Bericht nicht zu öffnen" -Component "PasswordReporting"
                }
            } catch {
                Write-Log "Fehler beim Anzeigen der MessageBox: $($_)" -Level "Warning"
                Write-DebugMessage "MessageBox konnte nicht angezeigt werden: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Error"
            }

            Write-DebugMessage "Berichterstellung erfolgreich abgeschlossen" -Component "PasswordReporting"
            return $true
        } catch {
            Write-Log "Fehler beim Speichern des Berichts: $($_)" -Level "Error"
            Write-DebugMessage "Fehler beim Speichern der Berichte: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Error"

            if ($null -ne $script:Window) {
                Update-Status "Fehler beim Speichern des Berichts: $($_)" "Error"
            }

            # Versuche Fallback in das Temp-Verzeichnis
            try {
                Write-DebugMessage "Versuche Fallback-Speicherung in Temp-Verzeichnis" -Component "PasswordReporting"
                $fallbackFile = Join-Path -Path $env:TEMP -ChildPath "PasswordReset_${Username}_$reportTime.txt"
                $txtContent | Out-File -FilePath $fallbackFile -Encoding utf8 -Force -ErrorAction Stop
                Write-Log "Fallback-Bericht wurde im Temp-Verzeichnis gespeichert: $fallbackFile" -Level "Warning"
                Write-DebugMessage "Fallback-Bericht erstellt: $fallbackFile" -Component "PasswordReporting" -Level "Warning"
            } catch {
                Write-Log "Auch Fallback-Speicherung fehlgeschlagen: $($_)" -Level "Error"
                Write-DebugMessage "Auch Fallback-Speicherung fehlgeschlagen: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Critical"
            }

            return $false
        }
    } catch {
        $errorMsg = "Kritischer Fehler beim Erstellen des Passwort-Reset Berichts für $Username`: $($_)"
        Write-Log $errorMsg -Level "Error"
        Write-DebugMessage "Kritischer Fehler in Export-PasswordResetReport: $($_.Exception.Message)" -Component "PasswordReporting" -Level "Critical"

        if ($null -ne $script:Window) {
            Update-Status $errorMsg "Error"
        }

        return $false
    }
}

# Passwort zurücksetzen
function Reset-Password {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [switch]$ExportReport
    )

    try {
        Write-DebugMessage "Führe Passwort-Reset für $Username durch" -Component "PasswordReset"

        if ([string]::IsNullOrWhiteSpace($Username)) {
            Update-Status "Benutzername ist leer." "Warning"
            return
        }

        # Benutzer prüfen und Passwort generieren
        try {
            Write-DebugMessage "Prüfe ob Benutzer $Username existiert..." -Component "PasswordReset"

            # Verwende sichere Benutzerabfrage mit Fallback bei AD-Problemen
            $user = Get-ADUserSafe -Filter "SamAccountName -eq '$Username'" -Properties DisplayName, SamAccountName, Description, LockedOut, PasswordExpired, PasswordLastSet, PasswordNeverExpires, LastLogonDate, pwdLastSet, Enabled

            if ($null -eq $user) {
                throw "Benutzer $Username wurde nicht gefunden."
            }

            Write-DebugMessage "Benutzer gefunden: $($user.DistinguishedName)" -Component "PasswordReset"

            # Passwort generieren mit Fallback bei Fehler
            try {
                $NewPassword = GenerateSecurePassword
                Write-DebugMessage "Neues Passwort generiert" -Component "PasswordReset"
            } catch {
                Write-DebugMessage "Fehler beim Generieren des Passworts, verwende Standard-Passwort" -Component "PasswordReset" -Level "Warning"
                $NewPassword = "Passw0rd!" + (Get-Random -Minimum 100 -Maximum 999)
            }

            $SecurePassword = ConvertTo-SecureString -String $NewPassword -AsPlainText -Force

            # Benutzerinformationen in der GUI aktualisieren - mit try/catch für jedes Element
            try {
                # Display Name aktualisieren
                if ($null -ne (Get-Variable -Name "txtUserDisplayName" -Scope Script -ErrorAction SilentlyContinue)) {
                    if ($null -ne $txtUserDisplayName) {
                        $txtUserDisplayName.Text = $user.DisplayName
                        Write-DebugMessage "DisplayName in der GUI aktualisiert: $($user.DisplayName)" -Component "PasswordReset"
                    }
                }

                # Sperrstatus aktualisieren
                if ($null -ne (Get-Variable -Name "txtUserLockedStatus" -Scope Script -ErrorAction SilentlyContinue)) {
                    if ($null -ne $txtUserLockedStatus) {
                        $txtUserLockedStatus.Text = if ($user.LockedOut) { "Gesperrt" } else { "Nicht gesperrt" }
                        Write-DebugMessage "Sperrstatus in der GUI aktualisiert: $($user.LockedOut)" -Component "PasswordReset"
                    }
                }

                # Letzte Anmeldung aktualisieren
                if ($null -ne (Get-Variable -Name "txtUserLastLogon" -Scope Script -ErrorAction SilentlyContinue)) {
                    if ($null -ne $txtUserLastLogon) {
                        if ($null -ne $user.LastLogonDate) {
                            $txtUserLastLogon.Text = $user.LastLogonDate.ToString("dd.MM.yyyy HH:mm:ss")
                            Write-DebugMessage "Letzte Anmeldung in der GUI aktualisiert: $($user.LastLogonDate)" -Component "PasswordReset"
                        } else {
                            $txtUserLastLogon.Text = "Nie"
                            Write-DebugMessage "Benutzer hat sich noch nie angemeldet" -Component "PasswordReset"
                        }
                    }
                }

                # Passwort-Ablaufdatum aktualisieren
                if ($null -ne (Get-Variable -Name "txtUserPwdExpiry" -Scope Script -ErrorAction SilentlyContinue)) {
                    if ($null -ne $txtUserPwdExpiry) {
                        if ($user.PasswordNeverExpires) {
                            $txtUserPwdExpiry.Text = "Nie (Passwort läuft nie ab)"
                            Write-DebugMessage "Passwort läuft nie ab (PasswordNeverExpires = $($user.PasswordNeverExpires))" -Component "PasswordReset"
                        } elseif ($user.PasswordExpired) {
                            $txtUserPwdExpiry.Text = "Abgelaufen"
                            Write-DebugMessage "Passwort ist bereits abgelaufen" -Component "PasswordReset"
                        } else {
                            try {
                                # Prüfe ob pwdLastSet verfügbar ist
                                if ($null -ne $user.pwdLastSet -and $user.pwdLastSet -gt 0) {
                                    $pwdLastSet = [DateTime]::FromFileTime($user.pwdLastSet)

                                    # Sicherer Abruf der Domänen-Passwortrichtlinie mit Fallback
                                    try {
                                        $domainPolicy = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
                                        $maxPwdAge = $domainPolicy.MaxPasswordAge
                                    } catch {
                                        Write-DebugMessage "Fehler beim Abrufen der Domänenrichtlinie: $($_.Exception.Message)" -Component "PasswordReset" -Level "Warning"
                                        # Standardwert von 42 Tagen als Fallback
                                        $maxPwdAge = New-TimeSpan -Days 42
                                    }

                                    $pwdExpiry = $pwdLastSet.Add($maxPwdAge)
                                    $txtUserPwdExpiry.Text = $pwdExpiry.ToString("dd.MM.yyyy HH:mm:ss")
                                    Write-DebugMessage "Passwort läuft ab am: $($pwdExpiry.ToString('dd.MM.yyyy HH:mm:ss'))" -Component "PasswordReset"
                                } else {
                                    $txtUserPwdExpiry.Text = "Unbekannt (pwdLastSet nicht verfügbar)"
                                    Write-DebugMessage "pwdLastSet nicht verfügbar" -Component "PasswordReset" -Level "Warning"
                                }
                            } catch {
                                $txtUserPwdExpiry.Text = "Unbekannt (Berechnungsfehler)"
                                Write-DebugMessage "Fehler beim Berechnen des Passwort-Ablaufdatums: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
                                Write-Log "Fehler beim Berechnen des Passwort-Ablaufdatums: $($_)"
                            }
                        }
                    }
                }

                # Passwort-Checkboxen aktualisieren
                if ($null -ne (Get-Variable -Name "chkPasswordNeverExpires" -Scope Script -ErrorAction SilentlyContinue)) {
                    if ($null -ne $chkPasswordNeverExpires) {
                        $chkPasswordNeverExpires.IsChecked = $user.PasswordNeverExpires
                    }
                }

                if ($null -ne (Get-Variable -Name "chkAccountEnabled" -Scope Script -ErrorAction SilentlyContinue)) {
                    if ($null -ne $chkAccountEnabled) {
                        $chkAccountEnabled.IsChecked = $user.Enabled
                    }
                }

                Write-DebugMessage "Benutzerdetails wurden in der GUI aktualisiert" -Component "PasswordReset"
            } catch {
                Write-DebugMessage "Fehler beim Aktualisieren der GUI-Elemente: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
                Write-Log "Fehler beim Aktualisieren der Benutzerinformationen in der GUI: $($_)"
            }

            # Passwort zurücksetzen - mit Retry-Mechanismus
            $maxRetries = 2
            $retryCount = 0
            $success = $false

            while (-not $success -and $retryCount -le $maxRetries) {
                try {
                    Write-DebugMessage "Setze Passwort für $Username zurück... (Versuch $($retryCount + 1))" -Component "PasswordReset"
                    Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset -ErrorAction Stop
                    $success = $true
                    Write-DebugMessage "Passwort erfolgreich zurückgesetzt" -Component "PasswordReset"
                } catch {
                    $retryCount++
                    if ($retryCount -le $maxRetries) {
                        Write-DebugMessage "Fehler beim Zurücksetzen des Passworts, versuche erneut ($retryCount/$maxRetries): $($_.Exception.Message)" -Component "PasswordReset" -Level "Warning"
                        Start-Sleep -Milliseconds 500
                    } else {
                        throw
                    }
                }
            }

            # Generiertes Passwort anzeigen mit Fehlerbehandlung
            if ($null -ne (Get-Variable -Name "txtGeneratedPassword" -Scope Script -ErrorAction SilentlyContinue)) {
                try {
                    if ($null -ne $txtGeneratedPassword) {
                        # PasswordBox hat die Eigenschaft 'Password', nicht 'Text'
                        $txtGeneratedPassword.Password = $NewPassword
                        Write-DebugMessage "Generiertes Passwort in der GUI angezeigt" -Component "PasswordReset"
                    } else {
                        Write-DebugMessage "txtGeneratedPassword ist NULL" -Component "PasswordReset" -Level "Warning"
                    }
                } catch {
                    Write-DebugMessage "Fehler beim Anzeigen des generierten Passworts in der GUI: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
                    Write-Log "Fehler beim Anzeigen des generierten Passworts: $($_)"
                }
            }

            # Statusupdate - verwende Update-Status mit Fehlerbehandlung
            try {
                Update-Status "Passwort für Benutzer $Username wurde zurückgesetzt." "Success"
                Write-DebugMessage "Passwort-Reset für $Username erfolgreich abgeschlossen" -Component "PasswordReset" -Level "Info"
            } catch {
                Write-DebugMessage "Fehler beim Aktualisieren des Status: $($_.Exception.Message)" -Component "PasswordReset" -Level "Warning"
            }

            # MessageBox anzeigen mit Fehlerbehandlung
            try {
                if ($null -ne [System.Windows.MessageBox]) {
                    [System.Windows.MessageBox]::Show("Das Passwort für Benutzer $Username wurde zurückgesetzt auf: $NewPassword", "Passwort zurückgesetzt", "OK", "Information")
                    Write-DebugMessage "Erfolgsmeldung wurde angezeigt" -Component "PasswordReset"
                } else {
                    Write-DebugMessage "MessageBox-Klasse ist nicht verfügbar" -Component "PasswordReset" -Level "Warning"
                    # Fallback-Ausgabe
                    Write-Host "`n[ERFOLG] Das Passwort für Benutzer $Username wurde zurückgesetzt auf: $NewPassword`n" -ForegroundColor Green
                }
            } catch {
                Write-DebugMessage "Fehler beim Anzeigen der Erfolgsmeldung: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
                Write-Log "Fehler beim Anzeigen der MessageBox: $($_)"
                # Fallback-Ausgabe
                Write-Host "`n[ERFOLG] Das Passwort für Benutzer $Username wurde zurückgesetzt auf: $NewPassword`n" -ForegroundColor Green
            }

            # Report exportieren, falls gewünscht
            if ($ExportReport) {
                try {
                    Write-DebugMessage "Erstelle Passwort-Reset-Bericht" -Component "PasswordReset"

                    # Prüfe ob Export-PasswordResetReport existiert und funktionsfähig ist
                    if (Get-Command -Name "Export-PasswordResetReport" -ErrorAction SilentlyContinue) {
                        $reportResult = Export-PasswordResetReport -Username $Username -NewPassword $SecurePassword

                        if ($reportResult) {
                            Write-DebugMessage "Bericht wurde erfolgreich erstellt" -Component "PasswordReset"
                        } else {
                            Write-DebugMessage "Fehler beim Erstellen des Berichts" -Component "PasswordReset" -Level "Warning"
                        }
                    } else {
                        # Fallback: Einfache Textdatei erstellen
                        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
                        $reportFile = "$script:ReportFolder\PasswordReset_${Username}_$reportTime.txt"

                        try {
                            # Stellen Sie sicher, dass der Report-Ordner existiert
                            if (-not (Test-Path -Path $script:ReportFolder)) {
                                New-Item -Path $script:ReportFolder -ItemType Directory -Force | Out-Null
                            }

                            # Einfachen Bericht schreiben
                            $reportContent = @"
Passwort-Reset Bericht
======================
Datum und Zeit: $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")
Benutzername: $Username
Zurückgesetzt von: $($env:USERNAME)
Neues Passwort: $NewPassword

WARNUNG: Bitte löschen Sie diesen Bericht nach der Übergabe des Passworts!
"@
                            $reportContent | Out-File -FilePath $reportFile -Encoding utf8 -Force
                            Write-DebugMessage "Einfacher Fallback-Bericht erstellt unter: $reportFile" -Component "PasswordReset"
                        } catch {
                            Write-DebugMessage "Fehler beim Erstellen des Fallback-Berichts: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
                        }
                    }
                } catch {
                    Write-DebugMessage "Ausnahme beim Erstellen des Berichts: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
                    Write-Log "Fehler beim Exportieren des Berichts: $($_)"
                }
            } else {
                Write-DebugMessage "Berichterstellung wurde übersprungen (ExportReport = $ExportReport)" -Component "PasswordReset"
            }

            # Liefere das neue Passwort zurück
            return $NewPassword
        } catch {
            Write-DebugMessage "AD-Fehler beim Zurücksetzen des Passworts: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
            Update-Status "Benutzer $Username wurde nicht gefunden oder ein Fehler ist aufgetreten: $($_)" "Error"
            Write-Log "Fehler bei Get-ADUser für $Username $($_)"

            # Fehler weiterwerfen für übergreifende Fehlerbehandlung
            throw
        }
    } catch {
        $errorMsg = "Fehler beim Zurücksetzen des Passworts: $($_)"
        Write-DebugMessage "Kritischer Fehler: $($_.Exception.Message)" -Component "PasswordReset" -Level "Critical"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"

        try {
            if ($null -ne [System.Windows.MessageBox]) {
                [System.Windows.MessageBox]::Show($errorMsg, "Fehler", "OK", "Error")
            } else {
                # Fallback-Ausgabe
                Write-Host "`n[FEHLER] $errorMsg`n" -ForegroundColor Red
            }
        } catch {
            Write-DebugMessage "Konnte Fehlermeldung nicht anzeigen: $($_.Exception.Message)" -Component "PasswordReset" -Level "Error"
            Write-Log "Fehler beim Anzeigen der MessageBox: $($_)"
            # Letzte Fallback-Ausgabe
            Write-Host "`n[FEHLER] $errorMsg`n" -ForegroundColor Red
        }

        # Fehler zurückgeben
        return $null
    }
}

# Konto entsperren
function Unlock-Account {
    param (
        [string]$Username,
        [string]$Scope
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Username)) {
            Update-Status "Benutzername ist leer." "Warning"
            return
        }

        Write-Log "Konto wird für Benutzer $Username im Bereich $Scope entsperrt."
        Update-Status "Konto wird für Benutzer $Username im Bereich $Scope entsperrt." "Info"

        try {
            switch ($Scope) {
                "Einzelner Benutzer" {
                    # Prüfen ob Benutzer existiert
                    if (Get-ADUser -Filter { SamAccountName -eq $Username } -ErrorAction SilentlyContinue) {
                        Unlock-ADAccount -Identity $Username
                        Update-Status "Konto für Benutzer $Username wurde entsperrt." "Success"

                        try {
                            [System.Windows.MessageBox]::Show("Das Konto für Benutzer $Username wurde entsperrt.", "Konto entsperrt", "OK", "Information")
                        } catch {
                            Write-Log "Fehler beim Anzeigen der MessageBox: $($_)"
                        }
                    } else {
                        Update-Status "Benutzer $Username wurde nicht gefunden." "Error"
                    }
                }
                default {
                    Update-Status "Bereich '$Scope' wird zurzeit nicht unterstützt." "Warning"
                }
            }
        } catch {
            throw
        }
    } catch {
        $errorMsg = "Fehler beim Entsperren des Kontos: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"

        try {
            [System.Windows.MessageBox]::Show($errorMsg, "Fehler", "OK", "Error")
        } catch {
            Write-Log "Fehler beim Anzeigen der MessageBox: $($_)"
        }
    }
}

# Sicheres Passwort generieren mit verbesserter Komplexität
function GenerateSecurePassword {
    param (
        [int]$Length = $script:Config.DefaultPasswordLength,
        [bool]$UseSpecial = $script:Config.UseSpecialChars,
        [bool]$UseNumbers = $script:Config.UseNumbers,
        [bool]$UseUpper = $script:Config.UseUppercase,
        [bool]$UseLower = $script:Config.UseLowercase
    )
    try {
        # Definition der Zeichensätze
        $lowerChars = "abcdefghijklmnopqrstuvwxyz"
        $upperChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        $numberChars = "0123456789"
        $specialChars = "!@#$%^&*()-_=+[]{};:,.<>/?"

        # Falls die Konfiguration kein gültiges Passwort ermöglicht, Fallback auf Default-Einstellungen
        if (-not ($UseSpecial -or $UseNumbers -or $UseUpper -or $UseLower)) {
            Write-DebugLog "Ungültige Passwort-Parameter, verwende Fallback-Einstellungen."
            $UseSpecial = $true
            $UseNumbers = $true
            $UseUpper = $true
            $UseLower = $true
        }

        # Sammle aktivierte Zeichensätze
        $charSets = @()
        if ($UseLower) { $charSets += $lowerChars }
        if ($UseUpper) { $charSets += $upperChars }
        if ($UseNumbers) { $charSets += $numberChars }
        if ($UseSpecial) { $charSets += $specialChars }

        # Passwort-Erzeugung mit mindestens einem Zeichen aus jedem aktivierten Zeichensatz
        $password = ""
        $usedSets = New-Object System.Collections.Generic.HashSet[string]

        # Stelle sicher, dass mindestens ein Zeichen aus jedem aktivierten Zeichensatz verwendet wird
        foreach ($set in $charSets) {
            $char = $set[(Get-Random -Minimum 0 -Maximum $set.Length)]
            $password += $char
            $usedSets.Add($set) | Out-Null
        }

        # Fülle den Rest des Passworts auf
        for ($i = $password.Length; $i -lt $Length; $i++) {
            $set = $charSets[(Get-Random -Minimum 0 -Maximum $charSets.Count)]
            $char = $set[(Get-Random -Minimum 0 -Maximum $set.Length)]
            $password += $char
        }

        # Mische das Passwort (Fisher-Yates Shuffle)
        $passwordChars = $password.ToCharArray()
        for ($i = $passwordChars.Length - 1; $i -gt 0; $i--) {
            $j = Get-Random -Minimum 0 -Maximum ($i + 1)
            $temp = $passwordChars[$i]
            $passwordChars[$i] = $passwordChars[$j]
            $passwordChars[$j] = $temp
        }

        # Validiere die Passwort-Stärke
        $finalPassword = [string]::new($passwordChars)

        return $finalPassword
    } catch {
        Write-Log "Fehler beim Generieren des sicheren Passworts: $($_)" -Level "Error"

        # Fallback zu einem einfachen aber sicheren Passwort
        try {
            $fallbackPassword = "Temp" + (Get-Random -Minimum 100000 -Maximum 999999) + "!"
            return $fallbackPassword
        } catch {
            # Absolute Fallback-Option
            return "Passwort123!"
        }
    }
}

# FGPP-Verwaltung Funktionen
function Import-FGPPPolicies {
    try {
        Write-Log "Lade FGPP-Richtlinien."

        # DataGrid leeren
        if ($null -ne $dgFGPP) {
            $dgFGPP.Items.Clear()
        } else {
            Write-Log "DataGrid für FGPP ist null."
            return
        }

        # FGPP-Richtlinien abrufen
        $fgppPolicies = Get-ADFineGrainedPasswordPolicy -Filter * -Properties Name, Precedence, MinPasswordLength, PasswordHistoryCount, MinPasswordAge, MaxPasswordAge, ComplexityEnabled, ReversibleEncryptionEnabled, AppliesTo

        # Richtlinien in DataGrid anzeigen
        foreach ($policy in $fgppPolicies) {
            $dgFGPP.Items.Add([PSCustomObject]@{
                    Name              = $policy.Name
                    Precedence        = $policy.Precedence
                    MinPasswordLength = $policy.MinPasswordLength
                    ComplexityEnabled = if ($policy.ComplexityEnabled) { "Ja" } else { "Nein" }
                    PolicyObject      = $policy  # Vollständiges Objekt für spätere Verwendung
                })
        }

        Write-Log "FGPP-Richtlinien erfolgreich geladen."
    } catch {
        $errorMsg = "Fehler beim Laden der FGPP-Richtlinien: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Event-Handler für FGPP-DataGrid SelectionChanged
function dgFGPP_SelectionChanged {
    param (
        $sender,
        $e
    )
    try {
        $selectedPolicy = $dgFGPP.SelectedItem

        if ($null -eq $selectedPolicy) {
            # Felder zurücksetzen
            $txtFGPPName.Text = ""
            $txtFGPPPrecedence.Text = ""
            $txtFGPPMinLength.Text = ""
            $txtFGPPHistory.Text = ""
            $txtFGPPMinAge.Text = ""
            $txtFGPPMaxAge.Text = ""
            $chkFGPPComplexity.IsChecked = $false
            $chkFGPPReversibleEncryption.IsChecked = $false
            $lstFGPPAppliedGroups.Items.Clear()
            return
        }

        # Vollständiges Policy-Objekt abrufen
        $policy = $selectedPolicy.PolicyObject

        # Felder mit Werten füllen
        $txtFGPPName.Text = $policy.Name
        $txtFGPPPrecedence.Text = $policy.Precedence
        $txtFGPPMinLength.Text = $policy.MinPasswordLength
        $txtFGPPHistory.Text = $policy.PasswordHistoryCount

        # MinPasswordAge und MaxPasswordAge im Tage-Format
        $txtFGPPMinAge.Text = $policy.MinPasswordAge.Days
        $txtFGPPMaxAge.Text = $policy.MaxPasswordAge.Days

        $chkFGPPComplexity.IsChecked = $policy.ComplexityEnabled
        $chkFGPPReversibleEncryption.IsChecked = $policy.ReversibleEncryptionEnabled

        # Angewandte Gruppen anzeigen
        $lstFGPPAppliedGroups.Items.Clear()

        foreach ($groupDN in $policy.AppliesTo) {
            try {
                $group = Get-ADGroup -Identity $groupDN -Properties Name
                $lstFGPPAppliedGroups.Items.Add($group.Name)
            } catch {
                Write-Log "Fehler beim Abrufen der Gruppe $groupDN $($_)"
                $lstFGPPAppliedGroups.Items.Add("Unbekannte Gruppe: $groupDN")
            }
        }

        Write-Log "FGPP-Details für $($policy.Name) angezeigt."
    } catch {
        $errorMsg = "Fehler beim Anzeigen der FGPP-Details: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Funktion zum Erstellen einer neuen FGPP
function New-CreateFGPP {
    try {
        # Eingaben validieren
        if ([string]::IsNullOrWhiteSpace($txtFGPPName.Text)) {
            Update-Status "FGPP-Name darf nicht leer sein." "Warning"
            return
        }

        $precedence = 0
        if (-not [int]::TryParse($txtFGPPPrecedence.Text, [ref]$precedence)) {
            Update-Status "Präzedenz muss eine ganze Zahl sein." "Warning"
            return
        }

        $minLength = 0
        if (-not [int]::TryParse($txtFGPPMinLength.Text, [ref]$minLength)) {
            Update-Status "Minimale Passwortlänge muss eine ganze Zahl sein." "Warning"
            return
        }

        $history = 0
        if (-not [int]::TryParse($txtFGPPHistory.Text, [ref]$history)) {
            Update-Status "Passwort-Historie muss eine ganze Zahl sein." "Warning"
            return
        }

        $minAge = 0
        if (-not [int]::TryParse($txtFGPPMinAge.Text, [ref]$minAge)) {
            Update-Status "Minimales Passwortalter muss eine ganze Zahl sein." "Warning"
            return
        }

        $maxAge = 0
        if (-not [int]::TryParse($txtFGPPMaxAge.Text, [ref]$maxAge)) {
            Update-Status "Maximales Passwortalter muss eine ganze Zahl sein." "Warning"
            return
        }

        # Prüfen, ob Gruppen ausgewählt wurden
        if ($lstFGPPAppliedGroups.Items.Count -eq 0) {
            Update-Status "Es muss mindestens eine Gruppe ausgewählt werden." "Warning"
            return
        }

        # Gruppen-DNs sammeln
        $groupDNs = @()
        foreach ($groupName in $lstFGPPAppliedGroups.Items) {
            try {
                $group = Get-ADGroup -Filter { Name -eq $groupName } -Properties DistinguishedName
                if ($null -ne $group) {
                    $groupDNs += $group.DistinguishedName
                } else {
                    Update-Status "Gruppe $groupName wurde nicht gefunden." "Warning"
                }
            } catch {
                Write-Log "Fehler beim Abrufen der Gruppe $groupName $($_)"
            }
        }

        if ($groupDNs.Count -eq 0) {
            Update-Status "Keine gültigen Gruppen gefunden." "Warning"
            return
        }

        # FGPP erstellen
        $params = @{
            Name                        = $txtFGPPName.Text
            Precedence                  = $precedence
            MinPasswordLength           = $minLength
            PasswordHistoryCount        = $history
            MinPasswordAge              = "$($minAge).00:00:00" # Tage
            MaxPasswordAge              = "$($maxAge).00:00:00" # Tage
            ComplexityEnabled           = $chkFGPPComplexity.IsChecked
            ReversibleEncryptionEnabled = $chkFGPPReversibleEncryption.IsChecked
        }

        $newFGPP = New-ADFineGrainedPasswordPolicy @params

        # Gruppen zuweisen
        foreach ($groupDN in $groupDNs) {
            Add-ADFineGrainedPasswordPolicySubject -Identity $txtFGPPName.Text -Subjects $groupDN
        }

        Update-Status "FGPP $($txtFGPPName.Text) wurde erfolgreich erstellt." "Success"
        Import-FGPPPolicies # Aktualisieren der Liste

    } catch {
        $errorMsg = "Fehler beim Erstellen der FGPP: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Funktion zum Bearbeiten einer bestehenden FGPP
function Edit-FGPP {
    try {
        $selectedItem = $dgFGPP.SelectedItem
        if ($null -eq $selectedItem) {
            Update-Status "Bitte wählen Sie zuerst eine zu bearbeitende FGPP aus." "Warning"
            return
        }

        # Eingaben validieren
        $params = @{ ErrorAction = 'Stop' }
        if (-not [int]::TryParse($txtFGPPPrecedence.Text, [ref]$params.Precedence)) {
            Update-Status "Ungültige Eingabe: Präzedenz muss eine ganze Zahl sein." "Warning"; return
        }
        if (-not [int]::TryParse($txtFGPPMinLength.Text, [ref]$params.MinPasswordLength)) {
            Update-Status "Ungültige Eingabe: Minimale Passwortlänge muss eine ganze Zahl sein." "Warning"; return
        }
        if (-not [int]::TryParse($txtFGPPHistory.Text, [ref]$params.PasswordHistoryCount)) {
            Update-Status "Ungültige Eingabe: Passwort-Historie muss eine ganze Zahl sein." "Warning"; return
        }
        if (-not [int]::TryParse($txtFGPPMinAge.Text, [ref]$minAgeDays)) {
            Update-Status "Ungültige Eingabe: Minimales Passwortalter muss eine ganze Zahl sein." "Warning"; return
        }
        if (-not [int]::TryParse($txtFGPPMaxAge.Text, [ref]$maxAgeDays)) {
            Update-Status "Ungültige Eingabe: Maximales Passwortalter muss eine ganze Zahl sein." "Warning"; return
        }

        # FGPP-Einstellungen aktualisieren
        $setParams = @{
            Identity                    = $selectedItem.Name
            Precedence                  = $params.Precedence
            MinPasswordLength           = $params.MinPasswordLength
            PasswordHistoryCount        = $params.PasswordHistoryCount
            MinPasswordAge              = New-TimeSpan -Days $minAgeDays
            MaxPasswordAge              = New-TimeSpan -Days $maxAgeDays
            ComplexityEnabled           = $chkFGPPComplexity.IsChecked
            ReversibleEncryptionEnabled = $chkFGPPReversibleEncryption.IsChecked
            ErrorAction                 = 'Stop'
        }
        Set-ADFineGrainedPasswordPolicy @setParams

        # Gruppenmitgliedschaften effizient aktualisieren
        $currentPolicy = $selectedItem.PolicyObject
        $existingSubjects = $currentPolicy.AppliesTo
        $newSubjectNames = $lstFGPPAppliedGroups.Items | ForEach-Object { $_.ToString() }

        # Neue Gruppen-DNs abrufen
        $newSubjects = @()
        if ($newSubjectNames.Count -gt 0) {
            $filter = ($newSubjectNames | ForEach-Object { "(Name='$($_)')" }) -join ''
            $newSubjects = (Get-ADGroup -LDAPFilter "(|$filter)").DistinguishedName
        }

        # Änderungen berechnen (Delta)
        $compareResult = Compare-Object -ReferenceObject $existingSubjects -DifferenceObject $newSubjects -PassThru
        $subjectsToAdd = $compareResult | Where-Object { $_.SideIndicator -eq '=>' }
        $subjectsToRemove = $compareResult | Where-Object { $_.SideIndicator -eq '<=' }

        # Gruppen hinzufügen und entfernen
        if ($subjectsToAdd) {
            Add-ADFineGrainedPasswordPolicySubject -Identity $selectedItem.Name -Subjects $subjectsToAdd -ErrorAction Stop
        }
        if ($subjectsToRemove) {
            Remove-ADFineGrainedPasswordPolicySubject -Identity $selectedItem.Name -Subjects $subjectsToRemove -Confirm:$false -ErrorAction Stop
        }

        Update-Status "FGPP '$($selectedItem.Name)' wurde erfolgreich aktualisiert." "Success"
        Import-FGPPPolicies # Liste aktualisieren

    } catch {
        $errorMsg = "Fehler beim Bearbeiten der FGPP: $($_.Exception.Message)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Funktion zum Löschen einer FGPP
function Remove-FGPP {
    try {
        $selectedPolicy = $dgFGPP.SelectedItem

        if ($null -eq $selectedPolicy) {
            Update-Status "Keine FGPP ausgewählt." "Warning"
            return
        }

        $confirmation = [System.Windows.MessageBox]::Show("Möchten Sie die FGPP '$($selectedPolicy.Name)' wirklich löschen?", "FGPP löschen", "YesNo", "Warning")

        if ($confirmation -eq "Yes") {
            Remove-ADFineGrainedPasswordPolicy -Identity $selectedPolicy.Name -Confirm:$false
            Update-Status "FGPP $($selectedPolicy.Name) wurde gelöscht." "Success"
            Import-FGPPPolicies # Aktualisieren der Liste
        }
    } catch {
        $errorMsg = "Fehler beim Löschen der FGPP: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Hilfsfunktion für die Gruppe hinzufügen/entfernen
function Add-GroupToFGPP {
    try {
        $selectedGroup = $cmbFGPPGroups.SelectedItem

        if ([string]::IsNullOrWhiteSpace($selectedGroup)) {
            Update-Status "Keine Gruppe ausgewählt." "Warning"
            return
        }

        # Prüfen, ob die Gruppe bereits in der Liste ist
        foreach ($existingGroup in $lstFGPPAppliedGroups.Items) {
            if ($existingGroup -eq $selectedGroup) {
                Update-Status "Die Gruppe ist bereits in der Liste." "Info"
                return
            }
        }

        $lstFGPPAppliedGroups.Items.Add($selectedGroup)
        Update-Status "Gruppe $selectedGroup zur FGPP hinzugefügt." "Info"
    } catch {
        $errorMsg = "Fehler beim Hinzufügen der Gruppe: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

function Remove-GroupFromFGPP {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param ()

    try {
        $selectedGroup = $lstFGPPAppliedGroups.SelectedItem

        if ([string]::IsNullOrWhiteSpace($selectedGroup)) {
            Update-Status "Keine Gruppe in der Liste ausgewählt." "Warning"
            return
        }

        if ($PSCmdlet.ShouldProcess($selectedGroup, "Remove from FGPP list")) {
            $lstFGPPAppliedGroups.Items.Remove($selectedGroup)
            Update-Status "Gruppe $selectedGroup aus der FGPP entfernt." "Info"
        }
    } catch {
        $errorMsg = "Fehler beim Entfernen der Gruppe: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Passwörter für eine OU zurücksetzen
function Reset-OUPasswords {
    param (
        [string]$OUPath
    )
    try {
        if ([string]::IsNullOrWhiteSpace($OUPath)) {
            Update-Status "OU-Pfad ist leer." "Warning"
            return
        }

        Write-Log "Passwörter werden für Benutzer in der OU $OUPath zurückgesetzt."
        Update-Status "Passwörter werden für Benutzer in der OU $OUPath zurückgesetzt." "Info"

        # Benutzer in der OU abrufen
        $users = Get-ADUser -Filter { Enabled -eq $true } -SearchBase $OUPath -SearchScope Subtree -Properties SamAccountName

        if ($users.Count -eq 0) {
            Update-Status "Keine aktiven Benutzer in der ausgewählten OU gefunden." "Warning"
            return
        }

        Update-Status "Es wurden $($users.Count) aktive Benutzer gefunden." "Info"

        # Fortschritts-Tracking
        $processed = 0
        $totalUsers = $users.Count

        # HTML-Report vorbereiten
        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $reportFile = "$script:ReportFolder\OU_PasswordReset_$reportTime.html"
        $txtReportFile = "$script:ReportFolder\OU_PasswordReset_$reportTime.txt"

        $htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Passwort-Reset Bericht</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0078D7; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        h1, h2 { color: #0078D7; }
        .success { color: green; }
        .error { color: red; }
    </style>
</head>
<body>
    <h1>Passwort-Reset Bericht</h1>
    <p><b>Datum und Zeit:</b> $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</p>
    <p><b>Organizational Unit:</b> $OUPath</p>
    <h2>Benutzer-Liste</h2>
    <table>
        <tr>
            <th>Benutzername</th>
            <th>Anzeigename</th>
            <th>Neues Passwort</th>
            <th>Status</th>
        </tr>
"@

        $txtHeader = @"
Passwort-Reset Bericht
----------------------
Datum und Zeit: $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")
Organizational Unit: $OUPath

Benutzer-Liste:
"@

        # HTML und TXT initialisieren
        $htmlContent = $htmlHeader
        $txtContent = $txtHeader + "`r`n`r`n"

        # Für jeden Benutzer Passwort zurücksetzen
        foreach ($user in $users) {
            try {
                # Sicheres Passwort generieren
                $newPassword = GenerateSecurePassword
                $securePassword = ConvertTo-SecureString -String $newPassword -AsPlainText -Force

                # Passwort zurücksetzen
                Set-ADAccountPassword -Identity $user.SamAccountName -NewPassword $securePassword -Reset -ErrorAction Stop

                # Benutzerdaten für Bericht abrufen
                $userData = Get-ADUser -Identity $user.SamAccountName -Properties DisplayName, SamAccountName, Description

                # HTML und TXT aktualisieren
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($userData.DisplayName)</td>
            <td>$newPassword</td>
            <td class="success">Erfolgreich</td>
        </tr>
"@

                $txtContent += "$($user.SamAccountName) | $($userData.DisplayName) | $newPassword | Erfolgreich`r`n"

                # Statusaktualisierung
                $processed++
                if ($processed % 10 -eq 0 -or $processed -eq $totalUsers) {
                    $percent = [math]::Round(($processed / $totalUsers) * 100)
                    Update-Status "Fortschritt: $processed/$totalUsers Benutzer verarbeitet ($percent%)" "Info"
                }

                Write-Log "Passwort für Benutzer $($user.SamAccountName) wurde zurückgesetzt."
            } catch {
                $errorMsg = "Fehler beim Zurücksetzen des Passworts für $($user.SamAccountName): $($_)"
                Write-Log $errorMsg

                # Fehlgeschlagene Benutzer im Bericht vermerken
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($userData.DisplayName)</td>
            <td>-</td>
            <td class="error">Fehler: $($_.Exception.Message)</td>
        </tr>
"@

                $txtContent += "$($user.SamAccountName) | $($userData.DisplayName) | - | Fehler: $($_.Exception.Message)`r`n"
            }
        }

        # HTML-Bericht abschließen
        $htmlContent += @"
    </table>
    <p><b>Zusammenfassung:</b> $processed von $totalUsers Benutzern erfolgreich verarbeitet.</p>
</body>
</html>
"@

        $txtContent += "`r`n`r`nZusammenfassung: $processed von $totalUsers Benutzern erfolgreich verarbeitet."

        # Berichte speichern
        try {
            $htmlContent | Out-File -FilePath $reportFile -Encoding utf8 -Force
            $txtContent | Out-File -FilePath $txtReportFile -Encoding utf8 -Force

            Update-Status "Bericht wurde gespeichert unter: $reportFile" "Success"
            Update-Status "Text-Bericht wurde gespeichert unter: $txtReportFile" "Success"
        } catch {
            Write-Log "Fehler beim Speichern des Berichts: $($_)"
            Update-Status "Fehler beim Speichern des Berichts: $($_)" "Error"
        }

        Update-Status "Passwort-Reset für $processed von $totalUsers Benutzern in der OU wurde abgeschlossen." "Success"

        # Bericht öffnen anbieten
        $openReport = [System.Windows.MessageBox]::Show(
            "Passwort-Reset für $processed von $totalUsers Benutzern wurde abgeschlossen. Möchten Sie den Bericht jetzt öffnen?",
            "Passwort-Reset abgeschlossen",
            "YesNo",
            "Information"
        )

        if ($openReport -eq "Yes") {
            try {
                Start-Process $reportFile
            } catch {
                Write-Log "Fehler beim Öffnen des Berichts: $($_)"
                Update-Status "Fehler beim Öffnen des Berichts: $($_)" "Error"
            }
        }
    } catch {
        $errorMsg = "Fehler beim Zurücksetzen der Passwörter für OU $OUPath`: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Konten in einer OU entsperren
function Unlock-OUAccounts {
    param (
        [string]$OUPath
    )
    try {
        if ([string]::IsNullOrWhiteSpace($OUPath)) {
            Update-Status "OU-Pfad ist leer." "Warning"
            return
        }

        Write-Log "Konten werden für Benutzer in der OU $OUPath entsperrt."
        Update-Status "Konten werden für Benutzer in der OU $OUPath entsperrt." "Info"

        # Gesperrte Benutzer in der OU abrufen
        $lockedUsers = Get-ADUser -Filter { LockedOut -eq $true } -SearchBase $OUPath -SearchScope Subtree -Properties SamAccountName, DisplayName, LockedOut

        if ($lockedUsers.Count -eq 0) {
            Update-Status "Keine gesperrten Benutzer in der ausgewählten OU gefunden." "Info"
            return
        }

        Update-Status "Es wurden $($lockedUsers.Count) gesperrte Benutzer gefunden." "Info"

        # HTML-Report vorbereiten
        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $reportFile = "$script:ReportFolder\OU_UnlockAccounts_$reportTime.html"

        $htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Konto-Entsperrung Bericht</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0078D7; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        h1, h2 { color: #0078D7; }
        .success { color: green; }
        .error { color: red; }
    </style>
</head>
<body>
    <h1>Konto-Entsperrung Bericht</h1>
    <p><b>Datum und Zeit:</b> $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</p>
    <p><b>Organizational Unit:</b> $OUPath</p>
    <h2>Entsperrte Konten</h2>
    <table>
        <tr>
            <th>Benutzername</th>
            <th>Anzeigename</th>
            <th>Status</th>
        </tr>
"@

        # HTML initialisieren
        $htmlContent = $htmlHeader

        # Zähler für erfolgreiche Entsperrungen
        $successCount = 0

        # Für jeden gesperrten Benutzer Konto entsperren
        foreach ($user in $lockedUsers) {
            try {
                # Konto entsperren
                Unlock-ADAccount -Identity $user.SamAccountName -ErrorAction Stop

                # HTML aktualisieren
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($user.DisplayName)</td>
            <td class="success">Erfolgreich entsperrt</td>
        </tr>
"@

                $successCount++
                Write-Log "Konto für Benutzer $($user.SamAccountName) wurde entsperrt."
                Update-Status "Konto für Benutzer $($user.SamAccountName) wurde entsperrt." "Success"
            } catch {
                $errorMsg = "Fehler beim Entsperren des Kontos für $($user.SamAccountName): $($_)"
                Write-Log $errorMsg

                # Fehlgeschlagene Entsperrungen im Bericht vermerken
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($user.DisplayName)</td>
            <td class="error">Fehler: $($_.Exception.Message)</td>
        </tr>
"@

                Update-Status $errorMsg "Error"
            }
        }

        # HTML-Bericht abschließen
        $htmlContent += @"
    </table>
    <p><b>Zusammenfassung:</b> $successCount von $($lockedUsers.Count) Konten erfolgreich entsperrt.</p>
</body>
</html>
"@

        # Bericht speichern
        try {
            $htmlContent | Out-File -FilePath $reportFile -Encoding utf8 -Force
            Update-Status "Bericht wurde gespeichert unter: $reportFile" "Success"
        } catch {
            Write-Log "Fehler beim Speichern des Berichts: $($_)"
            Update-Status "Fehler beim Speichern des Berichts: $($_)" "Error"
        }

        Update-Status "Entsperren von $successCount von $($lockedUsers.Count) Konten in der OU wurde abgeschlossen." "Success"

        # Bericht öffnen anbieten
        $openReport = [System.Windows.MessageBox]::Show(
            "Entsperren von $successCount von $($lockedUsers.Count) Konten wurde abgeschlossen. Möchten Sie den Bericht jetzt öffnen?",
            "Konto-Entsperrung abgeschlossen",
            "YesNo",
            "Information"
        )

        if ($openReport -eq "Yes") {
            try {
                Start-Process $reportFile
            } catch {
                Write-Log "Fehler beim Öffnen des Berichts: $($_)"
                Update-Status "Fehler beim Öffnen des Berichts: $($_)" "Error"
            }
        }
    } catch {
        $errorMsg = "Fehler beim Entsperren der Konten für OU $OUPath`: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Passwörter für eine Gruppe zurücksetzen
function Reset-GroupPasswords {
    param (
        [string]$GroupName
    )
    try {
        if ([string]::IsNullOrWhiteSpace($GroupName)) {
            Update-Status "Gruppenname ist leer." "Warning"
            return
        }

        Write-Log "Passwörter werden für Benutzer in der Gruppe $GroupName zurückgesetzt."
        Update-Status "Passwörter werden für Benutzer in der Gruppe $GroupName zurückgesetzt." "Info"

        # Benutzer in der Gruppe abrufen
        $groupMembers = Get-ADGroupMember -Identity $GroupName | Where-Object { $_.objectClass -eq "user" }
        $enabledUsers = @()

        foreach ($member in $groupMembers) {
            $user = Get-ADUser -Identity $member -Properties Enabled
            if ($user.Enabled) {
                $enabledUsers += $user
            }
        }

        if ($enabledUsers.Count -eq 0) {
            Update-Status "Keine aktiven Benutzer in der ausgewählten Gruppe gefunden." "Warning"
            return
        }

        Update-Status "Es wurden $($enabledUsers.Count) aktive Benutzer gefunden." "Info"

        # Fortschritts-Tracking
        $processed = 0
        $totalUsers = $enabledUsers.Count

        # HTML-Report vorbereiten
        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $reportFile = "$script:ReportFolder\Group_PasswordReset_$reportTime.html"
        $txtReportFile = "$script:ReportFolder\Group_PasswordReset_$reportTime.txt"

        $htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Passwort-Reset Bericht</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0078D7; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        h1, h2 { color: #0078D7; }
        .success { color: green; }
        .error { color: red; }
    </style>
</head>
<body>
    <h1>Passwort-Reset Bericht</h1>
    <p><b>Datum und Zeit:</b> $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</p>
    <p><b>Gruppe:</b> $GroupName</p>
    <h2>Benutzer-Liste</h2>
    <table>
        <tr>
            <th>Benutzername</th>
            <th>Anzeigename</th>
            <th>Neues Passwort</th>
            <th>Status</th>
        </tr>
"@

        $txtHeader = @"
Passwort-Reset Bericht
----------------------
Datum und Zeit: $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")
Gruppe: $GroupName

Benutzer-Liste:
"@

        # HTML und TXT initialisieren
        $htmlContent = $htmlHeader
        $txtContent = $txtHeader + "`r`n`r`n"

        # Für jeden Benutzer Passwort zurücksetzen
        foreach ($user in $enabledUsers) {
            try {
                # Sicheres Passwort generieren
                $newPassword = GenerateSecurePassword
                $securePassword = ConvertTo-SecureString -String $newPassword -AsPlainText -Force

                # Passwort zurücksetzen
                Set-ADAccountPassword -Identity $user.SamAccountName -NewPassword $securePassword -Reset -ErrorAction Stop

                # Benutzerdaten für Bericht abrufen
                $userData = Get-ADUser -Identity $user.SamAccountName -Properties DisplayName

                # HTML und TXT aktualisieren
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($userData.DisplayName)</td>
            <td>$newPassword</td>
            <td class="success">Erfolgreich</td>
        </tr>
"@

                $txtContent += "$($user.SamAccountName) | $($userData.DisplayName) | $newPassword | Erfolgreich`r`n"

                # Statusaktualisierung
                $processed++
                if ($processed % 10 -eq 0 -or $processed -eq $totalUsers) {
                    $percent = [math]::Round(($processed / $totalUsers) * 100)
                    Update-Status "Fortschritt: $processed/$totalUsers Benutzer verarbeitet ($percent%)" "Info"
                }

                Write-Log "Passwort für Benutzer $($user.SamAccountName) wurde zurückgesetzt."
            } catch {
                $errorMsg = "Fehler beim Zurücksetzen des Passworts für $($user.SamAccountName): $($_)"
                Write-Log $errorMsg

                # Fehlgeschlagene Benutzer im Bericht vermerken
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($userData.DisplayName)</td>
            <td>-</td>
            <td class="error">Fehler: $($_.Exception.Message)</td>
        </tr>
"@

                $txtContent += "$($user.SamAccountName) | $($userData.DisplayName) | - | Fehler: $($_.Exception.Message)`r`n"
            }
        }

        # HTML-Bericht abschließen
        $htmlContent += @"
    </table>
    <p><b>Zusammenfassung:</b> $processed von $totalUsers Benutzern erfolgreich verarbeitet.</p>
</body>
</html>
"@

        $txtContent += "`r`n`r`nZusammenfassung: $processed von $totalUsers Benutzern erfolgreich verarbeitet."

        # Berichte speichern
        try {
            $htmlContent | Out-File -FilePath $reportFile -Encoding utf8 -Force
            $txtContent | Out-File -FilePath $txtReportFile -Encoding utf8 -Force

            Update-Status "Bericht wurde gespeichert unter: $reportFile" "Success"
            Update-Status "Text-Bericht wurde gespeichert unter: $txtReportFile" "Success"
        } catch {
            Write-Log "Fehler beim Speichern des Berichts: $($_)"
            Update-Status "Fehler beim Speichern des Berichts: $($_)" "Error"
        }


        # Benutzer in der Gruppe abrufen
        $groupMembers = Get-ADGroupMember -Identity $GroupName | Where-Object { $_.objectClass -eq "user" }
        $lockedUsers = @()

        foreach ($member in $groupMembers) {
            $user = Get-ADUser -Identity $member -Properties SamAccountName, DisplayName, LockedOut
            if ($user.LockedOut) {
                $lockedUsers += $user
            }
        }

        if ($lockedUsers.Count -eq 0) {
            Update-Status "Keine gesperrten Benutzer in der ausgewählten Gruppe gefunden." "Info"
            return
        }

        Update-Status "Es wurden $($lockedUsers.Count) gesperrte Benutzer gefunden." "Info"

        # HTML-Report vorbereiten
        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $reportFile = "$script:ReportFolder\Group_UnlockAccounts_$reportTime.html"

        $htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Konto-Entsperrung Bericht</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0078D7; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        h1, h2 { color: #0078D7; }
        .success { color: green; }
        .error { color: red; }
    </style>
</head>
<body>
    <h1>Konto-Entsperrung Bericht</h1>
    <p><b>Datum und Zeit:</b> $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</p>
    <p><b>Gruppe:</b> $GroupName</p>
    <h2>Entsperrte Konten</h2>
    <table>
        <tr>
            <th>Benutzername</th>
            <th>Anzeigename</th>
            <th>Status</th>
        </tr>
"@

        # HTML initialisieren
        $htmlContent = $htmlHeader

        # Zähler für erfolgreiche Entsperrungen
        $successCount = 0

        # Für jeden gesperrten Benutzer Konto entsperren
        foreach ($user in $lockedUsers) {
            try {
                # Konto entsperren
                Unlock-ADAccount -Identity $user.SamAccountName -ErrorAction Stop

                # HTML aktualisieren
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($user.DisplayName)</td>
            <td class="success">Erfolgreich entsperrt</td>
        </tr>
"@

                $successCount++
                Write-Log "Konto für Benutzer $($user.SamAccountName) wurde entsperrt."
                Update-Status "Konto für Benutzer $($user.SamAccountName) wurde entsperrt." "Success"
            } catch {
                $errorMsg = "Fehler beim Entsperren des Kontos für $($user.SamAccountName): $($_)"
                Write-Log $errorMsg

                # Fehlgeschlagene Entsperrungen im Bericht vermerken
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($user.DisplayName)</td>
            <td class="error">Fehler: $($_.Exception.Message)</td>
        </tr>
"@

                Update-Status $errorMsg "Error"
            }
        }

        # HTML-Bericht abschließen
        $htmlContent += @"
    </table>
    <p><b>Zusammenfassung:</b> $successCount von $($lockedUsers.Count) Konten erfolgreich entsperrt.</p>
</body>
</html>
"@

        # Bericht speichern
        try {
            $htmlContent | Out-File -FilePath $reportFile -Encoding utf8 -Force
            Update-Status "Bericht wurde gespeichert unter: $reportFile" "Success"
        } catch {
            Write-Log "Fehler beim Speichern des Berichts: $($_)"
            Update-Status "Fehler beim Speichern des Berichts: $($_)" "Error"
        }

        Update-Status "Entsperren von $successCount von $($lockedUsers.Count) Konten in der Gruppe wurde abgeschlossen." "Success"

        # Bericht öffnen anbieten
        $openReport = [System.Windows.MessageBox]::Show(
            "Entsperren von $successCount von $($lockedUsers.Count) Konten wurde abgeschlossen. Möchten Sie den Bericht jetzt öffnen?",
            "Konto-Entsperrung abgeschlossen",
            "YesNo",
            "Information"
        )

        if ($openReport -eq "Yes") {
            try {
                Start-Process $reportFile
            } catch {
                Write-Log "Fehler beim Öffnen des Berichts: $($_)"
                Update-Status "Fehler beim Öffnen des Berichts: $($_)" "Error"
            }
        }
    } catch {
        $errorMsg = "Fehler beim Entsperren der Konten für Gruppe $GroupName`: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Import-Module mit Fehlerbehandlung
try {
    # Prüfe AD-Verbindung vor dem Laden des Moduls
    Write-GuaranteedDebug -Message "Prüfe AD-Verbindung und lade Module..." -Level "INFO"

    # Prüfen, ob das AD-Modul bereits geladen ist
    if (-not (Get-Module -Name ActiveDirectory)) {
        # Überprüfen, ob das Modul verfügbar ist, bevor es geladen wird
        if (Get-Module -ListAvailable -Name ActiveDirectory) {
            Write-GuaranteedDebug -Message "Active Directory Modul gefunden, lade..." -Level "INFO"
            Import-Module ActiveDirectory -ErrorAction Stop
            Write-GuaranteedDebug -Message "Active Directory-Modul wurde erfolgreich geladen" -Level "INFO"
        } else {
            throw "Das Active Directory PowerShell-Modul ist auf diesem System nicht installiert."
        }
    } else {
        Write-GuaranteedDebug -Message "Active Directory-Modul ist bereits geladen" -Level "INFO"
    }

    # Prüfe, ob eine AD-Verbindung hergestellt werden kann
    Write-GuaranteedDebug -Message "Teste die Verbindung zum Active Directory..." -Level "INFO"

    # Versuche, die Domäne zu ermitteln
    try {
        $domain = $null
        $adConnectionOK = $false

        # Methode 1: Get-ADDomain
        try {
            $domain = Get-ADDomain -ErrorAction Stop
            $adConnectionOK = $true
            Write-GuaranteedDebug -Message "Aktive Domäne gefunden: $($domain.DNSRoot)" -Level "INFO"
        } catch {
            Write-GuaranteedDebug -Message "Get-ADDomain konnte keine Domäne finden: $($_.Exception.Message)" -Level "WARNING"

            # Methode 2: ADSI Verbindung
            try {
                Write-GuaranteedDebug -Message "Versuche alternative ADSI-Verbindung..." -Level "INFO"
                $adsi = New-Object System.DirectoryServices.DirectoryEntry

                if ($null -ne $adsi.distinguishedName) {
                    $adConnectionOK = $true
                    $domainName = $adsi.distinguishedName -replace 'DC=', '' -replace ',', '.'
                    Write-GuaranteedDebug -Message "ADSI-Verbindung erfolgreich. Domäne: $domainName" -Level "INFO"
                } else {
                    Write-GuaranteedDebug -Message "ADSI-Verbindung konnte keine Domäne ermitteln" -Level "WARNING"
                }
            } catch {
                Write-GuaranteedDebug -Message "ADSI-Verbindung fehlgeschlagen: $($_.Exception.Message)" -Level "WARNING"
            }

            # Methode 3: Netzwerkinformationen
            if (-not $adConnectionOK) {
                try {
                    Write-GuaranteedDebug -Message "Versuche Domäneninformationen aus Netzwerkeinstellungen zu lesen..." -Level "INFO"
                    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem

                    if ($computerSystem.PartOfDomain) {
                        $adConnectionOK = $true
                        $domainName = $computerSystem.Domain
                        Write-GuaranteedDebug -Message "Domäne aus Computerinformationen ermittelt: $domainName" -Level "INFO"
                    } else {
                        Write-GuaranteedDebug -Message "Computer ist nicht Teil einer Domäne" -Level "WARNING"
                    }
                } catch {
                    Write-GuaranteedDebug -Message "Fehler beim Abrufen der Computerinformationen: $($_.Exception.Message)" -Level "WARNING"
                }
            }
        }

        # Wenn keine AD-Verbindung hergestellt werden konnte
        if (-not $adConnectionOK) {
            throw "Es konnte keine Verbindung zu einer Active Directory-Domäne hergestellt werden. Dieses Tool benötigt eine aktive Domänenverbindung."
        }

        # AD-Modul und Verbindung sind in Ordnung
        $script:ADConnectionStatus = "Connected"
        Write-GuaranteedDebug -Message "Active Directory-Verbindung ist aktiv und funktionsfähig" -Level "INFO"
    } catch {
        $errorMsg = "Fehler bei der Verbindung zum Active Directory: $($_.Exception.Message)"
        Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"

        # AD-Verbindung fehlgeschlagen, aber nicht kritisch abbrechen
        $script:ADConnectionStatus = "Warning"
    }
} catch {
    $errorMsg = "Das Active Directory-Modul konnte nicht geladen werden: $($_.Exception.Message)"
    Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"

    # AD-Modul-Fehler, aber trotzdem weitermachen
    $script:ADConnectionStatus = "Error"

    try {
        [System.Windows.MessageBox]::Show(
            "Active Directory-Verbindung fehlgeschlagen: $($_.Exception.Message)" +
            "`n`nDas Programm wird im eingeschränkten Modus fortgesetzt. " +
            "Nicht alle Funktionen werden verfügbar sein.",
            "Warnung - AD-Verbindungsproblem",
            "OK",
            "Warning"
        )
    } catch {
        Write-GuaranteedDebug -Message "Konnte MessageBox nicht anzeigen: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Zeige AD-Verbindungsstatus in der GUI an, wenn ein Status-Element existiert
function Update-ADConnectionStatusInGUI {
    try {
        if ($null -ne $script:lblADStatus) {
            switch ($script:ADConnectionStatus) {
                "Connected" {
                    $script:lblADStatus.Content = "AD: Verbunden"
                    $script:lblADStatus.Foreground = "Green"
                }
                "Warning" {
                    $script:lblADStatus.Content = "AD: Eingeschränkt"
                    $script:lblADStatus.Foreground = "Orange"
                }
                "Error" {
                    $script:lblADStatus.Content = "AD: Nicht verbunden"
                    $script:lblADStatus.Foreground = "Red"
                }
                default {
                    $script:lblADStatus.Content = "AD: Unbekannt"
                    $script:lblADStatus.Foreground = "Gray"
                }
            }
        }
    } catch {
        Write-GuaranteedDebug -Message "Fehler beim Aktualisieren des AD-Status in der GUI: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Funktion zum Laden aller AD-Gruppen in eine ComboBox
function Import-GroupsToComboBox {
    param (
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.ComboBox]$ComboBox
    )
    try {
        Write-Log "Lade AD-Gruppen in die ComboBox."
        $ComboBox.Items.Clear()

        # AD-Gruppen abrufen und nach Namen sortieren
        $groups = Get-ADGroup -Filter * -Properties Name | Sort-Object -Property Name

        foreach ($group in $groups) {
            $ComboBox.Items.Add($group.Name)
        }

        Write-Log "$($groups.Count) Gruppen wurden geladen."
        Update-Status "$($groups.Count) Gruppen wurden geladen." "Info"
    } catch {
        $errorMsg = "Fehler beim Laden der AD-Gruppen: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Funktion zum Laden der OU-Struktur in eine TreeView
function Import-OUsToTreeView {
    param (
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.TreeView]$TreeView
    )
    try {
        Write-Log "Lade OU-Struktur in die TreeView."
        $TreeView.Items.Clear()

        # Domänen-Root abrufen
        $domain = Get-ADDomain
        $rootDN = $domain.DistinguishedName

        # Root-Element für die TreeView erstellen
        $rootItem = New-Object System.Windows.Controls.TreeViewItem
        $rootItem.Header = $domain.Name
        $rootItem.Tag = $rootDN
        $rootItem.IsExpanded = $true # Root-Element standardmäßig ausklappen

        $TreeView.Items.Add($rootItem)

        # Rekursive Funktion zum Füllen der OUs
        function Add-OUsToTreeViewItem {
            param (
                [System.Windows.Controls.TreeViewItem]$ParentItem,
                [string]$ParentDN
            )
            try {
                $ous = Get-ADOrganizationalUnit -Filter * -SearchBase $ParentDN -SearchScope OneLevel | Sort-Object -Property Name

                foreach ($ou in $ous) {
                    $ouItem = New-Object System.Windows.Controls.TreeViewItem
                    $ouItem.Header = $ou.Name
                    $ouItem.Tag = $ou.DistinguishedName
                    $ParentItem.Items.Add($ouItem)

                    # Rekursiver Aufruf für untergeordnete OUs
                    Add-OUsToTreeViewItem -ParentItem $ouItem -ParentDN $ou.DistinguishedName
                }
            } catch {
                # Fehler beim Abrufen von OUs still behandeln, um den Prozess nicht zu unterbrechen
                Write-Log "Fehler beim Abrufen von OUs unter $ParentDN`: $($_)" -Level "Warning"
            }
        }

        # Start der rekursiven Befüllung
        Add-OUsToTreeViewItem -ParentItem $rootItem -ParentDN $rootDN

        Write-Log "OU-Struktur wurde erfolgreich geladen."
        Update-Status "OU-Struktur wurde geladen." "Info"
    } catch {
        $errorMsg = "Fehler beim Laden der OU-Struktur: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Verbesserte Initialisierung für die Tab-Anzeige
function Initialize-TabPages {
    try {
        # Stelle sicher, dass der TabControl existiert
        if ($null -eq $script:mainTabControl) {
            Write-Log "TabControl konnte nicht gefunden werden." -Level "Error"
            return
        }

        # Setze alle TabItems auf sichtbar und füge Handler für Navigation hinzu
        $tabCount = $script:mainTabControl.Items.Count
        Write-Log "Initialisiere $tabCount Tab-Seiten."

        for ($i = 0; $i -lt $tabCount; $i++) {
            try {
                $tab = $script:mainTabControl.Items[$i]
                if ($null -ne $tab) {
                    $tab.Visibility = "Visible"
                    Write-DebugLog "Tab $i ($($tab.Header)) auf sichtbar gesetzt."
                }
            } catch {
                Write-Log "Fehler beim Initialisieren von Tab $i`: $($_)" -Level "Warning"
            }
        }

        # Ersten Tab standardmäßig aktivieren
        $script:mainTabControl.SelectedIndex = 0

        # Befülle OU TreeView und Group ComboBox
        if ($null -ne $treeViewOUs) {
            try {
                Import-OUsToTreeView -TreeView $treeViewOUs
            } catch {
                Write-Log "Fehler beim Laden der OUs: $($_)" -Level "Error"
            }
        }

        if ($null -ne $cmbGroups) {
            try {
                Import-GroupsToComboBox -ComboBox $cmbGroups
            } catch {
                Write-Log "Fehler beim Laden der Gruppen: $($_)" -Level "Error"
            }
        }

        Write-Log "Tab-Initialisierung abgeschlossen."
    } catch {
        $errorMsg = "Fehler bei der Tab-Initialisierung: $($_)"
        Write-Log $errorMsg -Level "Error"
    }
}

# Passwort-Richtlinien in Tabelle darstellen
function Show-PasswordPolicies {
    try {
        Write-Log "Lese Passwort-Richtlinien aus."
        $Policies = Get-ADDefaultDomainPasswordPolicy

        # DataGrid mit Richtlinien füllen
        if ($null -ne $dgPasswordPolicies) {
            $dgPasswordPolicies.Items.Clear()

            # Daten für das DataGrid vorbereiten
            $policiesData = @(
                [PSCustomObject]@{
                    Policy         = "Minimale Passwortlänge"
                    Value          = $Policies.MinPasswordLength
                    Recommendation = "Mindestens 12 Zeichen (NIST-Empfehlung)"
                },
                [PSCustomObject]@{
                    Policy         = "Passwort-Komplexität"
                    Value          = if ($Policies.ComplexityEnabled) { "Aktiviert" } else { "Deaktiviert" }
                    Recommendation = "Aktiviert + Passphrasen erlauben"
                },
                [PSCustomObject]@{
                    Policy         = "Passwort-Historie"
                    Value          = $Policies.PasswordHistoryCount
                    Recommendation = "Mindestens 24 Passwörter speichern"
                },
                [PSCustomObject]@{
                    Policy         = "Maximales Passwortalter"
                    Value          = "$($Policies.MaxPasswordAge.Days) Tage"
                    Recommendation = "60-90 Tage oder NIST: Nur bei Verdacht auf Kompromittierung"
                },
                [PSCustomObject]@{
                    Policy         = "Minimales Passwortalter"
                    Value          = "$($Policies.MinPasswordAge.Days) Tage"
                    Recommendation = "1-2 Tage zur Verhinderung schneller Wiederverwendung"
                },
                [PSCustomObject]@{
                    Policy         = "Reversible Verschlüsselung"
                    Value          = if ($Policies.ReversibleEncryptionEnabled) { "Aktiviert" } else { "Deaktiviert" }
                    Recommendation = "Deaktiviert (Sicherheitsrisiko)"
                }
            )

            # Account Lockout-Richtlinien hinzufügen
            try {
                $lockoutPolicy = Get-ADDefaultDomainPasswordPolicy

                $policiesData += [PSCustomObject]@{
                    Policy         = "Account-Lockout-Schwelle"
                    Value          = if ($lockoutPolicy.LockoutThreshold -eq 0) { "Deaktiviert" } else { "$($lockoutPolicy.LockoutThreshold) Versuche" }
                    Recommendation = "5-10 fehlgeschlagene Versuche"
                }

                if ($lockoutPolicy.LockoutThreshold -gt 0) {
                    $policiesData += [PSCustomObject]@{
                        Policy         = "Lockout-Dauer"
                        Value          = "$($lockoutPolicy.LockoutDuration.TotalMinutes) Minuten"
                        Recommendation = "15-30 Minuten"
                    }

                    $policiesData += [PSCustomObject]@{
                        Policy         = "Lockout-Zurücksetzungszähler"
                        Value          = "$($lockoutPolicy.LockoutObservationWindow.TotalMinutes) Minuten"
                        Recommendation = "15-30 Minuten"
                    }
                }
            } catch {
                Write-Log "Fehler beim Abrufen der Account-Lockout-Richtlinien: $($_)"
            }

            # FGPP-Informationen hinzufügen, falls vorhanden
            try {
                # Code zum Hinzufügen der FGPP-Informationen hier
                if ($null -ne $fgppPolicies -and ($fgppPolicies -is [array] -and $fgppPolicies.Count -gt 0 -or $fgppPolicies -isnot [array])) {
                    $policiesData += [PSCustomObject]@{
                        Policy         = "Anzahl der FGPP-Richtlinien"
                        Value          = "$($fgppPolicies.Count) aktive FGPP"
                        Recommendation = "Prüfen Sie den FGPP-Tab für Details"
                    }
                }
            } catch {
                Write-Log "Fehler beim Abrufen der FGPP-Informationen: $($_)"
            }

            # Daten zum DataGrid hinzufügen
            foreach ($policy in $policiesData) {
                $dgPasswordPolicies.Items.Add($policy)
            }

            Write-Log "Passwort-Richtlinien wurden erfolgreich angezeigt."
        } else {
            Write-Log "DataGrid für Passwort-Richtlinien nicht gefunden."
        }
    } catch {
        $errorMsg = "Fehler beim Anzeigen der Passwort-Richtlinien: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}


# Konten in einer Gruppe entsperren
function Unlock-GroupAccounts {
    param (
        [string]$GroupName
    )
    try {
        if ([string]::IsNullOrWhiteSpace($GroupName)) {
            Update-Status "Gruppenname ist leer." "Warning"
            return
        }

        Write-Log "Konten werden für Benutzer in der Gruppe $GroupName entsperrt."
        Update-Status "Konten werden für Benutzer in der Gruppe $GroupName entsperrt." "Info"

        # Benutzer in der Gruppe abrufen
        $groupMembers = Get-ADGroupMember -Identity $GroupName | Where-Object { $_.objectClass -eq "user" }
        $lockedUsers = @()

        foreach ($member in $groupMembers) {
            $user = Get-ADUser -Identity $member -Properties SamAccountName, DisplayName, LockedOut
            if ($user.LockedOut) {
                $lockedUsers += $user
            }
        }

        if ($lockedUsers.Count -eq 0) {
            Update-Status "Keine gesperrten Benutzer in der ausgewählten Gruppe gefunden." "Info"
            return
        }

        Update-Status "Es wurden $($lockedUsers.Count) gesperrte Benutzer gefunden." "Info"

        # HTML-Report vorbereiten
        $reportTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $reportFile = "$script:ReportFolder\Group_UnlockAccounts_$reportTime.html"

        $htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Konto-Entsperrung Bericht</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0078D7; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        h1, h2 { color: #0078D7; }
        .success { color: green; }
        .error { color: red; }
    </style>
</head>
<body>
    <h1>Konto-Entsperrung Bericht</h1>
    <p><b>Datum und Zeit:</b> $(Get-Date -Format "dd.MM.yyyy HH:mm:ss")</p>
    <p><b>Gruppe:</b> $GroupName</p>
    <h2>Entsperrte Konten</h2>
    <table>
        <tr>
            <th>Benutzername</th>
            <th>Anzeigename</th>
            <th>Status</th>
        </tr>
"@

        # HTML initialisieren
        $htmlContent = $htmlHeader

        # Zähler für erfolgreiche Entsperrungen
        $successCount = 0

        # Für jeden gesperrten Benutzer Konto entsperren
        foreach ($user in $lockedUsers) {
            try {
                # Konto entsperren
                Unlock-ADAccount -Identity $user.SamAccountName -ErrorAction Stop

                # HTML aktualisieren
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($user.DisplayName)</td>
            <td class="success">Erfolgreich entsperrt</td>
        </tr>
"@

                $successCount++
                Write-Log "Konto für Benutzer $($user.SamAccountName) wurde entsperrt."
                Update-Status "Konto für Benutzer $($user.SamAccountName) wurde entsperrt." "Success"
            } catch {
                $errorMsg = "Fehler beim Entsperren des Kontos für $($user.SamAccountName): $($_)"
                Write-Log $errorMsg

                # Fehlgeschlagene Entsperrungen im Bericht vermerken
                $htmlContent += @"
        <tr>
            <td>$($user.SamAccountName)</td>
            <td>$($user.DisplayName)</td>
            <td class="error">Fehler: $($_.Exception.Message)</td>
        </tr>
"@

                Update-Status $errorMsg "Error"
            }
        }

        # HTML-Bericht abschließen
        $htmlContent += @"
    </table>
    <p><b>Zusammenfassung:</b> $successCount von $($lockedUsers.Count) Konten erfolgreich entsperrt.</p>
</body>
</html>
"@

        # Bericht speichern
        try {
            $htmlContent | Out-File -FilePath $reportFile -Encoding utf8 -Force
            Update-Status "Bericht wurde gespeichert unter: $reportFile" "Success"
        } catch {
            Write-Log "Fehler beim Speichern des Berichts: $($_)"
            Update-Status "Fehler beim Speichern des Berichts: $($_)" "Error"
        }

        Update-Status "Entsperren von $successCount von $($lockedUsers.Count) Konten in der Gruppe wurde abgeschlossen." "Success"

        # Bericht öffnen anbieten
        $openReport = [System.Windows.MessageBox]::Show(
            "Entsperren von $successCount von $($lockedUsers.Count) Konten wurde abgeschlossen. Möchten Sie den Bericht jetzt öffnen?",
            "Konto-Entsperrung abgeschlossen",
            "YesNo",
            "Information"
        )

        if ($openReport -eq "Yes") {
            try {
                Start-Process $reportFile
            } catch {
                Write-Log "Fehler beim Öffnen des Berichts: $($_)"
                Update-Status "Fehler beim Öffnen des Berichts: $($_)" "Error"
            }
        }
    } catch {
        $errorMsg = "Fehler beim Entsperren der Konten für Gruppe $GroupName`: $($_)"
        Write-Log $errorMsg
        Update-Status $errorMsg "Error"
    }
}

# Event-Handler für alle UI-Elemente registrieren
function Register-EventHandlers {
    try {
        Write-Log "Registriere Event-Handler für UI-Elemente."

        # Logo-Button mit URL verknüpfen
        if ($null -ne $HeaderLogo) {
            $HeaderLogo.Add_Click({
                    try {
                        Start-Process $script:HeaderLogoURL
                    } catch {
                        Write-Log "Fehler beim Öffnen der URL: $($_)"
                    }
                })
        }

        # Footer-Website mit URL verknüpfen
        if ($null -ne $FooterWebsite) {
            $FooterWebsite.Add_MouseLeftButtonDown({
                    try {
                        Start-Process "https://$($script:FooterWebseite)"
                    } catch {
                        Write-Log "Fehler beim Öffnen der URL: $($_)"
                    }
                })
        }

        # Navigation Buttons
        if ($null -ne $btnSingleUser) {
            $btnSingleUser.Add_Click({
                    try {
                        $script:mainTabControl.SelectedIndex = 0
                        Update-Status "Modus: $($script:TabNames.SingleUser)" "Info"
                    } catch {
                        Write-Log "Fehler bei der Navigation: $($_)"
                    }
                })
        }

        if ($null -ne $btnOU) {
            $btnOU.Add_Click({
                    try {
                        $script:mainTabControl.SelectedIndex = 1
                        Update-Status "Modus: $($script:TabNames.OUGroup)" "Info"
                    } catch {
                        Write-Log "Fehler bei der Navigation: $($_)"
                    }
                })
        }

        if ($null -ne $btnGroup) {
            $btnGroup.Add_Click({
                    try {
                        $script:mainTabControl.SelectedIndex = 1
                        Update-Status "Modus: $($script:TabNames.OUGroup)" "Info"
                    } catch {
                        Write-Log "Fehler bei der Navigation: $($_)"
                    }
                })
        }

        if ($null -ne $btnPolicies) {
            $btnPolicies.Add_Click({
                    try {
                        $script:mainTabControl.SelectedIndex = 2
                        Update-Status "Modus: $($script:TabNames.Policies)" "Info"

                        # Passwort-Richtlinien laden, falls DataGrid vorhanden
                        if ($null -ne $dgPasswordPolicies) {
                            Show-PasswordPolicies
                        }
                    } catch {
                        Write-Log "Fehler bei der Navigation: $($_)"
                    }
                })
        }

        if ($null -ne $btnFGPP) {
            $btnFGPP.Add_Click({
                    try {
                        $script:mainTabControl.SelectedIndex = 3
                        Update-Status "Modus: $($script:TabNames.FGPP)" "Info"

                        # FGPP-Richtlinien laden
                        Import-FGPPPolicies

                        # Gruppen in ComboBox laden
                        if ($null -ne $cmbFGPPGroups) {
                            $cmbFGPPGroups.Items.Clear()
                            $Groups = Get-ADGroup -Filter * -Properties Name | Sort-Object -Property Name
                            foreach ($Group in $Groups) {
                                $cmbFGPPGroups.Items.Add($Group.Name)
                            }
                        }
                    } catch {
                        Write-Log "Fehler bei der Navigation: $($_)"
                    }
                })
        }

        # Einzelne User Tab Event-Handler

        # Benutzersuche Button
        if ($null -ne $btnSearchUser) {
            $btnSearchUser.Add_Click({
                    try {
                        if ([string]::IsNullOrWhiteSpace($txtUsername.Text)) {
                            Update-Status "Bitte geben Sie einen Benutzernamen ein." "Warning"
                            return
                        }
                        $username = $txtUsername.Text
                        Update-Status "Suche nach Benutzer: $username..." "Info"

                        # Sichere Benutzerabfrage
                        $user = Get-ADUserSafe -Identity $username -Properties DisplayName, EmailAddress, SamAccountName, Description, Department, Enabled, LastLogonDate, LockedOut, PasswordExpired, PasswordLastSet, PasswordNeverExpires, CannotChangePassword

                        if ($null -eq $user) {
                            Update-Status "Benutzer '$username' nicht gefunden." "Error"
                            # Felder leeren
                            $txtUserDisplayName.Text = ""
                            $txtUserEmail.Text = ""
                            $txtSamAccountName.Text = ""
                            $txtUserDescription.Text = ""
                            $txtUserDepartment.Text = ""
                            $txtUserStatus.Text = ""
                            $txtUserLastLogon.Text = ""
                            $txtUserPwdExpiry.Text = ""
                            return
                        }

                        # GUI mit Benutzerdaten füllen
                        $txtUserDisplayName.Text = $user.DisplayName
                        $txtUserEmail.Text = $user.EmailAddress
                        $txtSamAccountName.Text = $user.SamAccountName
                        $txtUserDescription.Text = $user.Description
                        $txtUserDepartment.Text = $user.Department
                        $status = if ($user.Enabled) { "Aktiviert" } else { "Deaktiviert" }
                        if ($user.LockedOut) { $status += " (Gesperrt)" }
                        $txtUserStatus.Text = $status
                        $txtUserLastLogon.Text = if ($user.LastLogonDate) { $user.LastLogonDate.ToString("g") } else { "Unbekannt" }

                        # Passwortablauf berechnen
                        if ($user.PasswordNeverExpires) {
                            $txtUserPwdExpiry.Text = "Läuft nie ab"
                        } elseif ($user.PasswordExpired) {
                            $txtUserPwdExpiry.Text = "Abgelaufen"
                        } else {
                            $pwdLastSet = [DateTime]::FromFileTime($user.pwdLastSet)
                            $domainPolicy = Get-ADDefaultDomainPasswordPolicy
                            $maxPwdAge = $domainPolicy.MaxPasswordAge
                            $pwdExpiry = $pwdLastSet.Add($maxPwdAge)
                            $txtUserPwdExpiry.Text = $pwdExpiry.ToString("g")
                        }

                        # Checkboxen aktualisieren
                        $chkPasswordNeverExpires.IsChecked = $user.PasswordNeverExpires
                        $chkCannotChangePassword.IsChecked = $user.CannotChangePassword
                        $chkAccountEnabled.IsChecked = $user.Enabled
                        $chkMustChangePassword.IsChecked = $false # Standardmäßig zurücksetzen

                        Update-Status "Benutzer '$username' gefunden und Informationen geladen." "Success"

                    } catch {
                        $errorMsg = "Fehler bei der Benutzersuche: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Passwort zurücksetzen Button im Tab "Einzelne User"
        if ($null -ne $btnReset) {
            $btnReset.Add_Click({
                    try {
                        if ([string]::IsNullOrWhiteSpace($txtSamAccountName.Text)) {
                            Update-Status "Bitte suchen Sie zuerst einen Benutzer, bevor Sie eine Aktion ausführen." "Warning"
                            return
                        }

                        Reset-Password -Username $txtSamAccountName.Text -ExportReport
                    } catch {
                        $errorMsg = "Fehler beim Ausführen der Reset-Password Funktion: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Konto entsperren Button im Tab "Einzelne User"
        if ($null -ne $btnUnlock) {
            $btnUnlock.Add_Click({
                    try {
                        if ([string]::IsNullOrWhiteSpace($txtSamAccountName.Text)) {
                            Update-Status "Bitte suchen Sie zuerst einen Benutzer, bevor Sie eine Aktion ausführen." "Warning"
                            return
                        }

                        Unlock-Account -Username $txtSamAccountName.Text -Scope "Einzelner Benutzer"
                    } catch {
                        $errorMsg = "Fehler beim Ausführen der Unlock-Account Funktion: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Passwort-Optionen anwenden Button
        if ($null -ne $btnApplyOptions) {
            $btnApplyOptions.Add_Click({
                    try {
                        if ([string]::IsNullOrWhiteSpace($txtSamAccountName.Text)) {
                            Update-Status "Bitte suchen Sie zuerst einen Benutzer, bevor Sie eine Aktion ausführen." "Warning"
                            return
                        }

                        $samAccountName = $txtSamAccountName.Text

                        # Überprüfen, ob der Benutzer existiert
                        $user = Get-ADUser -Identity $samAccountName -ErrorAction SilentlyContinue

                        if ($null -eq $user) {
                            Update-Status "Benutzer $samAccountName nicht gefunden." "Error"
                            return
                        }

                        # Passwort-Optionen setzen
                        $params = @{
                            Identity              = $samAccountName
                            PasswordNeverExpires  = $chkPasswordNeverExpires.IsChecked
                            CannotChangePassword  = $chkCannotChangePassword.IsChecked
                            Enabled               = $chkAccountEnabled.IsChecked
                            ChangePasswordAtLogon = $chkMustChangePassword.IsChecked
                        }

                        Set-ADUser @params

                        Update-Status "Konto-Optionen für $samAccountName wurden angewendet." "Success"
                    } catch {
                        $errorMsg = "Fehler beim Anwenden der Konto-Optionen: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }


        # Zeige Passwort Checkbox
        if ($null -ne $chkShowPassword) {
            $chkShowPassword.Add_Click({
                    try {
                        # Create a visible TextBox for the password if it doesn't exist
                        if ($null -eq $script:visiblePasswordTextBox) {
                            # Find the parent Grid of the PasswordBox
                            $parentGrid = $txtGeneratedPassword.Parent
                            if ($null -ne $parentGrid) {
                                # Create the new TextBox
                                $script:visiblePasswordTextBox = New-Object System.Windows.Controls.TextBox
                                # Copy properties from the PasswordBox to make it look identical
                                $script:visiblePasswordTextBox.Height = $txtGeneratedPassword.Height
                                $script:visiblePasswordTextBox.Margin = $txtGeneratedPassword.Margin
                                $script:visiblePasswordTextBox.VerticalContentAlignment = 'Center'
                                # Set the Grid.Row attached property to match the PasswordBox
                                [System.Windows.Controls.Grid]::SetRow($script:visiblePasswordTextBox, [System.Windows.Controls.Grid]::GetRow($txtGeneratedPassword))
                                # Initially hide it
                                $script:visiblePasswordTextBox.Visibility = 'Collapsed'
                                # Add it to the same parent container
                                $parentGrid.Children.Add($script:visiblePasswordTextBox) | Out-Null
                            }
                        }

                        # Toggle visibility based on checkbox state
                        if ($chkShowPassword.IsChecked) {
                            # Show password: copy from PasswordBox to TextBox, then swap visibility
                            $script:visiblePasswordTextBox.Text = $txtGeneratedPassword.Password
                            $txtGeneratedPassword.Visibility = 'Collapsed'
                            $script:visiblePasswordTextBox.Visibility = 'Visible'
                            $script:visiblePasswordTextBox.Focus()
                        } else {
                            # Hide password: copy back from TextBox to PasswordBox, then swap visibility
                            $txtGeneratedPassword.Password = $script:visiblePasswordTextBox.Text
                            $script:visiblePasswordTextBox.Visibility = 'Collapsed'
                            $txtGeneratedPassword.Visibility = 'Visible'
                            $txtGeneratedPassword.Focus()
                        }
                    } catch {
                        Write-Log "Fehler beim Umschalten der Passwortanzeige: $($_)"
                    }
                })
        }

        # OU/Gruppe Tab Event-Handler

        # OU TreeView Event-Handler
        if ($null -ne $treeViewOUs) {
            $treeViewOUs.Add_SelectedItemChanged({
                    try {
                        $selectedItem = $treeViewOUs.SelectedItem
                        if ($null -ne $selectedItem) {
                            $selectedOU = $selectedItem.Tag
                            Update-Status "OU ausgewählt: $selectedOU" "Info"
                        }
                    } catch {
                        Write-Log "Fehler bei OU-Auswahl: $($_)"
                    }
                })
        }

        # Passwort zurücksetzen für OU Button
        if ($null -ne $btnResetOU) {
            $btnResetOU.Add_Click({
                    try {
                        $selectedItem = $treeViewOUs.SelectedItem
                        if ($null -eq $selectedItem) {
                            Update-Status "Bitte wählen Sie eine OU aus." "Warning"
                            return
                        }

                        $selectedOU = $selectedItem.Tag

                        $confirmation = [System.Windows.MessageBox]::Show(
                            "Möchten Sie wirklich die Passwörter für ALLE Benutzer in '$($selectedItem.Header)' zurücksetzen?",
                            "Passwörter zurücksetzen",
                            "YesNo",
                            "Warning"
                        )

                        if ($confirmation -eq "Yes") {
                            Reset-OUPasswords -OUPath $selectedOU
                        }
                    } catch {
                        $errorMsg = "Fehler beim Zurücksetzen der OU-Passwörter: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Konto entsperren für OU Button
        if ($null -ne $btnUnlockOU) {
            $btnUnlockOU.Add_Click({
                    try {
                        $selectedItem = $treeViewOUs.SelectedItem
                        if ($null -eq $selectedItem) {
                            Update-Status "Bitte wählen Sie eine OU aus." "Warning"
                            return
                        }

                        $selectedOU = $selectedItem.Tag

                        $confirmation = [System.Windows.MessageBox]::Show(
                            "Möchten Sie wirklich ALLE gesperrten Konten in '$($selectedItem.Header)' entsperren?",
                            "Konten entsperren",
                            "YesNo",
                            "Warning"
                        )

                        if ($confirmation -eq "Yes") {
                            Unlock-OUAccounts -OUPath $selectedOU
                        }
                    } catch {
                        $errorMsg = "Fehler beim Entsperren der OU-Konten: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Gruppen ComboBox Event-Handler
        if ($null -ne $cmbGroups) {
            $cmbGroups.Add_SelectionChanged({
                    try {
                        $selectedGroup = $cmbGroups.SelectedItem
                        if ([string]::IsNullOrWhiteSpace($selectedGroup)) {
                            return
                        }

                        Update-Status "Gruppe ausgewählt: $selectedGroup" "Info"

                        # Mitglieder auflisten
                        $lstGroupMembers.Items.Clear()
                        $members = Get-ADGroupMember -Identity $selectedGroup | Sort-Object -Property Name
                        foreach ($member in $members) {
                            if ($member.objectClass -eq "user") {
                                $lstGroupMembers.Items.Add($member.Name)
                            }
                        }
                    } catch {
                        Write-Log "Fehler beim Laden der Gruppenmitglieder: $($_)"
                    }
                })
        }

        # Passwort zurücksetzen für Gruppe Button
        if ($null -ne $btnResetGroup) {
            $btnResetGroup.Add_Click({
                    try {
                        $selectedGroup = $cmbGroups.SelectedItem
                        if ([string]::IsNullOrWhiteSpace($selectedGroup)) {
                            Update-Status "Bitte wählen Sie eine Gruppe aus." "Warning"
                            return
                        }

                        $confirmation = [System.Windows.MessageBox]::Show(
                            "Möchten Sie wirklich die Passwörter für ALLE Benutzer in der Gruppe '$selectedGroup' zurücksetzen?",
                            "Passwörter zurücksetzen",
                            "YesNo",
                            "Warning"
                        )

                        if ($confirmation -eq "Yes") {
                            Reset-GroupPasswords -GroupName $selectedGroup
                        }
                    } catch {
                        $errorMsg = "Fehler beim Zurücksetzen der Gruppen-Passwörter: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Konto entsperren für Gruppe Button
        if ($null -ne $btnUnlockGroup) {
            $btnUnlockGroup.Add_Click({
                    try {
                        $selectedGroup = $cmbGroups.SelectedItem
                        if ([string]::IsNullOrWhiteSpace($selectedGroup)) {
                            Update-Status "Bitte wählen Sie eine Gruppe aus." "Warning"
                            return
                        }

                        $confirmation = [System.Windows.MessageBox]::Show(
                            "Möchten Sie wirklich ALLE gesperrten Konten in der Gruppe '$selectedGroup' entsperren?",
                            "Konten entsperren",
                            "YesNo",
                            "Warning"
                        )

                        if ($confirmation -eq "Yes") {
                            Unlock-GroupAccounts -GroupName $selectedGroup
                        }
                    } catch {
                        $errorMsg = "Fehler beim Entsperren der Gruppen-Konten: $($_)"
                        Write-Log $errorMsg
                        Update-Status $errorMsg "Error"
                    }
                })
        }

        # Passwort-Richtlinien Tab Event-Handler
        if ($null -ne $btnRefreshPolicies) {
            $btnRefreshPolicies.Add_Click({
                    try {
                        Show-PasswordPolicies
                        Update-Status "Passwort-Richtlinien wurden aktualisiert." "Info"
                    } catch {
                        Write-Log "Fehler beim Aktualisieren der Passwort-Richtlinien: $($_)"
                    }
                })
        }

        # FGPP-Tab Event-Handler

        # DataGrid SelectionChanged Event-Handler
        if ($null -ne $dgFGPP) {
            $dgFGPP.Add_SelectionChanged({
                    dgFGPP_SelectionChanged $this $($_)
                })
        }

        # FGPP Bearbeiten Button
        if ($null -ne $btnEditFGPP) {
            $btnEditFGPP.Add_Click({
                    try {
                        if ($null -eq $dgFGPP.SelectedItem) {
                            Update-Status "Bitte wählen Sie eine FGPP aus." "Warning"
                            return
                        }

                        # GroupBox Header ändern
                        $groupBox = $Window.FindName("NewFGPPBox")
                        if ($null -ne $groupBox) {
                            $groupBox.Header = "FGPP bearbeiten"
                        }

                        # Erstellen-Button ausblenden, Speichern-Button einblenden
                        if ($null -ne $btnCreateFGPP) { $btnCreateFGPP.Visibility = "Collapsed" }
                        if ($null -ne $btnSaveFGPP) { $btnSaveFGPP.Visibility = "Visible" }
                    } catch {
                        Write-Log "Fehler beim Vorbereiten der FGPP-Bearbeitung: $($_)"
                    }
                })
        }

        # FGPP Löschen Button
        if ($null -ne $btnDeleteFGPP) {
            $btnDeleteFGPP.Add_Click({
                    try {
                        Remove-FGPP
                    } catch {
                        Write-Log "Fehler beim Löschen der FGPP: $($_)"
                    }
                })
        }

        # FGPP Aktualisieren Button
        if ($null -ne $btnRefreshFGPP) {
            $btnRefreshFGPP.Add_Click({
                    try {
                        Import-FGPPPolicies
                        Update-Status "FGPP-Richtlinien wurden aktualisiert." "Info"
                    } catch {
                        Write-Log "Fehler beim Aktualisieren der FGPP-Richtlinien: $($_)"
                    }
                })
        }

        # FGPP Erstellen Button
        if ($null -ne $btnCreateFGPP) {
            $btnCreateFGPP.Add_Click({
                    try {
                        New-CreateFGPP
                    } catch {
                        Write-Log "Fehler beim Erstellen der FGPP: $($_)"
                    }
                })
        }

        # FGPP Speichern Button
        if ($null -ne $btnSaveFGPP) {
            $btnSaveFGPP.Add_Click({
                    try {
                        Edit-FGPP

                        # GroupBox Header zurücksetzen
                        $groupBox = $Window.FindName("NewFGPPBox")
                        if ($null -ne $groupBox) {
                            $groupBox.Header = "Neue FGPP erstellen"
                        }

                        # Buttons zurücksetzen
                        if ($null -ne $btnCreateFGPP) { $btnCreateFGPP.Visibility = "Visible" }
                        if ($null -ne $btnSaveFGPP) { $btnSaveFGPP.Visibility = "Collapsed" }
                    } catch {
                        Write-Log "Fehler beim Speichern der FGPP: $($_)"
                    }
                })
        }

        # FGPP Abbrechen Button
        if ($null -ne $btnCancelFGPP) {
            $btnCancelFGPP.Add_Click({
                    try {
                        # Felder zurücksetzen
                        $txtFGPPName.Text = ""
                        $txtFGPPPrecedence.Text = ""
                        $txtFGPPMinLength.Text = ""
                        $txtFGPPHistory.Text = ""
                        $txtFGPPMinAge.Text = ""
                        $txtFGPPMaxAge.Text = ""
                        $chkFGPPComplexity.IsChecked = $false
                        $chkFGPPReversibleEncryption.IsChecked = $false
                        $lstFGPPAppliedGroups.Items.Clear()

                        # GroupBox Header zurücksetzen
                        $groupBox = $Window.FindName("NewFGPPBox")
                        if ($null -ne $groupBox) {
                            $groupBox.Header = "Neue FGPP erstellen"
                        }

                        # Buttons zurücksetzen
                        if ($null -ne $btnCreateFGPP) { $btnCreateFGPP.Visibility = "Visible" }
                        if ($null -ne $btnSaveFGPP) { $btnSaveFGPP.Visibility = "Collapsed" }

                        Update-Status "FGPP-Bearbeitung abgebrochen." "Info"
                    } catch {
                        Write-Log "Fehler beim Abbrechen der FGPP-Bearbeitung: $($_)"
                    }
                })
        }

        # Gruppe hinzufügen Button
        if ($null -ne $btnAddGroup) {
            $btnAddGroup.Add_Click({
                    try {
                        Add-GroupToFGPP
                    } catch {
                        Write-Log "Fehler beim Hinzufügen der Gruppe: $($_)"
                    }
                })
        }

        # Gruppe entfernen Button
        if ($null -ne $btnRemoveGroup) {
            $btnRemoveGroup.Add_Click({
                    try {
                        Remove-GroupFromFGPP
                    } catch {
                        Write-Log "Fehler beim Entfernen der Gruppe: $($_)"
                    }
                })
        }

        Write-Log "Event-Handler erfolgreich registriert."
    } catch {
        $errorMsg = "Fehler beim Registrieren der Event-Handler: $($_)"
        Write-Log $errorMsg
    }
}

# Verbesserte GUI-Initialisierungsfunktion mit strukturierter Fehlerbehandlung
function Initialize-GUI {
    try {
        Write-Log "Starte GUI-Initialisierung" -Level "Info"

        $xamlDocument = $null
        $successfulPath = ""

        # 1. Zuerst versuchen, den bereits im Skript definierten XAML-Content zu verwenden
        if (-not [string]::IsNullOrWhiteSpace($script:XamlContent)) {
            try {
                Write-Log "Verwende im Skript definierten XAML-Content" -Level "Info"

                # XAML-Content bereinigen
                $cleanedXaml = $script:XamlContent -replace '^\s*<\?xml.*?\?>', ''
                $cleanedXaml = $cleanedXaml.Trim([char]0xFEFF)

                # XML-Dokument erstellen
                $xamlDocument = New-Object System.Xml.XmlDocument
                $xamlDocument.LoadXml($cleanedXaml)
                $successfulPath = "Embedded XAML Content"

                Write-Log "XAML-Content aus Skript erfolgreich geladen" -Level "Info"
            } catch {
                Write-Log "Fehler beim Laden des internen XAML-Contents: $($_)" -Level "Warning"
            }
        }

        # 2. XAML in UI umwandeln
        try {
            Write-Log "Starte XAML-zu-UI Konvertierung" -Level "Info"

            # Namespace-Manager für X:Name-Attribute einrichten
            $xamlNamespace = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
            $xamlNamespace.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")

            # XAML für XamlReader vorbereiten (X:Name => Name)
            $tempXaml = $xamlDocument.OuterXml
            $tempXaml = $tempXaml -replace "x:Name", "Name"
            $tempXaml = $tempXaml -replace "x:Class", "Class" # Häufige Fehlerquelle

            # XmlNodeReader erstellen
            $reader = New-Object System.Xml.XmlNodeReader([xml]$tempXaml)

            # UI laden mit detaillierter Fehlerbehandlung
            try {
                Write-Log "Lade UI mit XamlReader" -Level "Info"
                $script:Window = [Windows.Markup.XamlReader]::Load($reader)

                # Validierung des geladenen Fensters
                if ($null -eq $script:Window) {
                    throw "XamlReader.Load hat ein NULL-Objekt zurückgegeben"
                }

                # Überprüfen des Objekttyps
                if ($script:Window -isnot [System.Windows.Window]) {
                    $actualType = $script:Window.GetType().FullName
                    Write-Log "WARNUNG: XamlReader.Load hat kein Window-Objekt zurückgegeben, sondern: $actualType" -Level "Warning"

                    # Versuch, das Problem zu beheben, wenn kein Window-Objekt zurückgegeben wurde
                    if ($script:Window -is [System.String]) {
                        Write-Log "KRITISCH: Window ist ein String-Objekt - versuche Neukonvertierung" -Level "Error"
                        # Neuversuch mit explizitem Window-Casting
                        try {
                            $reader = New-Object System.Xml.XmlNodeReader([xml]$tempXaml)
                            $script:Window = [System.Windows.Window][Windows.Markup.XamlReader]::Load($reader)
                        } catch {
                            Write-Log "Neukonvertierung fehlgeschlagen: $($_)" -Level "Error"
                            throw "Konnte kein gültiges Window-Objekt erstellen. XAML fehlerhaft oder nicht kompatibel."
                        }
                    }

                    # Erneute Typprüfung nach Korrekturversuch
                    if ($script:Window -isnot [System.Windows.Window]) {
                        throw "XamlReader.Load hat kein gültiges Window-Objekt zurückgegeben, sondern: $($script:Window.GetType().FullName)"
                    }
                }

                Write-Log "Windows-UI erfolgreich geladen: $($script:Window.GetType().FullName)" -Level "Info"
            } catch {
                # UI-Ladefehler mit detaillierter Diagnose
                $errorMsg = "Kritischer Fehler beim Laden des UI über XamlReader: $($_)"
                Write-Log $errorMsg -Level "Error"

                # Detaillierte Fehlerinformationen extrahieren
                if ($_.Exception.InnerException) {
                    Write-Log "Inner Exception: $($_.Exception.InnerException.Message)" -Level "Error"

                    # Bei XAML-Parsing-Fehlern oft hilfreich zu sehen, wo genau der Fehler ist
                    if ($_.Exception.InnerException.InnerException) {
                        Write-Log "Detaillierter Fehler: $($_.Exception.InnerException.InnerException.Message)" -Level "Error"
                    }
                }

                # Fallback zu einer einfachen MessageBox wenn keine GUI erstellt werden kann
                [System.Windows.MessageBox]::Show(
                    "Fehler beim Laden der Benutzeroberfläche: $($_)`n`nDas Programm wird beendet.",
                    "Kritischer Fehler",
                    "OK",
                    "Error"
                )

                throw $errorMsg
            }
        } catch {
            $errorMsg = "Fehler bei der XAML-zu-UI Konvertierung: $($_)"
            Write-Log $errorMsg -Level "Error"
            throw $errorMsg
        }

        # 3. UI-Elemente per Name binden mit intelligenter Fehlerbehandlung
        try {
            # Alle Elemente mit Name-Attribut extrahieren
            $namedElements = $xamlDocument.SelectNodes("//*[@*[contains(translate(local-name(),'x','X'),'Name')]]", $xamlNamespace)
            Write-Log "Gefundene benannte UI-Elemente: $($namedElements.Count)" -Level "Info"

            # Zähler für Diagnose
            $boundElements = 0
            $failedElements = 0

            # Sicherstellen, dass Window keine String oder ungültiges Objekt ist
            if (-not ($script:Window -is [System.Windows.Window])) {
                Write-Log "KRITISCH: Window ist kein gültiges Window-Objekt - UI-Elemente können nicht gebunden werden" -Level "Error"
                throw "Window-Objekt ist ungültig: $($script:Window.GetType().FullName)"
            }

            foreach ($element in $namedElements) {
                $elementName = $element.Name
                # Zuerst normales Name-Attribut prüfen
                $originalName = $element.GetAttribute("Name")

                # Falls leer, versuche x:Name Attribut
                if ([string]::IsNullOrWhiteSpace($originalName)) {
                    $originalName = $element.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")

                    # Validierung des Elementnamens
                    if ([string]::IsNullOrWhiteSpace($originalName)) {
                        Write-Log "Element ohne gültigen Namen gefunden: $elementName - überspringe" -Level "Warning"
                        continue
                    }
                }

                try {
                    # Element im geladenen UI finden
                    $uiElement = $script:Window.FindName($originalName)

                    # Validierung des UI-Elements
                    if ($null -ne $uiElement) {
                        # Element an Skript-Variable binden
                        Set-Variable -Name $originalName -Value $uiElement -Scope Script
                        Write-Log "UI-Element erfolgreich gebunden: $originalName" -Level "Debug"
                        $boundElements++
                    } else {
                        Write-Log "Konnte UI-Element nicht finden: $originalName" -Level "Warning"
                        $failedElements++
                    }
                } catch {
                    Write-Log "Fehler beim Binden des UI-Elements $originalName`: $($_)" -Level "Warning"
                    $failedElements++
                }
            }

            Write-Log "UI-Elemente Binding abgeschlossen: $boundElements erfolgreich, $failedElements fehlgeschlagen" -Level "Info"

            # Kritische UI-Elemente prüfen
            $criticalElements = @("mainTabControl", "HeaderAppName", "FooterText")
            foreach ($elementName in $criticalElements) {
                $element = Get-Variable -Name $elementName -Scope Script -ErrorAction SilentlyContinue
                if ($null -eq $element -or $null -eq $element.Value) {
                    Write-Log "Kritisches UI-Element nicht gefunden: $elementName" -Level "Warning"
                }
            }
        } catch {
            $errorMsg = "Fehler beim Binden der UI-Elemente: $($_)"
            Write-Log $errorMsg -Level "Error"
            # Nicht kritisch, weitermachen
        }

        # 4. UI-Eigenschaften setzen mit robuster Fehlerbehandlung
        try {
            Write-Log "Setze UI-Eigenschaften" -Level "Info"

            # App-Name im Header setzen
            if ($null -ne $HeaderAppName) {
                try {
                    $HeaderAppName.Text = $script:AppName
                    Write-Log "App-Name im Header gesetzt: $script:AppName" -Level "Debug"
                } catch {
                    Write-Log "Fehler beim Setzen des App-Names: $($_)" -Level "Warning"
                }
            } else {
                Write-Log "HeaderAppName Element nicht gefunden" -Level "Warning"
            }

            # Footer-Texte setzen
            if ($null -ne $FooterText) {
                try {
                    $FooterText.Text = $script:Config.FooterText
                    Write-Log "Footer-Text gesetzt" -Level "Debug"
                } catch {
                    Write-Log "Fehler beim Setzen des Footer-Textes: $($_)" -Level "Warning"
                }
            }

            if ($null -ne $FooterWebsite) {
                try {
                    $FooterWebsite.Text = $script:Config.FooterWebseite
                    Write-Log "Footer-Website gesetzt" -Level "Debug"
                } catch {
                    Write-Log "Fehler beim Setzen der Footer-Website: $($_)" -Level "Warning"
                }
            }

            # ThemeColor setzen mit mehreren Fallback-Optionen
            $HeaderBackground = $script:Window.FindName("HeaderBackground")
            if ($null -ne $HeaderBackground) {
                try {
                    # 1. Versuch: Mit ColorConverter
                    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($script:ThemeColor)
                    $brush = New-Object System.Windows.Media.SolidColorBrush($color)
                    $HeaderBackground.Fill = $brush
                    Write-Log "ThemeColor über ColorConverter gesetzt: $script:ThemeColor" -Level "Debug"
                } catch {
                    Write-Log "Nicht-kritischer Fehler beim Setzen der ThemeColor: $($_)" -Level "Warning"
                }
            }

            Write-Log "UI-Eigenschaften erfolgreich gesetzt" -Level "Info"
        } catch {
            Write-Log "Nicht-kritischer Fehler beim Setzen der UI-Eigenschaften: $($_)" -Level "Warning"
            # Nicht kritisch, weitermachen
        }

        # 5. Erweiterte UI-Diagnostik vor Anzeige
        try {
            Write-Log "Starte erweiterte UI-Diagnostik" -Level "Info"

            # Prüfe, ob Window-Objekt gültig ist
            if ($null -eq $script:Window) {
                Write-Log "KRITISCH: Window-Objekt ist NULL" -Level "Error"
            } elseif (-not ($script:Window -is [System.Windows.Window])) {
                Write-Log "KRITISCH: Window-Objekt ist kein gültiges Window: $($script:Window.GetType().FullName)" -Level "Error"
            } else {
                # Prüfe Dispatcher
                if ($null -ne $script:Window.Dispatcher) {
                    $isUIThread = $script:Window.Dispatcher.CheckAccess()
                    $dispatcherStatus = if ($script:Window.Dispatcher.HasShutdownStarted) { 'Herunterfahren begonnen' } else { 'Aktiv' }
                    Write-Log "UI-Dispatcher ist aktiv: $dispatcherStatus" -Level "Info"
                }

                # Prüfe SynchronizationContext
                $syncContext = [System.Threading.SynchronizationContext]::Current
                if ($null -eq $syncContext) {
                    Write-Log "Warnung: SynchronizationContext ist NULL" -Level "Warning"
                }

                # Prüfe Window Eigenschaften - sicher prüfen, ob Content ein einzelnes Element ist
                try {
                    if ($null -ne $script:Window.Content) {
                        $contentType = $script:Window.Content.GetType().FullName
                        Write-Log "Window.Content Typ: $contentType" -Level "Info"
                        $visualChildren = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($script:Window.Content)
                        Write-Log "Visuelle Kinder des Root-Elements: $visualChildren" -Level "Info"
                    } else {
                        Write-Log "Window.Content ist NULL" -Level "Warning"
                    }
                } catch {
                    Write-Log "Fehler bei UI-Diagnose: $($_)" -Level "Error"
                }
            }
        } catch {
            Write-Log "Nicht-kritischer Fehler bei UI-Diagnose: $($_)" -Level "Warning"
            # Nicht kritisch, weitermachen
        }

        # 6. Event-Handler registrieren
        try {
            Write-Log "Registriere Event-Handler" -Level "Info"
            Register-EventHandlers
            Write-Log "Event-Handler registriert" -Level "Info"
        } catch {
            Write-Log "Fehler beim Registrieren der Event-Handler: $($_)" -Level "Error"
            # Nicht kritisch, weitermachen
        }

        # 7. Tabs initialisieren
        try {
            Write-Log "Initialisiere Tabs" -Level "Info"
            Initialize-TabPages
            Write-Log "Tabs initialisiert" -Level "Info"
        } catch {
            Write-Log "Fehler beim Initialisieren der Tabs: $($_)" -Level "Error"
            # Nicht kritisch, weitermachen
        }

        # 8. Window.Loaded Event registrieren
        try {
            if ($script:Window -is [System.Windows.Window]) {
                $script:Window.Add_Loaded({
                        try {
                            Write-Log "Fenster wurde geladen" -Level "Info"
                            # UI-Elemente nach dem Laden aktualisieren
                            Update-ADConnectionStatusInGUI
                        } catch {
                            Write-Log "Fehler im Loaded-Event: $($_)" -Level "Error"
                        }
                    })
                Write-Log "Window.Loaded Event registriert" -Level "Info"
            } else {
                Write-Log "Konnte Window.Loaded Event nicht registrieren: Window ist kein gültiges Window-Objekt" -Level "Error"
            }
        } catch {
            Write-Log "Fehler beim Registrieren des Window.Loaded Events: $($_)" -Level "Error"
            # Nicht kritisch, weitermachen
        }

        # 9. Fenster anzeigen
        try {
            Write-Log "Zeige GUI-Fenster an" -Level "Info"
            if ($script:Window -is [System.Windows.Window]) {
                # Explizite Typprüfung vor dem Anzeigen
                $windowObj = [System.Windows.Window]$script:Window
                $windowObj.ShowDialog() | Out-Null
                Write-Log "GUI-Fenster wurde erfolgreich angezeigt" -Level "Info"
            } else {
                $errorMsg = "Fehler beim Anzeigen des GUI-Fensters: Window ist kein gültiges Window-Objekt: $($script:Window.GetType().FullName)"
                Write-Log $errorMsg -Level "Error"
                throw $errorMsg
            }
        } catch {
            $errorMsg = "Fehler beim Anzeigen des Fensters: $($_)"
            Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"

            # Versuche trotzdem eine Meldung anzuzeigen
            try {
                [System.Windows.MessageBox]::Show(
                    "Fehler beim Anzeigen des Hauptfensters: $($_)",
                    "Kritischer Fehler",
                    "OK",
                    "Error"
                )
            } catch {
                Write-Host "KRITISCHER FEHLER: Konnte weder GUI noch Fehlermeldung anzeigen: $($_)" -ForegroundColor Red
            }

            throw $errorMsg
        }
    } catch {
        $errorMessage = "Kritischer Fehler beim Initialisieren der GUI: $($_)"
        Write-GuaranteedDebug -Message $errorMessage -Level "ERROR"

        # Versuche eine MessageBox anzuzeigen
        try {
            [System.Windows.MessageBox]::Show(
                "Ein kritischer Fehler ist aufgetreten: $($_)",
                "Fehler beim Starten der Anwendung",
                "OK",
                "Error"
            )
        } catch {
            Write-Host "KRITISCHER FEHLER: $errorMessage" -ForegroundColor Red
        }

        throw $errorMessage
    }
}

# Hauptprogramm
try {
    # Starte das Programm
    Write-Log "Programmstart: $script:AppName"
    Initialize-GUI
} catch {
    $errorMsg = "Kritischer Fehler beim Starten der Anwendung: $($_)"
    Write-Log $errorMsg

    try {
        [System.Windows.MessageBox]::Show($errorMsg, "Kritischer Fehler", "OK", "Error")
    } catch {
        Write-Error "Konnte MessageBox nicht anzeigen: $($_)"
    }
}
# NULL-PROTECTION: Funktion zur Prüfung und sicheren Behandlung von NULL-Objekten
function Test-NullObject {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Object,
        [string]$ObjectName = "Unbenanntes Objekt",
        [string]$DefaultValue = $null,
        [switch]$ReturnDefaultOnNull = $false,
        [switch]$LogError = $true
    )

    try {
        if ($null -eq $Object) {
            if ($LogError) {
                # Direkter Write-Host ohne Try-Catch für unmittelbare Sichtbarkeit
                Write-Host "NULL-OBJEKT ERKANNT: $ObjectName ist NULL" -ForegroundColor Red

                # Callstack für Debug-Information zur Fehlerquelle
                $callStack = Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 3
                Write-Information -MessageData "Aufgerufen von:" -InformationAction Continue
                foreach ($call in $callStack) {
                    Write-Host "  - $($call.Command) in $($call.ScriptName):$($call.ScriptLineNumber)" -ForegroundColor DarkRed
                }

                # In Logdatei schreiben (direkt, ohne andere Funktionen)
                try {
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                    $logEntry = "[$timestamp] [NULL-ERROR] $ObjectName ist NULL. Aufruf aus: $($callStack[0].Command):$($callStack[0].ScriptLineNumber)"
                    $logEntry | Out-File -FilePath "$env:TEMP\easyPASSWORD_NULL_errors.log" -Append -Encoding utf8
                } catch {
                    # Silent catch - absoluter Fallback
                }
            }

            if ($ReturnDefaultOnNull) {
                return $DefaultValue
            }

            return $false
        }

        return $true
    } catch {
        # Absoluter Fallback bei Fehler in der Null-Prüfung selbst
        try {
            Write-Information -MessageData "KRITISCHER FEHLER in NULL-Prüfung: $($_.Exception.Message)" -InformationAction Continue
            return $false
        } catch {
            # Absoluter stiller Fallback
            return $false
        }
    }
}

# Funktion zur sicheren Objektzuweisung mit NULL-Schutz
function Get-SafeObject {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Object,
        [string]$ObjectName = "Unbenanntes Objekt",
        [object]$DefaultValue = $null
    )

    try {
        if (Test-NullObject -Object $Object -ObjectName $ObjectName -LogError $true) {
            return $Object
        } else {
            return $DefaultValue
        }
    } catch {
        try {
            Write-Information -MessageData "KRITISCHER FEHLER in Get-SafeObject für $ObjectName`: $($_.Exception.Message)" -InformationAction Continue
            return $DefaultValue
        } catch {
            # Absoluter stiller Fallback
            return $DefaultValue
        }
    }
}

# Debug-Aufzeichnung mit NULL-Überwachung
function Start-NullCheckMonitoring {
    # Versuche alle globalen und Skript-Variablen zu überwachen
    try {
        $variables = Get-Variable -Scope Script

        Write-GuaranteedDebug -Message "NULL-ÜBERWACHUNG GESTARTET. Überwache $($variables.Count) Skript-Variablen." -Level "INFO"

        # Kritische Variablen separat prüfen und protokollieren
        $criticalVariables = @(
            "script:Config",
            "script:AppName",
            "script:ThemeColor",
            "script:LogFile",
            "script:Window",
            "script:MainTabControl",
            "script:HeaderAppName",
            "script:FooterText"
        )

        $nullCount = 0
        foreach ($varName in $criticalVariables) {
            $varPath = $varName -replace "script:", ""
            $var = Get-Variable -Name $varPath -Scope Script -ErrorAction SilentlyContinue

            if ($null -eq $var -or $null -eq $var.Value) {
                $nullCount++
                Write-GuaranteedDebug -Message "KRITISCHE NULL-VARIABLE: $varName ist NULL" -Level "ERROR"
            } else {
                Write-GuaranteedDebug -Message "Variable $varName = $($var.Value)" -Level "DEBUG"
            }
        }

        # Überprüfung des GUI-Fensters und wichtiger Steuerelemente
        if ($null -ne $script:Window) {
            Write-GuaranteedDebug -Message "GUI-Fenster geladen: $($script:Window.GetType().FullName)" -Level "INFO"

            # Liste aller Namen im Window ausgeben
            $foundElements = 0
            $nullElements = 0

            # Funktionalen Tab-Control finden
            if ($null -ne $script:mainTabControl) {
                Write-GuaranteedDebug -Message "Tab-Control gefunden mit $($script:mainTabControl.Items.Count) Tabs" -Level "INFO"
            } else {
                Write-GuaranteedDebug -Message "KRITISCH: Tab-Control ist NULL" -Level "ERROR"
                $nullElements++
            }

            # Wichtige Headers und Footer prüfen
            $headerFooterElements = @(
                "HeaderAppName",
                "FooterText",
                "FooterWebsite"
            )

            foreach ($elementName in $headerFooterElements) {
                $element = Get-Variable -Name $elementName -Scope Script -ErrorAction SilentlyContinue

                if ($null -eq $element -or $null -eq $element.Value) {
                    Write-GuaranteedDebug -Message "KRITISCH: GUI-Element $elementName ist NULL" -Level "ERROR"
                    $nullElements++
                } else {
                    $foundElements++
                    Write-GuaranteedDebug -Message "GUI-Element $elementName gefunden" -Level "DEBUG"
                }
            }

            Write-GuaranteedDebug -Message "GUI-Elemente: $foundElements gefunden, $nullElements NULL-Elemente" -Level "INFO"
        } else {
            Write-GuaranteedDebug -Message "KRITISCH: GUI-Fenster ist NULL" -Level "ERROR"
            $nullCount++
        }

        Write-GuaranteedDebug -Message "NULL-Check abgeschlossen: $nullCount kritische NULL-Variablen gefunden" -Level "INFO"

        return $nullCount
    } catch {
        Write-GuaranteedDebug -Message "FEHLER bei NULL-Überwachung: $($_.Exception.Message)" -Level "ERROR"
        return -1
    }
}

# Null-Check nach dem Laden des Fensters
function Register-WindowLoadedEvent {
    if ($null -ne $script:Window) {
        try {
            $script:Window.Add_Loaded({
                    try {
                        Write-GuaranteedDebug -Message "GUI-Fenster wurde geladen - führe NULL-Checks durch" -Level "INFO"
                        # Start-NullCheckMonitoring
                    } catch {
                        Write-GuaranteedDebug -Message "Fehler im Window.Loaded Event: $($_.Exception.Message)" -Level "ERROR"
                    }
                })

            Write-GuaranteedDebug -Message "Window.Loaded Event wurde erfolgreich registriert" -Level "INFO"
        } catch {
            Write-GuaranteedDebug -Message "Fehler beim Registrieren des Window.Loaded Events: $($_.Exception.Message)" -Level "ERROR"
        }
    } else {
        Write-GuaranteedDebug -Message "KRITISCH: Window-Variable ist NULL, kann Loaded-Event nicht registrieren" -Level "ERROR"
    }
}

# 2. XAML-Inhalt aus eingebettetem Inhalt verwenden
$xamlContent = $script:XamlContent

if ([string]::IsNullOrWhiteSpace($xamlContent)) {
    Write-GuaranteedDebug -Message "KRITISCH: Eingebetteter XAML-Inhalt ist leer" -Level "ERROR"
    return $null
}

# 3. Bereinigung und Vorbereitung für Parser
$xamlContent = $xamlContent -replace '^\s*<\?xml.*?\?>', ''  # XML-Deklaration entfernen
$xamlContent = $xamlContent.Trim([char]0xFEFF)  # BOM entfernen

# 4. Konvertierung zu XML
try {
    Write-GuaranteedDebug -Message "Konvertiere XAML zu XML-Objekt" -Level "INFO"
    [xml]$xamlDocument = $xamlContent

    if ($null -eq $xamlDocument) {
        Write-GuaranteedDebug -Message "KRITISCH: XAML-Konvertierung ergab NULL" -Level "ERROR"
        return $null
    }

    # 5. XamlReader erstellen
    Write-GuaranteedDebug -Message "Erstelle XMLNodeReader" -Level "INFO"
    $tempXaml = $xamlDocument.OuterXml
    $tempXaml = $tempXaml -replace "x:Name", "Name"
    $tempXaml = $tempXaml -replace "x:Class", "Class"

    $reader = New-Object System.Xml.XmlNodeReader([xml]$tempXaml)

    if ($null -eq $reader) {
        Write-GuaranteedDebug -Message "KRITISCH: XMLNodeReader ist NULL" -Level "ERROR"
        return $null
    }

    # 6. UI laden
    $window = [Windows.Markup.XamlReader]::Load($reader)

    if ($null -eq $window) {
        Write-GuaranteedDebug -Message "KRITISCH: XamlReader.Load hat NULL zurückgegeben" -Level "ERROR"
        return $null
    }

    # Write-GuaranteedDebug -Message "XAML erfolgreich geladen: $($window.GetType().FullName)" -Level "INFO"
    return $window
} catch {
    Write-GuaranteedDebug -Message "Fehler beim Verarbeiten der XAML-Datei: $($_.Exception.Message)" -Level "ERROR"

    if ($_.Exception.InnerException) {
        Write-GuaranteedDebug -Message "Inner Exception: $($_.Exception.InnerException.Message)" -Level "ERROR"
    }

    return $null
}

# Führe zusätzlichen Null-Check direkt nach dem Start durch
# Start-NullCheckMonitoring

# Finale WindowsFormHost-Diagnose für tiefergehende UI-Probleme
function Start-UIDeepDiagnostics {
    try {
        Write-GuaranteedDebug -Message "Starte erweiterte UI-Diagnostik" -Level "INFO"

        # Überprüfung der UI-Thread-Synchronisierung
        $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
        if ($null -eq $dispatcher) {
            Write-GuaranteedDebug -Message "KRITISCH: UI-Dispatcher ist NULL" -Level "ERROR"
        } else {
            Write-GuaranteedDebug -Message "UI-Dispatcher ist aktiv: $($dispatcher.Thread.ManagedThreadId)" -Level "INFO"
        }

        # Überprüfung des SynchronizationContext
        $syncContext = [System.Threading.SynchronizationContext]::Current
        if ($null -eq $syncContext) {
            Write-GuaranteedDebug -Message "Warnung: SynchronizationContext ist NULL" -Level "WARNING"
        } else {
            Write-GuaranteedDebug -Message "SynchronizationContext ist vorhanden: $($syncContext.GetType().FullName)" -Level "INFO"
        }

        # Überprüfung der visuellen Hierarchie des Fensters
        if ($null -ne $script:Window) {
            $visualChildren = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($script:Window)
            Write-GuaranteedDebug -Message "Visuelle Kinder des Hauptfensters: $visualChildren" -Level "INFO"

            # Prüfung des MainTabControl
            if ($null -ne $script:mainTabControl) {
                $tabItems = $script:mainTabControl.Items.Count
                Write-GuaranteedDebug -Message "TabControl enthält $tabItems TabItems" -Level "INFO"

                # Validierung der einzelnen Tabs
                for ($i = 0; $i -lt $tabItems; $i++) {
                    try {
                        $tab = $script:mainTabControl.Items[$i]
                        $tabHeader = if ($null -ne $tab.Header) { $tab.Header.ToString() } else { "Unbekannt" }
                        Write-GuaranteedDebug -Message "Tab Header=$tabHeader, IsVisible=$($tab.IsVisible)" -Level "DEBUG"
                    } catch {
                        Write-GuaranteedDebug -Message "Fehler beim Zugriff auf Tab $($_.Exception.Message)" -Level "ERROR"
                    }
                }
            } else {
                Write-GuaranteedDebug -Message "KRITISCH: MainTabControl ist NULL" -Level "ERROR"
            }
        } else {
            Write-GuaranteedDebug -Message "KRITISCH: Window ist NULL, keine UI-Hierarchie-Diagnose möglich" -Level "ERROR"
        }

        Write-GuaranteedDebug -Message "UI-Diagnose abgeschlossen" -Level "INFO"
    } catch {
        Write-GuaranteedDebug -Message "Fehler bei UI-Diagnose: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Funktion zum Laden von XAML aus String-Inhalt
function Import-XamlFromContent {
    param (
        [Parameter(Mandatory = $true)]
        [string]$XamlContent
    )

    try {
        Write-GuaranteedDebug -Message "Sichere XAML-Ladung: " -Level "INFO"

        if ([string]::IsNullOrWhiteSpace($XamlContent)) {
            throw "XAML-Inhalt ist leer oder NULL"
        }

        # Write-GuaranteedDebug -Message "Konvertiere XAML zu XML-Objekt" -Level "INFO"
        [xml]$xamlDocument = $XamlContent

        # Write-GuaranteedDebug -Message "Erstelle XMLNodeReader" -Level "INFO"
        $reader = New-Object System.Xml.XmlNodeReader($xamlDocument)

        # Write-GuaranteedDebug -Message "Lade UI mit XamlReader" -Level "INFO"
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Write-GuaranteedDebug -Message "XAML erfolgreich geladen: $($window.GetType().FullName)" -Level "INFO"

        return $window
    } catch {
        $errorMsg = "Fehler beim Laden des XAML-Inhalts: $($_.Exception.Message)"
        Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"
        throw $errorMsg
    }
}

# Verbesserte sichere GUI-Initialisierungsfunktion mit expliziter Typprüfung
function Initialize-GUI-Safe {
    try {
        Write-GuaranteedDebug -Message "Starte sichere GUI-Initialisierung" -Level "INFO"

        # Verwende direkt das eingebettete XAML aus $script:XamlContent
        $window = Import-XamlFromContent -XamlContent $script:XamlContent

        if ($null -eq $window) {
            throw "Die GUI konnte nicht initialisiert werden. XAML-Ladung fehlgeschlagen."
        }

        # WICHTIG: Explizite Typprüfung durchführen
        if (-not ($window -is [System.Windows.Window])) {
            $actualType = $window.GetType().FullName
            Write-GuaranteedDebug -Message "KRITISCH: Geladenes Window-Objekt hat falschen Typ: $actualType" -Level "ERROR"

            # Versuche einen zweiten Ansatz mit eingebettetem Inhalt
            try {
                Write-GuaranteedDebug -Message "Versuche XAML-Ladung mit alternativer Methode" -Level "WARNING"
                [xml]$xamlContent = $script:XamlContent
                $xamlContent = $xamlContent -replace 'x:Class=".*?"', '' -replace 'mc:Ignorable="d"', ''
                $reader = New-Object System.Xml.XmlNodeReader($xamlContent)
                $window = [System.Windows.Markup.XamlReader]::Load($reader)

                # Erneute Typprüfung
                if (-not ($window -is [System.Windows.Window])) {
                    throw "XAML konnte nicht als gültiges Window-Objekt geladen werden"
                }
            } catch {
                # Erstelle ein einfaches Minimal-Window als absoluten Fallback
                Write-GuaranteedDebug -Message "Erstelle einfaches Fallback-Fenster" -Level "ERROR"
                $window = New-Object System.Windows.Window
                $window.Title = "easyPASSWORDRESET - NOTFALLMODUS"
                $window.Width = 800
                $window.Height = 450

                $grid = New-Object System.Windows.Controls.Grid
                $window.Content = $grid

                $textBlock = New-Object System.Windows.Controls.TextBlock
                $textBlock.Text = "KRITISCHER FEHLER: Die Benutzeroberfläche konnte nicht geladen werden."
                $textBlock.FontSize = 18
                $textBlock.Foreground = "Red"
                $textBlock.HorizontalAlignment = "Center"
                $textBlock.VerticalAlignment = "Center"
                $textBlock.TextWrapping = "Wrap"
                $textBlock.TextAlignment = "Center"

                $grid.Children.Add($textBlock) | Out-Null
            }
        }

        # Prüfe nochmals, ob Window-Objekt korrekt ist
        if (-not ($window -is [System.Windows.Window])) {
            throw "Konnte kein gültiges Window-Objekt erstellen, trotz mehrerer Versuche"
        }

        # Fenster der Skriptvariable zuweisen, NUR wenn es ein gültiges Window-Objekt ist
        $script:Window = $window
        Write-GuaranteedDebug -Message "Window-Objekt wurde zugewiesen vom Typ: $($script:Window.GetType().FullName)" -Level "INFO"

        # UI-Elemente per Name binden mit intelligenter Fehlerbehandlung
        try {
            Write-GuaranteedDebug -Message "Binde UI-Elemente" -Level "INFO"

            # XAML-Inhalt erneut verarbeiten, um alle benannten Elemente zu finden
            $xamlContent = $script:XamlContent
            [xml]$xamlDocument = $xamlContent -replace '^\s*<\?xml.*?\?>', '' -replace 'x:Class=".*?"', '' -replace 'mc:Ignorable="d"', ''

            # Namespace-Manager für X:Name-Attribute einrichten
            $script:XamlNamespace = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
            $script:XamlNamespace.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")

            # Alle Elemente mit Name-Attribut extrahieren
            $namedElements = $xamlDocument.SelectNodes("//*[@Name or @x:Name]", $script:XamlNamespace)
            Write-GuaranteedDebug -Message "Gefundene benannte UI-Elemente: $($namedElements.Count)" -Level "INFO"

            # Zähler für die Bindung
            $boundCount = 0
            $failedCount = 0

            foreach ($element in $namedElements) {
                $elementName = $element.Name
                # Zuerst normales Name-Attribut prüfen
                $originalName = $element.GetAttribute("Name")

                # Falls leer, versuche x:Name Attribut
                if ([string]::IsNullOrWhiteSpace($originalName)) {
                    $originalName = $element.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")

                    # Validierung des Elementnamens
                    if ([string]::IsNullOrWhiteSpace($originalName)) {
                        Write-GuaranteedDebug -Message "Element ohne gültigen Namen gefunden: $elementName - überspringe" -Level "WARNING"
                        continue
                    }
                }

                try {
                    # Element im geladenen UI finden
                    $uiElement = $script:Window.FindName($originalName)

                    # Validierung des UI-Elements
                    if ($null -ne $uiElement) {
                        # Element an Skript-Variable binden
                        Set-Variable -Name $originalName -Value $uiElement -Scope Script
                        $boundCount++
                        Write-GuaranteedDebug -Message "UI-Element erfolgreich gebunden: $originalName" -Level "DEBUG"
                    } else {
                        $failedCount++
                        Write-GuaranteedDebug -Message "Konnte UI-Element nicht finden: $originalName" -Level "WARNING"
                    }
                } catch {
                    $failedCount++
                    Write-GuaranteedDebug -Message "Fehler beim Binden des UI-Elements $originalName`: $($_.Exception.Message)" -Level "WARNING"
                }
            }

            Write-GuaranteedDebug -Message "UI-Elemente-Bindung: $boundCount erfolgreich, $failedCount fehlgeschlagen" -Level "INFO"
        } catch {
            $errorMsg = "Fehler beim Binden der UI-Elemente: $($_.Exception.Message)"
            Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"
            # Nicht kritisch, weitermachen
        }

        # UI-Eigenschaften setzen mit Fehlerbehandlung
        try {
            # App-Name im Header setzen
            if ($null -ne $HeaderAppName) {
                $HeaderAppName.Text = $script:AppName
                Write-GuaranteedDebug -Message "App-Name im Header gesetzt: $script:AppName" -Level "DEBUG"
            } else {
                Write-GuaranteedDebug -Message "HeaderAppName Element nicht gefunden" -Level "WARNING"
            }

            # Footer-Texte setzen
            if ($null -ne $FooterText) {
                $FooterText.Text = $script:Config.FooterText
                Write-GuaranteedDebug -Message "Footer-Text gesetzt" -Level "DEBUG"
            }

            if ($null -ne $FooterWebsite) {
                $FooterWebsite.Text = $script:Config.FooterWebseite
                Write-GuaranteedDebug -Message "Footer-Website gesetzt" -Level "DEBUG"
            }

            # ThemeColor setzen mit mehreren Fallback-Optionen
            $HeaderBackground = $script:Window.FindName("HeaderBackground")
            if ($null -ne $HeaderBackground) {
                try {
                    # 1. Versuch: Direktzugriff
                    $HeaderBackground.Fill = $script:ThemeColor
                    Write-GuaranteedDebug -Message "ThemeColor direkt gesetzt" -Level "DEBUG"
                } catch {
                    try {
                        # 2. Versuch: Mit ColorConverter
                        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($script:ThemeColor)
                        $brush = New-Object System.Windows.Media.SolidColorBrush($color)
                        $HeaderBackground.Fill = $brush
                        Write-GuaranteedDebug -Message "ThemeColor über ColorConverter gesetzt" -Level "DEBUG"
                    } catch {
                        Write-GuaranteedDebug -Message "Fehler beim Setzen der ThemeColor: $($_.Exception.Message)" -Level "WARNING"
                    }
                }
            }
        } catch {
            Write-GuaranteedDebug -Message "Nicht-kritischer Fehler beim Setzen der UI-Eigenschaften: $($_.Exception.Message)" -Level "WARNING"
            # Nicht kritisch, weitermachen
        }

        # Event-Handler registrieren und Window Loaded Event hinzufügen
        Register-EventHandlers
        Register-WindowLoadedEvent

        # Tabs initialisieren
        Initialize-TabPages

        # AD-Status in der GUI aktualisieren
        Update-ADConnectionStatusInGUI

        # UI-Tiefendiagnose durchführen
        # Start-UIDeepDiagnostics

        # Fenster anzeigen
        try {
            # WICHTIG: Prüfen, ob Window ein gültiges Objekt ist, bevor ShowDialog aufgerufen wird
            Write-GuaranteedDebug -Message "Zeige GUI-Fenster an" -Level "INFO"

            if ($null -eq $script:Window) {
                throw "Window-Objekt ist NULL"
            }

            if (-not ($script:Window -is [System.Windows.Window])) {
                $actualType = $script:Window.GetType().FullName
                throw "Window-Objekt ist kein gültiges Window-Objekt: $actualType"
            }

            # Sichere Ausführung von ShowDialog
            $script:Window.ShowDialog() | Out-Null
            Write-GuaranteedDebug -Message "GUI-Fenster wurde erfolgreich angezeigt" -Level "INFO"
        } catch {
            $errorMsg = "Fehler beim Anzeigen des Fensters: $($_.Exception.Message)"
            Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"

            # Versuche einen alternativen Ansatz bei String-Typ-Problem
            if ($script:Window -is [System.String]) {
                Write-GuaranteedDebug -Message "KRITISCH: Window ist ein String-Objekt - versuche Neuinitialisierung" -Level "ERROR"
                try {
                    # Erstelle ein einfaches Not-Window
                    $fallbackWindow = New-Object System.Windows.Window
                    $fallbackWindow.Title = "easyPASSWORDRESET - FEHLERFALL"
                    $fallbackWindow.Width = 500
                    $fallbackWindow.Height = 300

                    $stackPanel = New-Object System.Windows.Controls.StackPanel
                    $stackPanel.VerticalAlignment = "Center"
                    $stackPanel.Margin = New-Object System.Windows.Thickness(20)

                    $errorTextBlock = New-Object System.Windows.Controls.TextBlock
                    $errorTextBlock.Text = "KRITISCHER GUI-FEHLER:`n$($errorMsg)"
                    $errorTextBlock.FontSize = 16
                    $errorTextBlock.Foreground = "Red"
                    $errorTextBlock.TextWrapping = "Wrap"
                    $errorTextBlock.TextAlignment = "Center"
                    $errorTextBlock.Margin = New-Object System.Windows.Thickness(0, 0, 0, 20)

                    $closeButton = New-Object System.Windows.Controls.Button
                    $closeButton.Content = "Schließen"
                    $closeButton.Width = 100
                    $closeButton.Height = 30
                    $closeButton.Add_Click({ $fallbackWindow.Close() })

                    $stackPanel.Children.Add($errorTextBlock) | Out-Null
                    $stackPanel.Children.Add($closeButton) | Out-Null
                    $fallbackWindow.Content = $stackPanel

                    # Überschreibe das fehlerhafte Window
                    $script:Window = $fallbackWindow
                    $script:Window.ShowDialog() | Out-Null
                } catch {
                    $finalErrorMsg = "Konnte weder Hauptfenster noch Fehler-Fallback-Fenster anzeigen: $($_.Exception.Message)"
                    Write-GuaranteedDebug -Message $finalErrorMsg -Level "ERROR"
                    throw $finalErrorMsg
                }
            } else {
                throw $errorMsg
            }
        }

        Write-GuaranteedDebug -Message "GUI erfolgreich initialisiert und angezeigt" -Level "INFO"
    } catch {
        $errorMessage = "Kritischer Fehler beim Initialisieren der GUI: $($_.Exception.Message)"
        Write-GuaranteedDebug -Message $errorMessage -Level "ERROR"

        try {
            [System.Windows.MessageBox]::Show($errorMessage, "Fehler", "OK", "Error")
        } catch {
            Write-Error "Konnte MessageBox nicht anzeigen: $($_)"
            # Absolute Fallback-Methode
            Write-Information -MessageData "KRITISCHER FEHLER: $errorMessage" -InformationAction Continue
        }
    }
}

# Function zum sauberen Beenden des Skripts mit Ressourcenfreigabe
function Exit-Application {
    param (
        [string]$Message = "Anwendung wird beendet",
        [int]$ExitCode = 0
    )

    try {
        Write-GuaranteedDebug -Message "$Message (ExitCode: $ExitCode)" -Level "INFO"

        # Logdateien abschließen
        Write-Log "Anwendung wird beendet: $Message" -Level "Info"

        # GUI-Ressourcen freigeben
        if ($null -ne $script:Window) {
            try {
                $script:Window.Close()
                $script:Window = $null
                Write-GuaranteedDebug -Message "GUI-Fenster geschlossen" -Level "DEBUG"
            } catch {
                Write-GuaranteedDebug -Message "Fehler beim Schließen des GUI-Fensters: $($_.Exception.Message)" -Level "WARNING"
            }
        }

        # Alle temporären Dateien löschen, die älter als 7 Tage sind
        try {
            $tempFiles = Get-ChildItem -Path $env:TEMP -Filter "easyPASSWORD_*" -File |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }

            if ($tempFiles.Count -gt 0) {
                Write-GuaranteedDebug -Message "Lösche $($tempFiles.Count) temporäre Dateien" -Level "DEBUG"
                $tempFiles | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-GuaranteedDebug -Message "Fehler beim Bereinigen temporärer Dateien: $($_.Exception.Message)" -Level "WARNING"
        }

        # Abschließenden Banner ausgeben
        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Cyan
        Write-Information -MessageData " $($script:AppName) wurde beendet" -InformationAction Continue
        Write-Information -MessageData "====================================================" -InformationAction Continue
        Write-Host ""

        # Alle verbleibenden Runspaces und Jobs aufräumen
        Get-Job | Where-Object { $_.State -eq 'Running' } | Stop-Job
        Get-Job | Remove-Job

        # Beenden mit Exit-Code
        if ($ExitCode -ne 0) {
            exit $ExitCode
        }
    } catch {
        Write-Error "Fehler beim Beenden der Anwendung: $($_.Exception.Message)"
        exit 1
    }
}

# Selbstdiagnose-Funktion für Start-Checks (ohne externe Dateien)
function Start-SelfDiagnostics {
    try {
        Write-GuaranteedDebug -Message "Starte Selbstdiagnose" -Level "INFO"
        $diagnosticResults = @{
            Passed   = $true
            Warnings = 0
            Errors   = 0
            Details  = @()
        }

        # 1. Prüfe PowerShell-Version
        if ($PSVersionTable.PSVersion.Major -lt 5) {
            $diagnosticResults.Warnings++
            $diagnosticResults.Details += "PowerShell-Version ist älter als 5.0: $($PSVersionTable.PSVersion)"
            Write-GuaranteedDebug -Message "PowerShell-Version ist älter als 5.0: $($PSVersionTable.PSVersion)" -Level "WARNING"
        }

        # 2. Prüfe Required Assemblies
        $requiredAssemblies = @("PresentationFramework", "PresentationCore", "WindowsBase")
        foreach ($assembly in $requiredAssemblies) {
            try {
                [System.Reflection.Assembly]::LoadWithPartialName($assembly) | Out-Null
            } catch {
                $diagnosticResults.Errors++
                $diagnosticResults.Details += "Assembly konnte nicht geladen werden: $assembly"
                Write-GuaranteedDebug -Message "Assembly konnte nicht geladen werden: $assembly" -Level "ERROR"
            }
        }

        # 3. Prüfe die Benutzerberechtigungen
        try {
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
            $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

            if (-not $principal.IsInRole($adminRole)) {
                $diagnosticResults.Warnings++
                $diagnosticResults.Details += "Skript läuft nicht mit Administratorrechten"
                Write-GuaranteedDebug -Message "Skript läuft nicht mit Administratorrechten" -Level "WARNING"
            }
        } catch {
            $diagnosticResults.Errors++
            $diagnosticResults.Details += "Fehler beim Prüfen der Benutzerberechtigungen: $($_.Exception.Message)"
            Write-GuaranteedDebug -Message "Fehler beim Prüfen der Benutzerberechtigungen: $($_.Exception.Message)" -Level "ERROR"
        }

        # 4. Kritische Fehler behandeln
        if ($diagnosticResults.Errors -gt 0) {
            $diagnosticResults.Passed = $false
        }

        Write-GuaranteedDebug -Message "Selbstdiagnose abgeschlossen: $($diagnosticResults.Errors) Fehler, $($diagnosticResults.Warnings) Warnungen" -Level "INFO"

        # Warnungen in der GUI anzeigen, wenn vorhanden
        if ($diagnosticResults.Warnings -gt 0 -and $null -ne $script:Window) {
            try {
                $warningMessage = "Die Selbstdiagnose hat $($diagnosticResults.Warnings) Warnungen festgestellt:`n`n"
                $warningMessage += $diagnosticResults.Details -join "`n"

                [System.Windows.MessageBox]::Show(
                    $warningMessage,
                    "Diagnosewarnung",
                    "OK",
                    "Warning"
                )
            } catch {
                Write-GuaranteedDebug -Message "Fehler beim Anzeigen der Diagnosewarnungen: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        # Kritische Fehler behandeln
        if (-not $diagnosticResults.Passed) {
            try {
                $errorMessage = "Die Selbstdiagnose hat kritische Fehler festgestellt:`n`n"
                $errorMessage += ($diagnosticResults.Details | Where-Object { $_ -match "Fehler" }) -join "`n"

                [System.Windows.MessageBox]::Show(
                    $errorMessage,
                    "Diagnosefehler",
                    "OK",
                    "Error"
                )
            } catch {
                Write-GuaranteedDebug -Message "Fehler beim Anzeigen der Diagnosefehler: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        return $diagnosticResults
    } catch {
        Write-GuaranteedDebug -Message "Kritischer Fehler in der Selbstdiagnose: $($_.Exception.Message)" -Level "ERROR"
        return @{ Passed = $false; Errors = 1; Warnings = 0; Details = @("Kritischer Fehler in der Selbstdiagnose: $($_.Exception.Message)") }
    }
}

# Mehrsprachigkeitsunterstützung aktivieren
function Initialize-Localization {
    param (
        [string]$Language = "de-DE",
        [string]$FallbackLanguage = "en-US"
    )

    try {
        Write-GuaranteedDebug -Message "Initialisiere Mehrsprachigkeit für: $Language" -Level "INFO"

        # Lokalisierung direkt im Skript definieren (keine externen Dateien)
        $script:Localization = @{
            Language = $Language
            Strings  = @{
                # Deutsche Texte (Standard)
                "WindowTitle"           = "easyPASSWORDRESET - Active Directory Passwort Tool"
                "ButtonReset"           = "Passwort zurücksetzen"
                "ButtonUnlock"          = "Konto entsperren"
                "ButtonApply"           = "Anwenden"
                "ButtonCancel"          = "Abbrechen"
                "LabelUsername"         = "Benutzername:"
                "LabelPassword"         = "Neues Passwort:"
                "LabelConfirm"          = "Passwort bestätigen:"
                "StatusReady"           = "Bereit"
                "StatusProcessing"      = "Wird verarbeitet..."
                "StatusComplete"        = "Abgeschlossen"
                "ErrorInvalidUser"      = "Ungültiger Benutzername"
                "ErrorPasswordMismatch" = "Passwörter stimmen nicht überein"
                "SuccessPasswordReset"  = "Passwort erfolgreich zurückgesetzt"
                "SuccessAccountUnlock"  = "Konto erfolgreich entsperrt"
                "TabSingleUser"         = "Einzelner Benutzer"
                "TabOUGroup"            = "OU/Gruppe"
                "TabPolicies"           = "Passwort-Richtlinien"
                "TabFGPP"               = "Feinabgestimmte Passwort-Richtlinien"
                "FooterText"            = "© $(Get-Date -Format 'yyyy') PhinIT easyPASSWORDRESET"
                "FooterWebsite"         = "www.phinit.de"
            }
        }

        Write-GuaranteedDebug -Message "Mehrsprachigkeit initialisiert mit $($script:Localization.Strings.Count) Einträgen" -Level "INFO"
    } catch {
        Write-GuaranteedDebug -Message "Kritischer Fehler bei der Initialisierung der Mehrsprachigkeit: $($_.Exception.Message)" -Level "ERROR"

        # Fallback: Minimale Lokalisierung
        $script:Localization = @{
            Language = "de-DE"
            Strings  = @{
                "WindowTitle"  = "easyPwdRESET - AD Passwort Tool"
                "ButtonReset"  = "Zurücksetzen"
                "ButtonUnlock" = "Entsperren"
                "StatusReady"  = "Bereit"
            }
        }
    }
}

# Finales Cleanup beim Beenden des Skripts
function Register-ExitHandlers {
    try {
        # PowerShell-Exit-Handler
        $MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
            Exit-Application -Message "Skript wird entladen"
        }

        # Event-Handler beim Herunterfahren des Systems
        Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
            Exit-Application -Message "PowerShell wird beendet"
        }
    } catch {
        Write-GuaranteedDebug -Message "Fehler beim Registrieren der Exit-Handler: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Selbstdiagnostik durchführen
# Start-SelfDiagnostics

# Mehrsprachigkeit initialisieren
Initialize-Localization -Language "de-DE"

# Exit-Handler registrieren
Register-ExitHandlers

# Hauptprogramm
try {
    # Starte das Programm
    Write-Log "Programmstart: $script:AppName"
    Write-GuaranteedDebug -Message "Starte Hauptprogramm: $script:AppName" -Level "INFO"

    # Verwende die sichere GUI-Initialisierung
    Initialize-GUI-Safe

    Write-GuaranteedDebug -Message "Hauptprogramm abgeschlossen" -Level "INFO"
} catch {
    $errorMsg = "Kritischer Fehler beim Starten der Anwendung: $($_)"
    Write-Log $errorMsg
    Write-GuaranteedDebug -Message $errorMsg -Level "ERROR"

    try {
        [System.Windows.MessageBox]::Show($errorMsg, "Kritischer Fehler", "OK", "Error")
    } catch {
        Write-Error "Konnte MessageBox nicht anzeigen: $($_)"
        Write-Information -MessageData $errorMsg -InformationAction Continue
    }

    # Beende mit Fehlercode
    Exit-Application -Message "Kritischer Fehler beim Starten" -ExitCode 1
}

# Ordnungsgemäßes Beenden des Skripts
Exit-Application -Message "Anwendung normal beendet"



# SIG # Begin signature block
# MIIcCAYJKoZIhvcNAQcCoIIb+TCCG/UCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDgBhpjeijNvsag
# cMy5eZDqxFmOeDlKko/SN7c9051jBaCCFk4wggMQMIIB+KADAgECAhB3jzsyX9Cg
# jEi+sBC2rBMTMA0GCSqGSIb3DQEBCwUAMCAxHjAcBgNVBAMMFVBoaW5JVC1QU3Nj
# cmlwdHNfU2lnbjAeFw0yNTA3MDUwODI4MTZaFw0yNzA3MDUwODM4MTZaMCAxHjAc
# BgNVBAMMFVBoaW5JVC1QU3NjcmlwdHNfU2lnbjCCASIwDQYJKoZIhvcNAQEBBQAD
# ggEPADCCAQoCggEBALmz3o//iDA5MvAndTjGX7/AvzTSACClfuUR9WYK0f6Ut2dI
# mPxn+Y9pZlLjXIpZT0H2Lvxq5aSI+aYeFtuJ8/0lULYNCVT31Bf+HxervRBKsUyi
# W9+4PH6STxo3Pl4l56UNQMcWLPNjDORWRPWHn0f99iNtjI+L4tUC/LoWSs3obzxN
# 3uTypzlaPBxis2qFSTR5SWqFdZdRkcuI5LNsJjyc/QWdTYRrfmVqp0QrvcxzCv8u
# EiVuni6jkXfiE6wz+oeI3L2iR+ywmU6CUX4tPWoS9VTtmm7AhEpasRTmrrnSg20Q
# jiBa1eH5TyLAH3TcYMxhfMbN9a2xDX5pzM65EJUCAwEAAaNGMEQwDgYDVR0PAQH/
# BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBQO7XOqiE/EYi+n
# IaR6YO5M2MUuVTANBgkqhkiG9w0BAQsFAAOCAQEAjYOKIwBu1pfbdvEFFaR/uY88
# peKPk0NnvNEc3dpGdOv+Fsgbz27JPvItITFd6AKMoN1W48YjQLaU22M2jdhjGN5i
# FSobznP5KgQCDkRsuoDKiIOTiKAAknjhoBaCCEZGw8SZgKJtWzbST36Thsdd/won
# ihLsuoLxfcFnmBfrXh3rTIvTwvfujob68s0Sf5derHP/F+nphTymlg+y4VTEAijk
# g2dhy8RAsbS2JYZT7K5aEJpPXMiOLBqd7oTGfM7y5sLk2LIM4cT8hzgz3v5yPMkF
# H2MdR//K403e1EKH9MsGuGAJZddVN8ppaiESoPLoXrgnw2SY5KCmhYw1xRFdjTCC
# BY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFowDQYJKoZIhvcNAQEMBQAwZTEL
# MAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3
# LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNlcnQgQXNzdXJlZCBJRCBSb290
# IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIzNTk1OVowYjELMAkGA1UEBhMC
# VVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0
# LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2jeu+RdSjwwIjBpM+zCpyUuySE9
# 8orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bGl20dq7J58soR0uRf1gU8Ug9S
# H8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBEEC7fgvMHhOZ0O21x4i0MG+4g
# 1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/NrDRAX7F6Zu53yEioZldXn1RY
# jgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A2raRmECQecN4x7axxLVqGDgD
# EI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8IUzUvK4bA3VdeGbZOjFEmjNA
# vwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfBaYh2mHY9WV1CdoeJl2l6SPDg
# ohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaaRBkrfsCUtNJhbesz2cXfSwQA
# zH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZifvaAsPvoZKYz0YkH4b235kOk
# GLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXeeqxfjT/JvNNBERJb5RBQ6zHF
# ynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g/KEexcCPorF+CiaZ9eRpL5gd
# LfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYE
# FOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1Ri6en
# IZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUH
# MAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDov
# L2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNy
# dDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1UdIAQKMAgwBgYEVR0gADANBgkq
# hkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22Ftf3v1cHvZqsoYcs7IVeqRq7
# IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih9/Jy3iS8UgPITtAq3votVs/5
# 9PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYDE3cnRNTnf+hZqPC/Lwum6fI0
# POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c2PR3WlxUjG/voVA9/HYJaISf
# b8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88nq2x2zm8jLfR+cWojayL/ErhU
# LSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5lDCCBrQwggScoAMCAQICEA3H
# rFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMCVVMxFTAT
# BgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEh
# MB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4XDTI1MDUwNzAwMDAw
# MFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFt
# cGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysddujRmh0tFEXnU2tjQ2UtZmWgyxU
# 7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S9SLrC6Kbltqn7SWCWgzbNfiR
# +2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+42DFUF0mR/vtLa4+gKPsYfwE
# u7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg62IVwxKSpO0XaF9DPfNBKS7Za
# zch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21Qomb+zzQWKhxKTVVgtmUPAW3
# 5xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8y9IaaGBpPNXKFifinT7zL2gd
# FpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQNfVmUB5KlCX3ZA4x5HHKS+rq
# BvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gaou30yZ46t4Y9F20HHfIY4/6vH
# espYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6gqztiT96Fv/9bH7mQyogxG9QE
# PHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJDpsZGKdlsjg4u70EwgWbVRSX1
# Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D8bpfm4CLKczsG7ZrIGNTAgMB
# AAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/57qYrhwPTzAO
# BgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgwdwYIKwYBBQUHAQEE
# azBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQQYIKwYB
# BQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAGA1UdIAQZMBcwCAYG
# Z4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAF877FoAc/gc9
# EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6FTGNpoV2V4wzSUGvI9NAzaoQk
# 97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mCefSG+tXqGpYZ3essBS3q8nL2
# UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57mQfQXwcAEGCvRR2qKtntujB71
# WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9ydOal95CHfmTnM4I+ZI2rVQf
# jXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dBwp9nEC8EAqoxW6q17r0z0noD
# js6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdqfMTCW/NmKLJ9M+MtucVGyOxi
# Df06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2puE6FndlENSmE+9JGYxOGLS/
# D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAOk5eCkhSxZON3rGlHqhpB/8Ml
# uDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL0Q4ssd8xHZnIn/7GELH3IdvG
# 2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBunvAZapsiI5YKdvlarEvf8EA+8
# hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE1aADAgECAhAKgO8YS43xBYLR
# xHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwHhcNMjUwNjA0MDAwMDAw
# WhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNl
# cnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVz
# dGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHfyjfMGUIwYzKomd8U1nH7C8Dr
# 0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPxNyFPJIDZHhAqlUPt281mHrBb
# ZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpkBaMUNg7MOLxI6E9RaUueHTQK
# WXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFvZSjKs3SKO1QNUdFd2adw44wD
# cKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1znOM8odbkqoK+lJ25LCHBSai25
# CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8fcpK40uhktzUd/Yk0xUvhDU6l
# vJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ahfvAk12hE5FVs9HVVWcO5J4dV
# mVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUDy9Z2hSgctaepZTd0ILIUbWuh
# KuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9w6CtjuuVHJOVoIJ/DtpJRE7C
# e7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTnnkrT3pXWETTJkhd76CIDBbTR
# ofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKacJ+A9/z7eacCAwEAAaOCAZUw
# ggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7/PIx7f391/ORcWMZUEPPYYzo
# MB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIH
# gDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYI
# KwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZR
# aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGlt
# ZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBS
# oFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRp
# bWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgG
# BmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBAGUqrfEcJwS5
# rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF0RkP2AGr181o2YWPoSHz9iZE
# N/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKqdT8wv2UV+Kbz/3ImZlJ7YXwB
# D9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbUUO75ZSpbh1oipOhcUT8lD8QA
# GB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTeHihsQyfFg5fxUFEp7W42fNBV
# N4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG7aEQJmmrJTV3Qhtfparz+BW6
# 0OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NBqycz0BZwhB9WOfOu/CIJnzkQ
# TwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6+iX8MmB10nfldPF9SVD7weCC
# 3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaAyBjFBtXVLcKtapnMG3VH3EmA
# p/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyPehwJVxwC+UpX2MSey2ueIu9T
# HFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3FNwFlTxq25+T4QwX9xa6ILs84
# ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIFEDCCBQwCAQEwNDAgMR4wHAYDVQQD
# DBVQaGluSVQtUFNzY3JpcHRzX1NpZ24CEHePOzJf0KCMSL6wELasExMwDQYJYIZI
# AWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAv
# BgkqhkiG9w0BCQQxIgQg4sf8cwMcHHf9Ezio7k6jEZl7486cEkv5W3VcmAbqeUIw
# DQYJKoZIhvcNAQEBBQAEggEAqUsTaey9x1V6WUcYPPDTZFJuK+59IkxeMPX9Gw1K
# FjDByF5N1PE9SrfgGiqhE+BheoAmBjc2nzI6zHjHckQCzoEC3IuwjmX/L6cC2/4P
# lxlSzCnRJxf7bEijbCvMpzKCfUthmQ8QLZjVR8WfFN5pbqGkCBDnDwXFFnod5e2A
# snnNs2mz4XPCYU8f5NqKPdIK1usw9DIbIVsMdqHzManz4EP7OJ1R0Uu359u6tJw7
# Yce0uOnwTASc7CoHK8tBYrlefOi86uigKhcks86n7R3gdKE7igxquK4Laxjx7mxm
# HncmDMZr7g62ApmoQfGIruF0Siud1D7PraqEMkZXaELjAKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeVdGgw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNTA3MjAxMjIxNDBaMC8GCSqGSIb3DQEJBDEiBCAvK4NhQ6ty
# kPHNrmb784W2j1LXeXNExwYr+muQN2ht/TANBgkqhkiG9w0BAQEFAASCAgCzEwTL
# hwptbHHbyBJ8uLQaWUhsQr2pAGn0Y0gcVwkjRorXSJwOTLBIqnZgvrsBlChCOxFk
# yTA3vuAJ9AMr7v9Tvf9vvxueNLVIqIeyA5sdXVa5V/8R0XgZC5kcSgQyUG6KLm6g
# mZ/VKFfvle05szTihA9eeImMPcjh/gJ2GLmf/Lrr4/gUg0GZOS8+tu38gQ9/bQ+2
# GCpmW75It7Q+fnMeUFr0KMwabKf+tS6MI0jxgyeKbqJV1oY60I9lwfhrvt0EF/il
# LhcbZDFf+hZTm+7lDh8WDPAPxEkLea5KXpAXlMrgpVGfrrRwKf+SjQdBakK6VJk7
# UKXYeNIisxKffhlwjyHoEdWgcqYJ7NEIWi32BodxbWRR+XGM3CSTDbGj9pWvQd4K
# 8nxT0LH40Oah8FiNxWpXbJHG/1e3iBjVSmRasGtvDg09CPBbER1SqunAJXMvpCt/
# i7fyI6+OgvRtwVWsueq829Lppf0h1thvXBYJiq7N1h/7dOQsJ3G3r0Dx95PFrdJF
# JPq7lYk+3PXNBt72GopaKJACeRq669zKUTcgnyMVFGVpRiE0RFv+H8y201+DOYbF
# zEPIZGO/bACGuX+imzX0hHyqRkgM67l0X9ctRg6BI/X/Fx5l+kwrvWd/YNGzttvs
# USWTwyr0vTaze29MafAuZpo7deGupUTrcQyN5g==
# SIG # End signature block
