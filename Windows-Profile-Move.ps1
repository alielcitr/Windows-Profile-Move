<#
.SYNOPSIS
    Windows kullanıcı profilini bir hesaptan başka bir hesaba güvenli şekilde taşır.
 
.DESCRIPTION
    Windows Profile Move; bir kaynak kullanıcı hesabına ait profili (dosyalar,
    NTUSER.DAT registry hive'ı, NTFS izinleri ve ProfileList registry kaydı
    dahil) hedef bir kullanıcı hesabına, aşağıdaki denetimli fazları izleyerek
    taşır:
 
        INIT -> BACKUP -> COPY -> TRANSFORM_HIVE -> UPDATE_ACL
              -> UPDATE_PROFILELIST -> (VERIFY_TARGET) -> COMMIT
              -> DELETE_SOURCE -> (FINAL_VERIFY) -> COMPLETED
 
    Her faz, işlem bittikten sonra bir JSON durum (state) dosyasına kaydedilir.
    Bu sayede taşıma kesintiye uğrarsa -Resume ile kaldığı fazdan devam
    ettirilebilir. COMMIT fazından önce oluşan hatalarda dosyalar ve
    ProfileList registry'si otomatik olarak yedekten geri yüklenir
    (rollback); COMMIT sonrası otomatik rollback güvenli olmadığı için
    bilinçli olarak devre dışıdır.
 
    Betik, yönetici (elevated) bir PowerShell oturumu gerektirir ve
    SupportsShouldProcess desteklediği için -WhatIf / -Confirm ile
    kullanılabilir.
 
.PARAMETER SourceUser
    Kaynak hesap. 'kullaniciadi' veya 'DOMAIN\kullaniciadi' biçiminde.
 
.PARAMETER TargetUser
    Hedef hesap. 'kullaniciadi' veya 'DOMAIN\kullaniciadi' biçiminde.
 
.PARAMETER DestinationPath
    Hedef profilin taşınacağı özel klasör yolu. Belirtilmezse hedef hesabın
    mevcut/varsayılan profil yolu kullanılır.
 
.PARAMETER KeepSource
    Belirtilirse kaynak profil silinmez, sadece kopyalanır (klonlama).
 
.PARAMETER Force
    Hedef profil klasörü zaten varsa üzerine yazılmasına izin verir.
 
.PARAMETER Backup
    Bilgilendirme amaçlıdır; betik yedeklemeyi her durumda zorunlu kılar.
 
.PARAMETER BackupPath
    Yedeklerin yazılacağı kök klasör. Varsayılan: %TEMP%\ProfileMigration\Backup
 
.PARAMETER Verify
    Hedef profili (ve kaynağın gerçekten silindiğini) doğrulayan ek
    kontrolleri etkinleştirir.
 
.PARAMETER SkipNTUserUpdate
    NTUSER.DAT içindeki yol/SID güncellemesini atlar.
 
.PARAMETER Silent
    Konsola çıktı basmaz; yalnızca log dosyasına yazar.
 
.PARAMETER TimeoutMinutes
    Robocopy işlemleri için zaman aşımı (1-1440 dakika). Varsayılan: 120.
 
.PARAMETER Resume
    -StateFile ile belirtilen kayıtlı durumdan taşımaya devam eder.
 
.PARAMETER StateFile
    Durum (state) JSON dosyasının yolu. Belirtilmezse otomatik oluşturulur.
 
.EXAMPLE
    .\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new'
 
    En basit kullanım: aynı makinedeki iki yerel hesap arasında profili
    taşır, izinleri ve ProfileList'i günceller, doğrulama sonrası kaynağı
    siler.
 
.EXAMPLE
    .\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' -WhatIf
 
    Hiçbir değişiklik yapmadan taşıma planını gösterir (kuru çalıştırma).
 
.EXAMPLE
    .\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' `
        -KeepSource -Verify
 
    Kaynağı silmeden hedefte doğrulanmış bir kopya oluşturur (klonlama).
 
.EXAMPLE
    .\profilemove.ps1 -SourceUser 'aelci.old' -TargetUser 'aelci.new' `
        -Resume -StateFile 'C:\Temp\ProfileMigration\state_20260819_120000.json'
 
    Daha önce kesintiye uğramış bir taşımayı kaydedilmiş state dosyasından
    devam ettirir.
 
.NOTES
    Ad     : Windows Profile Move
    Yazar  : ALİ ELÇİ
    Sürüm  : 1.0
	mail   : alielcitr@gmail.com
 
    Gereksinimler:
      - Yönetici olarak çalıştırılan PowerShell 5.1+
      - Taşınacak hesapların ikisinin de oturum açık olmaması
      - robocopy.exe, reg.exe, icacls.exe (Windows'ta varsayılan bulunur)
 
.LINK
    https://github.com/alielcitr/Windows-Profile-Move
#>
[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High'
)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SourceUser,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$TargetUser,

    [Parameter(Position = 2)]
    [string]$DestinationPath,

    [switch]$KeepSource,
    [switch]$Force,
    [switch]$Backup,
    [string]$BackupPath,
    [switch]$Verify,
    [switch]$SkipNTUserUpdate,
    [switch]$Silent,
    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 120,
    [switch]$Resume,
    [string]$StateFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ============================================================================
# CONSTANTS
# ============================================================================

$script:ProfileListRoot =
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

$script:SystemSids = @(
    'S-1-5-18',
    'S-1-5-19',
    'S-1-5-20'
)

# ============================================================================
# ENUM-LIKE PHASES
# ============================================================================

class MigrationPhase {
    static [string]$INIT              = 'INIT'
    static [string]$BACKUP            = 'BACKUP'
    static [string]$COPY              = 'COPY'
    static [string]$TRANSFORM_HIVE    = 'TRANSFORM_HIVE'
    static [string]$UPDATE_ACL        = 'UPDATE_ACL'
    static [string]$UPDATE_PROFILELIST = 'UPDATE_PROFILELIST'
    static [string]$VERIFY_TARGET     = 'VERIFY_TARGET'
    static [string]$COMMIT            = 'COMMIT'
    static [string]$DELETE_SOURCE     = 'DELETE_SOURCE'
    static [string]$FINAL_VERIFY      = 'FINAL_VERIFY'
    static [string]$COMPLETED         = 'COMPLETED'
    static [string]$ROLLBACK          = 'ROLLBACK'
    static [string]$FAILED            = 'FAILED'
}

# ============================================================================
# LOGGER
# ============================================================================

class Logger {
    [string]$LogPath
    [bool]$Silent

    Logger(
        [string]$LogPath,
        [bool]$Silent = $false
    ) {
        $this.LogPath = $LogPath
        $this.Silent = $Silent

        $dir = Split-Path -Path $LogPath -Parent

        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force |
                Out-Null
        }
    }

    [void]Log(
        [string]$Message,
        [string]$Level = 'INFO'
    ) {
        $entry = @{
            Time    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            Level   = $Level
            Message = $Message
        }

        try {
            ($entry | ConvertTo-Json -Compress) |
                Out-File -FilePath $this.LogPath -Append -Encoding UTF8
        }
        catch {
            # Logging failure must never break migration.
        }

        if (-not $this.Silent) {
            $color = switch ($Level) {
                'ERROR'   { 'Red' }
                'WARNING' { 'Yellow' }
                'SUCCESS' { 'Green' }
                'PHASE'   { 'Cyan' }
                default   { 'Gray' }
            }

            Write-Host "[$Level] $Message" -ForegroundColor $color
        }
    }

    [void]Info([string]$Message) {
        $this.Log($Message, 'INFO')
    }

    [void]Warning([string]$Message) {
        $this.Log($Message, 'WARNING')
    }

    [void]Error([string]$Message) {
        $this.Log($Message, 'ERROR')
    }

    [void]Success([string]$Message) {
        $this.Log($Message, 'SUCCESS')
    }

    [void]Phase([string]$Message) {
        $this.Log($Message, 'PHASE')
    }

    [void]Section([string]$Title) {
        $this.Log("=== $Title ===", 'PHASE')

        if (-not $this.Silent) {
            Write-Host ''
            Write-Host ('=' * 72) -ForegroundColor Cyan
            Write-Host $Title -ForegroundColor Cyan
            Write-Host ('=' * 72) -ForegroundColor Cyan
        }
    }
}

# ============================================================================
# STATE
# ============================================================================

class MigrationState {

    [string]$MigrationId
    [string]$Phase

    [string]$SourceUser
    [string]$SourceSID
    [string]$SourceProfile

    [string]$TargetUser
    [string]$TargetSID
    [string]$TargetProfile

    [string]$BackupPath
    [string]$RegistryBackupPath

    [datetime]$StartTime
    [datetime]$LastUpdate

    [bool]$BackupCompleted = $false
    [bool]$CopyCompleted = $false
    [bool]$HiveTransformed = $false
    [bool]$ACLUpdated = $false
    [bool]$ProfileListUpdated = $false
    [bool]$TargetVerified = $false
    [bool]$Committed = $false
    [bool]$SourceDeleted = $false
    [bool]$FinalVerified = $false

    [System.Collections.ArrayList]$Errors
    [System.Collections.ArrayList]$Warnings

    MigrationState() {
        $this.MigrationId = [Guid]::NewGuid().ToString()
        $this.Phase = [MigrationPhase]::INIT
        $this.StartTime = Get-Date
        $this.LastUpdate = Get-Date

        $this.Errors = [System.Collections.ArrayList]::new()
        $this.Warnings = [System.Collections.ArrayList]::new()
    }

    [void]UpdatePhase([string]$NewPhase) {
        $this.Phase = $NewPhase
        $this.LastUpdate = Get-Date
    }

    [void]AddError([string]$Message) {
        [void]$this.Errors.Add($Message)
        $this.LastUpdate = Get-Date
    }

    [void]AddWarning([string]$Message) {
        [void]$this.Warnings.Add($Message)
        $this.LastUpdate = Get-Date
    }

    [string]ToJson() {

        $data = [ordered]@{
            MigrationId        = $this.MigrationId
            Phase              = $this.Phase

            SourceUser         = $this.SourceUser
            SourceSID          = $this.SourceSID
            SourceProfile      = $this.SourceProfile

            TargetUser         = $this.TargetUser
            TargetSID          = $this.TargetSID
            TargetProfile      = $this.TargetProfile

            BackupPath         = $this.BackupPath
            RegistryBackupPath = $this.RegistryBackupPath

            StartTime          = $this.StartTime.ToString('o')
            LastUpdate         = $this.LastUpdate.ToString('o')

            BackupCompleted    = $this.BackupCompleted
            CopyCompleted      = $this.CopyCompleted
            HiveTransformed    = $this.HiveTransformed
            ACLUpdated         = $this.ACLUpdated
            ProfileListUpdated = $this.ProfileListUpdated
            TargetVerified     = $this.TargetVerified
            Committed          = $this.Committed
            SourceDeleted      = $this.SourceDeleted
            FinalVerified      = $this.FinalVerified

            Errors             = @($this.Errors)
            Warnings           = @($this.Warnings)
        }

        return ($data | ConvertTo-Json -Depth 10)
    }

    static [MigrationState] FromJson([string]$Json) {

        try {
            $data = $Json | ConvertFrom-Json

            $state = [MigrationState]::new()

            $state.MigrationId =
                [string]$data.MigrationId

            $state.Phase =
                [string]$data.Phase

            $state.SourceUser =
                [string]$data.SourceUser

            $state.SourceSID =
                [string]$data.SourceSID

            $state.SourceProfile =
                [string]$data.SourceProfile

            $state.TargetUser =
                [string]$data.TargetUser

            $state.TargetSID =
                [string]$data.TargetSID

            $state.TargetProfile =
                [string]$data.TargetProfile

            $state.BackupPath =
                [string]$data.BackupPath

            $state.RegistryBackupPath =
                [string]$data.RegistryBackupPath

            $state.StartTime =
                [datetime]::Parse([string]$data.StartTime)

            $state.LastUpdate =
                [datetime]::Parse([string]$data.LastUpdate)

            $state.BackupCompleted =
                [bool]$data.BackupCompleted

            $state.CopyCompleted =
                [bool]$data.CopyCompleted

            $state.HiveTransformed =
                [bool]$data.HiveTransformed

            $state.ACLUpdated =
                [bool]$data.ACLUpdated

            $state.ProfileListUpdated =
                [bool]$data.ProfileListUpdated

            $state.TargetVerified =
                [bool]$data.TargetVerified

            $state.Committed =
                [bool]$data.Committed

            $state.SourceDeleted =
                [bool]$data.SourceDeleted

            $state.FinalVerified =
                [bool]$data.FinalVerified

            $state.Errors =
                [System.Collections.ArrayList]::new()

            foreach ($item in @($data.Errors)) {
                [void]$state.Errors.Add([string]$item)
            }

            $state.Warnings =
                [System.Collections.ArrayList]::new()

            foreach ($item in @($data.Warnings)) {
                [void]$state.Warnings.Add([string]$item)
            }

            return $state
        }
        catch {
            throw "State deserialization failed: $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# ADMIN CHECK
# ============================================================================

function Test-IsAdministrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
        New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ============================================================================
# PATH HELPERS
# ============================================================================

function Normalize-PathForComparison {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        return $full.TrimEnd('\').ToLowerInvariant()
    }
    catch {
        return $Path.TrimEnd('\').ToLowerInvariant()
    }
}

function Test-PathInsidePath {
    param(
        [Parameter(Mandatory)]
        [string]$ChildPath,

        [Parameter(Mandatory)]
        [string]$ParentPath
    )

    $child = Normalize-PathForComparison $ChildPath
    $parent = Normalize-PathForComparison $ParentPath

    return (
        $child -eq $parent -or
        $child.StartsWith($parent + '\')
    )
}

# ============================================================================
# PROFILE INFORMATION
# ============================================================================

class ProfileInfo {

    [string]$OriginalInput
    [string]$Username
    [string]$Domain
    [string]$SID
    [string]$ProfilePath
    [bool]$IsDomainUser
    [bool]$IsLocalUser
    [bool]$ProfileExists
    [bool]$IsActive
    [string]$NTAccount
    [string]$SamAccountName

    ProfileInfo([string]$UsernameInput) {

        $this.OriginalInput = $UsernameInput

        $this.ParseUsername()
        $this.ResolveSID()
        $this.LoadProfileInfo()
    }

    [void]ParseUsername() {

        $value = $this.OriginalInput.Trim()

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'Username cannot be empty.'
        }

        if ($value.Contains('\')) {

            $parts = $value -split '\\', 2

            if ($parts.Count -ne 2) {
                throw "Invalid account format: $value"
            }

            $this.Domain = $parts[0]
            $this.Username = $parts[1]
            $this.SamAccountName = $parts[1]
            $this.IsDomainUser = $true
        }
        else {
            $this.Domain = $env:COMPUTERNAME
            $this.Username = $value
            $this.SamAccountName = $value
            $this.IsLocalUser = $true
        }

        $this.NTAccount =
            "$($this.Domain)\$($this.SamAccountName)"
    }

    [void]ResolveSID() {

        try {

            $account =
                New-Object System.Security.Principal.NTAccount(
                    $this.NTAccount
                )

            $sid =
                $account.Translate(
                    [System.Security.Principal.SecurityIdentifier]
                )

            $this.SID = $sid.Value

            if ($this.SID -in $script:SystemSids) {
                throw "System account cannot be migrated: $($this.NTAccount)"
            }

            try {

                $localAccount =
                    Get-CimInstance Win32_UserAccount `
                        -Filter "Name='$($this.SamAccountName)'" `
                        -ErrorAction Stop |
                    Where-Object {
                        $_.Domain -eq $this.Domain
                    } |
                    Select-Object -First 1

                if ($null -ne $localAccount) {

                    $this.IsLocalUser =
                        [bool]$localAccount.LocalAccount

                    $this.IsDomainUser =
                        -not $this.IsLocalUser
                }
            }
            catch {
                # SID resolution already succeeded.
            }
        }
        catch {
            throw "Could not resolve account '$($this.NTAccount)': $($_.Exception.Message)"
        }
    }

    [string]GetProfilePathFromSID() {

        $key =
            Join-Path $script:ProfileListRoot $this.SID

        if (-not (Test-Path -LiteralPath $key)) {
            return $null
        }

        try {

            $value =
                Get-ItemProperty `
                    -LiteralPath $key `
                    -Name ProfileImagePath `
                    -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace(
                [string]$value.ProfileImagePath
            )) {
                return $null
            }

            return [Environment]::ExpandEnvironmentVariables(
                [string]$value.ProfileImagePath
            )
        }
        catch {
            return $null
        }
    }

    [void]LoadProfileInfo() {

        $path = $this.GetProfilePathFromSID()

        if ([string]::IsNullOrWhiteSpace($path)) {
            $path =
                Join-Path $env:SystemDrive (
                    "Users\$($this.Username)"
                )
        }

        $this.ProfilePath = $path
        $this.ProfileExists =
            Test-Path -LiteralPath $path -PathType Container

        $this.IsActive =
            Test-UserProfileActive -SID $this.SID -SamAccountName $this.SamAccountName
    }

    [void]UpdateProfilePath([string]$NewPath) {

        if ([string]::IsNullOrWhiteSpace($NewPath)) {
            throw 'Destination profile path cannot be empty.'
        }

        $this.ProfilePath =
            [Environment]::ExpandEnvironmentVariables($NewPath)

        $this.ProfileExists =
            Test-Path -LiteralPath $this.ProfilePath -PathType Container
    }
}

function Test-UserProfileActive {
    param(
        [Parameter(Mandatory)]
        [string]$SID,

        [Parameter(Mandatory)]
        [string]$SamAccountName
    )

    # PRIMARY CHECK: a loaded NTUSER.DAT hive under HKEY_USERS\<SID> is the
    # authoritative signal that a profile is currently in use (interactive
    # logon, scheduled task running as that user, a service, etc.).
    try {

        $loaded =
            Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSChildName -eq $SID
            }

        if ($loaded) {
            return $true
        }
    }
    catch {
    }

    # SECONDARY CHECK: "query user" output does NOT contain SIDs, it lists
    # session name / username / state, so it must be matched by account
    # name rather than SID. This only catches *interactive* sessions, but
    # is kept as a defense-in-depth check alongside the hive check above.
    try {

        $output =
            & "$env:SystemRoot\System32\query.exe" user 2>$null

        foreach ($line in @($output)) {

            # query user pads/truncates the username column and may prefix
            # the active session with '>'; do a loose, case-insensitive
            # match on the username token instead of a full-line match.
            $trimmed = $line.TrimStart('>', ' ')

            if ($trimmed -match ('^' + [regex]::Escape($SamAccountName) + '\s')) {
                return $true
            }
        }
    }
    catch {
    }

    return $false
}

# ============================================================================
# STATE SAVE / LOAD
# ============================================================================

function Save-MigrationState {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [string]$StateFilePath,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    try {

        $directory =
            Split-Path -Path $StateFilePath -Parent

        if ($directory -and -not (Test-Path -LiteralPath $directory)) {

            New-Item `
                -ItemType Directory `
                -Path $directory `
                -Force |
                Out-Null
        }

        $temporary =
            "$StateFilePath.$([Guid]::NewGuid().ToString('N')).tmp"

        $State.ToJson() |
            Out-File `
                -FilePath $temporary `
                -Encoding UTF8 `
                -Force

        Move-Item `
            -LiteralPath $temporary `
            -Destination $StateFilePath `
            -Force

        $Logger.Info(
            "State saved: $StateFilePath [$($State.Phase)]"
        )

        return $true
    }
    catch {

        $Logger.Error(
            "Could not save state: $($_.Exception.Message)"
        )

        throw
    }
}

function Load-MigrationState {
    param(
        [Parameter(Mandatory)]
        [string]$StateFilePath,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    if (-not (Test-Path -LiteralPath $StateFilePath)) {
        return $null
    }

    try {

        $json =
            Get-Content `
                -LiteralPath $StateFilePath `
                -Raw `
                -ErrorAction Stop

        $state =
            [MigrationState]::FromJson($json)

        $Logger.Info(
            "State loaded: $StateFilePath [$($state.Phase)]"
        )

        return $state
    }
    catch {

        $Logger.Error(
            "Could not load state: $($_.Exception.Message)"
        )

        throw
    }
}

# ============================================================================
# ROBocopy
# ============================================================================

function Invoke-RobocopyWithTimeout {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $robocopy =
        Join-Path $env:SystemRoot 'System32\robocopy.exe'

    if (-not (Test-Path -LiteralPath $robocopy)) {
        throw "Robocopy not found: $robocopy"
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Robocopy source does not exist: $Source"
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item `
            -ItemType Directory `
            -Path $Destination `
            -Force |
            Out-Null
    }

    $allArgs = @(
        $Source
        $Destination
    ) + $Arguments

    $psi =
        New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = $robocopy
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Proper Windows command line quoting.
    $psi.Arguments =
        (($allArgs | ForEach-Object {
            if ($_ -match '[\s"]') {
                '"' + ($_ -replace '"', '\"') + '"'
            }
            else {
                $_
            }
        }) -join ' ')

    $Logger.Info(
        "Robocopy: $Source -> $Destination"
    )

    $process =
        New-Object System.Diagnostics.Process

    $process.StartInfo = $psi

    try {

        if (-not $process.Start()) {
            throw 'Could not start robocopy.'
        }

        # Drain asynchronously to avoid stdout pipe deadlock.
        $stdoutTask =
            $process.StandardOutput.ReadToEndAsync()

        $stderrTask =
            $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {

            $Logger.Error(
                "Robocopy timeout after $TimeoutSeconds seconds."
            )

            try {
                $process.Kill()
            }
            catch {
            }

            try {
                $process.WaitForExit(5000)
            }
            catch {
            }

            throw "Robocopy timeout: $TimeoutSeconds seconds."
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        $exitCode = $process.ExitCode

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {

            foreach ($line in ($stdout -split "`r?`n")) {
                if ($line.Trim()) {
                    $Logger.Info("ROBOCOPY: $($line.Trim())")
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {

            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) {
                    $Logger.Warning(
                        "ROBOCOPY STDERR: $($line.Trim())"
                    )
                }
            }
        }

        # Microsoft: >= 8 = failure.
        if ($exitCode -ge 8) {

            throw "Robocopy failed with exit code $exitCode."
        }

        if ($exitCode -ge 2) {

            $Logger.Warning(
                "Robocopy completed with status $exitCode."
            )
        }
        else {

            $Logger.Success(
                "Robocopy completed with status $exitCode."
            )
        }

        return @{
            ExitCode = $exitCode
        }
    }
    finally {

        try {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
        catch {
        }

        $process.Dispose()
    }
}

# ============================================================================
# BACKUP
# ============================================================================

function Backup-ProfileRegistry {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [string]$BackupFolder,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $backupFile =
        Join-Path $BackupFolder 'ProfileList.reg'

    $profileList =
        'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    $Logger.Info(
        "Backing up ProfileList registry..."
    )

    & "$env:SystemRoot\System32\reg.exe" `
        export `
        $profileList `
        $backupFile `
        /y 2>&1 |
        ForEach-Object {
            $Logger.Info("REG: $_")
        }

    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $backupFile)) {

        throw "ProfileList registry backup failed."
    }

    $Logger.Success(
        "ProfileList backup created: $backupFile"
    )

    return $backupFile
}

function Backup-SourceHive {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [string]$BackupFolder,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $ntUser =
        Join-Path $State.SourceProfile 'NTUSER.DAT'

    if (-not (Test-Path -LiteralPath $ntUser)) {
        throw "Source NTUSER.DAT not found: $ntUser"
    }

    $destination =
        Join-Path $BackupFolder 'NTUSER.DAT'

    Copy-Item `
        -LiteralPath $ntUser `
        -Destination $destination `
        -Force `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $destination)) {
        throw 'NTUSER.DAT backup failed.'
    }

    $Logger.Success(
        "NTUSER.DAT backup created."
    )
}

function Invoke-Backup {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $timestamp =
        Get-Date -Format 'yyyyMMdd_HHmmss'

    $safeUser =
        $State.SourceUser -replace '[\\/:*?"<>|]', '_'

    $backupFolder =
        Join-Path $BackupRoot (
            "ProfileBackup_${safeUser}_$timestamp"
        )

    New-Item `
        -ItemType Directory `
        -Path $backupFolder `
        -Force |
        Out-Null

    $Logger.Info(
        "Backup folder: $backupFolder"
    )

    $args = @(
        '/E'
        '/COPY:DAT'
        '/DCOPY:DAT'
        '/R:3'
        '/W:5'
        '/MT:16'
        '/ZB'
        '/XJ'
        '/NP'
        '/NDL'
        '/NFL'
    )

    Invoke-RobocopyWithTimeout `
        -Source $State.SourceProfile `
        -Destination $backupFolder `
        -Arguments $args `
        -TimeoutSeconds $TimeoutSeconds `
        -Logger $Logger |
        Out-Null

    Backup-SourceHive `
        -State $State `
        -BackupFolder $backupFolder `
        -Logger $Logger

    $registryBackup =
        Backup-ProfileRegistry `
            -State $State `
            -BackupFolder $backupFolder `
            -Logger $Logger

    $State.BackupPath = $backupFolder
    $State.RegistryBackupPath = $registryBackup
    $State.BackupCompleted = $true

    return $backupFolder
}

# ============================================================================
# NTUSER.DAT
# ============================================================================

function Replace-RegistryStringValues {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$OldValue,

        [Parameter(Mandatory)]
        [string]$NewValue,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $count = 0

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return $count
    }

    $keys = New-Object System.Collections.Generic.List[string]

    $stack = New-Object System.Collections.Stack
    $stack.Push($RootPath)

    while ($stack.Count -gt 0) {

        $current = [string]$stack.Pop()

        try {

            $keys.Add($current)

            foreach (
                $subKey in @(
                    Get-ChildItem `
                        -LiteralPath $current `
                        -ErrorAction SilentlyContinue
                )
            ) {
                $stack.Push($subKey.PSPath)
            }
        }
        catch {
        }
    }

    $escapedOld =
        [regex]::Escape($OldValue)

    # $NewValue is used as a regex REPLACEMENT string below. If it contains
    # '$' (e.g. a path like 'C:\Users\Dept$New'), .NET would interpret it as
    # a backreference token ($1, $&, etc.) instead of a literal character.
    # Escaping '$' as '$$' makes the replacement fully literal.
    $literalNewValue =
        $NewValue -replace '\$', '$$$$'

    foreach ($key in $keys) {

        try {

            $properties =
                Get-ItemProperty `
                    -LiteralPath $key `
                    -ErrorAction SilentlyContinue

            if ($null -eq $properties) {
                continue
            }

            foreach ($property in $properties.PSObject.Properties) {

                if ($property.Name -match '^PS') {
                    continue
                }

                if ($property.Value -isnot [string]) {
                    continue
                }

                if (-not $property.Value.Contains($OldValue)) {
                    continue
                }

                $newData =
                    $property.Value -replace $escapedOld, $literalNewValue

                Set-ItemProperty `
                    -LiteralPath $key `
                    -Name $property.Name `
                    -Value $newData `
                    -ErrorAction Stop

                $count++

                $Logger.Info(
                    "Hive value updated: $key\$($property.Name)"
                )
            }
        }
        catch {
            $Logger.Warning(
                "Could not update hive key '$key': $($_.Exception.Message)"
            )
        }
    }

    return $count
}

function Transform-NTUserHive {
    param(
        [Parameter(Mandatory)]
        [string]$NtUserPath,

        [Parameter(Mandatory)]
        [string]$OldPath,

        [Parameter(Mandatory)]
        [string]$NewPath,

        [Parameter(Mandatory)]
        [string]$OldSID,

        [Parameter(Mandatory)]
        [string]$NewSID,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    if (-not (Test-Path -LiteralPath $NtUserPath)) {
        throw "NTUSER.DAT not found: $NtUserPath"
    }

    $hiveName =
        "ProfileMigration_$([Guid]::NewGuid().ToString('N'))"

    $loaded = $false

    try {

        $Logger.Info(
            "Loading hive: $NtUserPath"
        )

        & "$env:SystemRoot\System32\reg.exe" `
            load `
            "HKU\$hiveName" `
            $NtUserPath 2>&1 |
            ForEach-Object {
                $Logger.Info("REG: $_")
            }

        if ($LASTEXITCODE -ne 0) {
            throw "reg load failed with exit code $LASTEXITCODE."
        }

        $loaded = $true

        $root =
            "Registry::HKEY_USERS\$hiveName"

        # Only update locations where absolute profile paths are meaningful.
        $pathRoots = @(
            "$root\Software\Microsoft\Windows\CurrentVersion\Explorer"
            "$root\Software\Microsoft\Windows\CurrentVersion\Run"
            "$root\Software\Microsoft\Windows\CurrentVersion\RunOnce"
            "$root\Software\Microsoft\Windows\CurrentVersion\App Paths"
        )

        $pathCount = 0

        foreach ($pathRoot in $pathRoots) {

            $pathCount +=
                Replace-RegistryStringValues `
                    -RootPath $pathRoot `
                    -OldValue $OldPath `
                    -NewValue $NewPath `
                    -Logger $Logger
        }

        # SID replacement is intentionally restricted.
        $sidCount =
            Replace-RegistryStringValues `
                -RootPath "$root\Software\Microsoft\Windows\CurrentVersion\Explorer" `
                -OldValue $OldSID `
                -NewValue $NewSID `
                -Logger $Logger

        $Logger.Success(
            "NTUSER.DAT transformed: $pathCount path values, $sidCount SID values."
        )
    }
    finally {

        if ($loaded) {

            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()

            Start-Sleep -Milliseconds 500

            & "$env:SystemRoot\System32\reg.exe" `
                unload `
                "HKU\$hiveName" 2>&1 |
                ForEach-Object {
                    $Logger.Info("REG: $_")
                }

            if ($LASTEXITCODE -ne 0) {

                throw (
                    "Could not unload registry hive HKU\$hiveName. " +
                    'A process may still have an open registry handle.'
                )
            }

            $Logger.Info(
                "Hive unloaded: HKU\$hiveName"
            )
        }
    }
}

# ============================================================================
# ACL
# ============================================================================

function Update-ProfileACL {
    param(
        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [Parameter(Mandatory)]
        [string]$SourceSID,

        [Parameter(Mandatory)]
        [string]$TargetSID,

        [Parameter(Mandatory)]
        [string]$TargetUser,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $Logger.Info(
        "Updating ACL: $ProfilePath"
    )

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) {
        throw "Profile path does not exist: $ProfilePath"
    }

    $targetSidObject =
        New-Object System.Security.Principal.SecurityIdentifier(
            $TargetSID
        )

    $sourceSidObject =
        New-Object System.Security.Principal.SecurityIdentifier(
            $SourceSID
        )

    $paths = @(
        $ProfilePath
    )

    # Root ACL first.
    foreach ($path in $paths) {

        $acl =
            Get-Acl -LiteralPath $path -ErrorAction Stop

        $changed = $false

        foreach ($rule in @($acl.Access)) {

            $ruleSid = $null

            try {

                $ruleSid =
                    $rule.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier]
                    )
            }
            catch {
                continue
            }

            if ($ruleSid.Value -ne $SourceSID) {
                continue
            }

            $newRule =
                New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $targetSidObject,
                    $rule.FileSystemRights,
                    $rule.InheritanceFlags,
                    $rule.PropagationFlags,
                    $rule.AccessControlType
                )

            $acl.RemoveAccessRuleSpecific($rule)
            $acl.AddAccessRule($newRule)

            $changed = $true

            $Logger.Info(
                "ACE replaced: $SourceSID -> $TargetSID"
            )
        }

        if ($changed) {

            Set-Acl `
                -LiteralPath $path `
                -AclObject $acl `
                -ErrorAction Stop
        }
    }

    & "$env:SystemRoot\System32\icacls.exe" `
        $ProfilePath `
        /remove:g `
        "*$SourceSID" `
        /T `
        /C `
        /Q 2>&1 |
        ForEach-Object {
            $Logger.Info("ICACLS: $_")
        }

    # icacls returns non-zero if the SID simply isn't present anywhere in
    # the tree; that is not an error condition here, so it is only logged.
    if ($LASTEXITCODE -ne 0) {
        $Logger.Warning(
            "icacls /remove:g for source SID returned exit code $LASTEXITCODE (may simply mean no matching ACE was found)."
        )
    }

    # Explicitly grant target access recursively.
    $grantSpec =
        "*$TargetSID:(OI)(CI)F"

    & "$env:SystemRoot\System32\icacls.exe" `
        $ProfilePath `
        /grant `
        $grantSpec `
        /T `
        /C `
        /Q 2>&1 |
        ForEach-Object {
            $Logger.Info("ICACLS: $_")
        }

    if ($LASTEXITCODE -ne 0) {
        throw "icacls target grant failed with exit code $LASTEXITCODE."
    }

    foreach ($wellKnownSid in @(
        'S-1-5-18'       # NT AUTHORITY\SYSTEM
        'S-1-5-32-544'   # BUILTIN\Administrators
    )) {

        & "$env:SystemRoot\System32\icacls.exe" `
            $ProfilePath `
            /grant `
            "*${wellKnownSid}:(OI)(CI)F" `
            /T `
            /C `
            /Q 2>&1 |
            ForEach-Object {
                $Logger.Info("ICACLS: $_")
            }

        if ($LASTEXITCODE -ne 0) {
            throw "Could not grant access to well-known SID $wellKnownSid."
        }
    }

    $Logger.Success(
        "Profile ACL updated."
    )
}

# ============================================================================
# PROFILELIST
# ============================================================================

function Update-ProfileList {
    param(
        [Parameter(Mandatory)]
        [string]$TargetSID,

        [Parameter(Mandatory)]
        [string]$TargetProfile,

        [Parameter(Mandatory)]
        [string]$SourceSID,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $targetKey =
        Join-Path $script:ProfileListRoot $TargetSID

    $sourceKey =
        Join-Path $script:ProfileListRoot $SourceSID

    $targetKeyExisted =
        Test-Path -LiteralPath $targetKey

    if (-not $targetKeyExisted) {

        New-Item `
            -Path $targetKey `
            -Force |
            Out-Null
    }

    if (-not $targetKeyExisted -and (Test-Path -LiteralPath $sourceKey)) {

        $carryOverNames = @(
            'Flags'
            'State'
            'RefCount'
            'ProfileAttemptedProfileDownloadTimeStamp'
            'ProfileLoadTimeLow'
            'ProfileLoadTimeHigh'
        )

        $sourceProps =
            Get-ItemProperty `
                -LiteralPath $sourceKey `
                -ErrorAction SilentlyContinue

        if ($null -ne $sourceProps) {

            foreach ($name in $carryOverNames) {

                if ($sourceProps.PSObject.Properties.Name -contains $name) {

                    try {

                        New-ItemProperty `
                            -LiteralPath $targetKey `
                            -Name $name `
                            -Value $sourceProps.$name `
                            -PropertyType DWord `
                            -Force |
                            Out-Null

                        $Logger.Info(
                            "ProfileList value carried over: $name"
                        )
                    }
                    catch {

                        $Logger.Warning(
                            "Could not carry over ProfileList value '$name': $($_.Exception.Message)"
                        )
                    }
                }
            }
        }
    }

    New-ItemProperty `
        -LiteralPath $targetKey `
        -Name ProfileImagePath `
        -Value $TargetProfile `
        -PropertyType ExpandString `
        -Force |
        Out-Null

    if ($SourceSID -and $SourceSID -ne $TargetSID) {

        if (Test-Path -LiteralPath $sourceKey) {

            Remove-Item `
                -LiteralPath $sourceKey `
                -Recurse `
                -Force `
                -ErrorAction Stop

            $Logger.Info(
                "Source ProfileList key removed: $SourceSID"
            )
        }
    }

    $Logger.Success(
        "ProfileList updated: $TargetSID -> $TargetProfile"
    )
}

# ============================================================================
# VERIFICATION
# ============================================================================

function Test-TargetProfile {
    param(
        [Parameter(Mandatory)]
        [string]$TargetProfile,

        [Parameter(Mandatory)]
        [string]$TargetSID,

        [Parameter(Mandatory)]
        [string]$TargetUser,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $valid = $true

    if (-not (Test-Path -LiteralPath $TargetProfile -PathType Container)) {

        $Logger.Error(
            "Target profile does not exist: $TargetProfile"
        )

        return $false
    }

    $required = @(
        'NTUSER.DAT'
        'Desktop'
        'Documents'
        'Downloads'
    )

    foreach ($name in $required) {

        $path =
            Join-Path $TargetProfile $name

        if (-not (Test-Path -LiteralPath $path)) {

            $Logger.Warning(
                "Missing target item: $name"
            )

            $valid = $false
        }
    }

    $ntUser =
        Join-Path $TargetProfile 'NTUSER.DAT'

    if (Test-Path -LiteralPath $ntUser) {

        $size =
            (Get-Item -LiteralPath $ntUser).Length

        if ($size -lt 1024) {

            $Logger.Warning(
                "NTUSER.DAT appears invalid: $size bytes"
            )

            $valid = $false
        }
    }

    $profileKey =
        Join-Path $script:ProfileListRoot $TargetSID

    if (-not (Test-Path -LiteralPath $profileKey)) {

        $Logger.Warning(
            "Target ProfileList key missing."
        )

        $valid = $false
    }
    else {

        $registeredPath =
            Get-ItemProperty `
                -LiteralPath $profileKey `
                -Name ProfileImagePath `
                -ErrorAction Stop

        $registered =
            [Environment]::ExpandEnvironmentVariables(
                [string]$registeredPath.ProfileImagePath
            )

        if (
            (Normalize-PathForComparison $registered) -ne
            (Normalize-PathForComparison $TargetProfile)
        ) {

            $Logger.Warning(
                "ProfileList mismatch: $registered"
            )

            $valid = $false
        }
        else {

            $Logger.Info(
                "ProfileList path verified."
            )
        }
    }

    # Verify target SID actually resolves.
    try {

        $sid =
            New-Object System.Security.Principal.SecurityIdentifier(
                $TargetSID
            )

        $null =
            $sid.Translate(
                [System.Security.Principal.NTAccount]
            )

        $Logger.Info(
            "Target SID resolves correctly."
        )
    }
    catch {

        $Logger.Warning(
            "Target SID cannot be translated."
        )

        $valid = $false
    }

    # Verify target ACL using SID translation rather than localized account name.
    try {

        $acl =
            Get-Acl -LiteralPath $TargetProfile

        $targetAccess = $false

        foreach ($rule in @($acl.Access)) {

            try {

                $ruleSid =
                    $rule.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier]
                    )

                if (
                    $ruleSid.Value -eq $TargetSID -and
                    (
                        $rule.FileSystemRights -band
                        [System.Security.AccessControl.FileSystemRights]::FullControl
                    ) -eq
                    [System.Security.AccessControl.FileSystemRights]::FullControl
                ) {

                    $targetAccess = $true
                    break
                }
            }
            catch {
            }
        }

        if (-not $targetAccess) {

            $Logger.Warning(
                "Target SID does not have FullControl on profile root."
            )

            $valid = $false
        }
        else {

            $Logger.Info(
                "Target ACL verified."
            )
        }
    }
    catch {

        $Logger.Warning(
            "Could not verify target ACL: $($_.Exception.Message)"
        )

        $valid = $false
    }

    return $valid
}

function Test-FinalProfile {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $valid =
        Test-TargetProfile `
            -TargetProfile $State.TargetProfile `
            -TargetSID $State.TargetSID `
            -TargetUser $State.TargetUser `
            -Logger $Logger

    if (-not $State.SourceDeleted) {
        return $valid
    }

    if (Test-Path -LiteralPath $State.SourceProfile) {

        $Logger.Warning(
            "Source profile still exists after deletion."
        )

        return $false
    }

    $Logger.Info(
        "Source profile confirmed deleted."
    )

    return $valid
}

# ============================================================================
# ROLLBACK
# ============================================================================

function Invoke-Rollback {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $Logger.Section('ROLLBACK')

    if ($State.SourceDeleted) {

        $Logger.Error(
            'Source profile has already been deleted. Automatic rollback is unsafe.'
        )

        return $false
    }

    if (-not $State.BackupCompleted -or
        [string]::IsNullOrWhiteSpace($State.BackupPath)) {

        $Logger.Error(
            'No usable backup exists. Automatic rollback unavailable.'
        )

        return $false
    }

    $success = $true

    if (Test-Path -LiteralPath $State.BackupPath) {

        try {

            if (Test-Path -LiteralPath $State.TargetProfile) {

                Remove-Item `
                    -LiteralPath $State.TargetProfile `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }

            New-Item `
                -ItemType Directory `
                -Path $State.TargetProfile `
                -Force |
                Out-Null

            $args = @(
                '/E'
                '/COPY:DAT'
                '/DCOPY:DAT'
                '/R:3'
                '/W:5'
                '/MT:16'
                '/ZB'
                '/XJ'
                '/NP'
                '/NDL'
                '/NFL'
            )

            Invoke-RobocopyWithTimeout `
                -Source $State.BackupPath `
                -Destination $State.TargetProfile `
                -Arguments $args `
                -TimeoutSeconds 300 `
                -Logger $Logger |
                Out-Null

            $Logger.Success(
                'Target files restored from backup.'
            )
        }
        catch {

            $Logger.Error(
                "File rollback failed: $($_.Exception.Message)"
            )

            $success = $false
        }
    }

    if (
        $State.RegistryBackupPath -and
        (Test-Path -LiteralPath $State.RegistryBackupPath)
    ) {

        try {

            $Logger.Info(
                "Restoring ProfileList registry..."
            )

            & "$env:SystemRoot\System32\reg.exe" `
                import `
                $State.RegistryBackupPath 2>&1 |
                ForEach-Object {
                    $Logger.Info("REG: $_")
                }

            if ($LASTEXITCODE -ne 0) {

                throw (
                    "reg import failed with exit code $LASTEXITCODE."
                )
            }

            $Logger.Success(
                'ProfileList registry restored.'
            )
        }
        catch {

            $Logger.Error(
                "Registry rollback failed: $($_.Exception.Message)"
            )

            $success = $false
        }
    }

    if ($success) {
        $State.UpdatePhase([MigrationPhase]::ROLLBACK)
        $Logger.Success('Rollback completed.')
    }
    else {
        $State.UpdatePhase([MigrationPhase]::FAILED)
        $Logger.Error(
            'Rollback partially failed. Manual inspection required.'
        )
    }

    return $success
}

# ============================================================================
# REPORT
# ============================================================================

function Show-MigrationReport {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [Logger]$Logger
    )

    $report = @"
MIGRATION REPORT
================================================================

Migration ID : $($State.MigrationId)
Status       : $($State.Phase)

SOURCE
  User       : $($State.SourceUser)
  SID        : $($State.SourceSID)
  Profile    : $($State.SourceProfile)

TARGET
  User       : $($State.TargetUser)
  SID        : $($State.TargetSID)
  Profile    : $($State.TargetProfile)

PHASES
  Backup         : $($State.BackupCompleted)
  Copy           : $($State.CopyCompleted)
  Hive Transform : $($State.HiveTransformed)
  ACL Update     : $($State.ACLUpdated)
  ProfileList    : $($State.ProfileListUpdated)
  Target Verify  : $($State.TargetVerified)
  Commit         : $($State.Committed)
  Source Delete  : $($State.SourceDeleted)
  Final Verify   : $($State.FinalVerified)

BACKUP
  Files          : $($State.BackupPath)
  Registry       : $($State.RegistryBackupPath)

ERRORS
$($State.Errors -join "`r`n")

WARNINGS
$($State.Warnings -join "`r`n")

================================================================
"@

    if (-not $Silent) {
        Write-Host $report
    }

    try {

        $reportPath =
            Join-Path `
                (Split-Path $Logger.LogPath -Parent) `
                "MigrationReport_$($State.MigrationId).json"

        $State.ToJson() |
            Out-File `
                -FilePath $reportPath `
                -Encoding UTF8 `
                -Force

        $Logger.Info(
            "Report saved: $reportPath"
        )
    }
    catch {
    }
}

# ============================================================================
# MIGRATION ENGINE
# ============================================================================

function Start-Migration {
    param(
        [Parameter(Mandatory)]
        [MigrationState]$State,

        [Parameter(Mandatory)]
        [Logger]$Logger,

        [Parameter(Mandatory)]
        [bool]$KeepSource,

        [Parameter(Mandatory)]
        [bool]$Force,

        [Parameter(Mandatory)]
        [bool]$Verify,

        [Parameter(Mandatory)]
        [bool]$SkipNTUserUpdate,

        [Parameter(Mandatory)]
        [int]$TimeoutMinutes,

        [Parameter(Mandatory)]
        [string]$StateFilePath,

        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter(Mandatory)]
        [bool]$BackupRequested
    )

    $timeoutSeconds =
        $TimeoutMinutes * 60

    # ------------------------------------------------------------------------
    # BACKUP
    # ------------------------------------------------------------------------

    if (-not $State.BackupCompleted) {

        $State.UpdatePhase([MigrationPhase]::BACKUP)
        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: BACKUP')

        if ($PSCmdlet.ShouldProcess(
            $State.SourceProfile,
            'Create migration backup'
        )) {

            $backupFolder =
                Invoke-Backup `
                    -State $State `
                    -BackupRoot $BackupRoot `
                    -TimeoutSeconds $timeoutSeconds `
                    -Logger $Logger

            $State.BackupCompleted = $true
            $State.BackupPath = $backupFolder

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger
        }
    }

    if (-not $State.BackupCompleted) {
        throw 'Migration cannot continue without a completed backup.'
    }

    # ------------------------------------------------------------------------
    # COPY
    # ------------------------------------------------------------------------

    if (-not $State.CopyCompleted) {

        $State.UpdatePhase([MigrationPhase]::COPY)

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: COPY')

        if (Test-Path -LiteralPath $State.TargetProfile) {

            if (-not $Force) {

                throw (
                    "Target profile already exists: " +
                    "$($State.TargetProfile). Use -Force."
                )
            }

            if ($PSCmdlet.ShouldProcess(
                $State.TargetProfile,
                'Delete existing target profile'
            )) {

                Remove-Item `
                    -LiteralPath $State.TargetProfile `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
        }

        if ($PSCmdlet.ShouldProcess(
            $State.TargetProfile,
            'Copy source profile'
        )) {

            New-Item `
                -ItemType Directory `
                -Path $State.TargetProfile `
                -Force |
                Out-Null

            $args = @(
                '/E'
                '/COPY:DAT'
                '/DCOPY:DAT'
                '/R:5'
                '/W:10'
                '/MT:32'
                '/ZB'
                '/XJ'
                '/NP'
                '/NDL'
                '/NFL'

                '/XD'
                'Temp'
                'Temporary Internet Files'
                'Cache'
                'INetCache'
            )

            Invoke-RobocopyWithTimeout `
                -Source $State.SourceProfile `
                -Destination $State.TargetProfile `
                -Arguments $args `
                -TimeoutSeconds $timeoutSeconds `
                -Logger $Logger |
                Out-Null

            $State.CopyCompleted = $true

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger
        }
    }

    # ------------------------------------------------------------------------
    # HIVE
    # ------------------------------------------------------------------------

    if (-not $State.HiveTransformed) {

        $State.UpdatePhase([MigrationPhase]::TRANSFORM_HIVE)

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: TRANSFORM_HIVE')

        if ($SkipNTUserUpdate) {

            $Logger.Warning(
                'NTUSER.DAT transformation explicitly skipped.'
            )

            $State.HiveTransformed = $true
        }
        else {

            $ntUser =
                Join-Path $State.TargetProfile 'NTUSER.DAT'

            if (-not (Test-Path -LiteralPath $ntUser)) {

                throw "Target NTUSER.DAT not found: $ntUser"
            }

            if ($PSCmdlet.ShouldProcess(
                $ntUser,
                'Transform NTUSER.DAT'
            )) {

                Transform-NTUserHive `
                    -NtUserPath $ntUser `
                    -OldPath $State.SourceProfile `
                    -NewPath $State.TargetProfile `
                    -OldSID $State.SourceSID `
                    -NewSID $State.TargetSID `
                    -Logger $Logger

                $State.HiveTransformed = $true
            }
        }

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger
    }

    # ------------------------------------------------------------------------
    # ACL
    # ------------------------------------------------------------------------

    if (-not $State.ACLUpdated) {

        $State.UpdatePhase([MigrationPhase]::UPDATE_ACL)

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: UPDATE_ACL')

        if ($PSCmdlet.ShouldProcess(
            $State.TargetProfile,
            'Update target ACL'
        )) {

            Update-ProfileACL `
                -ProfilePath $State.TargetProfile `
                -SourceSID $State.SourceSID `
                -TargetSID $State.TargetSID `
                -TargetUser $State.TargetUser `
                -Logger $Logger

            $State.ACLUpdated = $true

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger
        }
    }

    # ------------------------------------------------------------------------
    # PROFILELIST
    # ------------------------------------------------------------------------

    if (-not $State.ProfileListUpdated) {

        $State.UpdatePhase([MigrationPhase]::UPDATE_PROFILELIST)

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: UPDATE_PROFILELIST')

        if ($PSCmdlet.ShouldProcess(
            $State.TargetSID,
            'Update Windows ProfileList'
        )) {

            Update-ProfileList `
                -TargetSID $State.TargetSID `
                -TargetProfile $State.TargetProfile `
                -SourceSID $State.SourceSID `
                -Logger $Logger

            $State.ProfileListUpdated = $true

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger
        }
    }

    # ------------------------------------------------------------------------
    # VERIFY
    # ------------------------------------------------------------------------

    if ($Verify) {

        if (-not $State.TargetVerified) {

            $State.UpdatePhase([MigrationPhase]::VERIFY_TARGET)

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger

            $Logger.Phase('PHASE: VERIFY_TARGET')

            $State.TargetVerified =
                Test-TargetProfile `
                    -TargetProfile $State.TargetProfile `
                    -TargetSID $State.TargetSID `
                    -TargetUser $State.TargetUser `
                    -Logger $Logger

            if (-not $State.TargetVerified) {
                throw 'Target verification failed.'
            }

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger
        }
    }
    else {

        $Logger.Warning(
            'Target verification skipped because -Verify was not specified.'
        )
    }

    # ------------------------------------------------------------------------
    # COMMIT
    # ------------------------------------------------------------------------

    if (-not $State.Committed) {

        $State.UpdatePhase([MigrationPhase]::COMMIT)

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: COMMIT')

        if ($Verify -and -not $State.TargetVerified) {
            throw 'Commit blocked because target verification failed.'
        }

        if ($PSCmdlet.ShouldProcess(
            $State.TargetProfile,
            'Commit migration'
        )) {

            $State.Committed = $true

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger

            $Logger.Success(
                'Migration committed.'
            )
        }
    }

    # ------------------------------------------------------------------------
    # DELETE SOURCE
    # ------------------------------------------------------------------------

    if (-not $KeepSource -and -not $State.SourceDeleted) {

        if (-not $State.Committed) {
            throw 'Source deletion blocked because migration is not committed.'
        }

        $State.UpdatePhase([MigrationPhase]::DELETE_SOURCE)

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFilePath `
            -Logger $Logger

        $Logger.Phase('PHASE: DELETE_SOURCE')

        if ($PSCmdlet.ShouldProcess(
            $State.SourceProfile,
            'DELETE SOURCE PROFILE'
        )) {

            # Final safety verification immediately before deletion.
            $safety =
                Test-TargetProfile `
                    -TargetProfile $State.TargetProfile `
                    -TargetSID $State.TargetSID `
                    -TargetUser $State.TargetUser `
                    -Logger $Logger

            if (-not $safety) {
                throw (
                    'Source deletion blocked: target profile failed safety verification.'
                )
            }

            $sourceSamAccountName =
                ($State.SourceUser -split '\\')[-1]

            $targetSamAccountName =
                ($State.TargetUser -split '\\')[-1]

            if (
                Test-UserProfileActive `
                    -SID $State.SourceSID `
                    -SamAccountName $sourceSamAccountName
            ) {
                throw (
                    'Source deletion blocked: source account has become ' +
                    'active since the migration started.'
                )
            }

            if (
                Test-UserProfileActive `
                    -SID $State.TargetSID `
                    -SamAccountName $targetSamAccountName
            ) {
                throw (
                    'Source deletion blocked: target account has become ' +
                    'active since the migration started.'
                )
            }

            Remove-Item `
                -LiteralPath $State.SourceProfile `
                -Recurse `
                -Force `
                -ErrorAction Stop

            $State.SourceDeleted = $true

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger

            $Logger.Success(
                "Source profile deleted: $($State.SourceProfile)"
            )
        }
    }
    elseif ($KeepSource) {

        $Logger.Info(
            'Source profile preserved because -KeepSource was specified.'
        )
    }

    # ------------------------------------------------------------------------
    # FINAL VERIFY
    # ------------------------------------------------------------------------

    if ($Verify) {

        if (-not $State.FinalVerified) {

            $State.UpdatePhase([MigrationPhase]::FINAL_VERIFY)

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger

            $Logger.Phase('PHASE: FINAL_VERIFY')

            $State.FinalVerified =
                Test-FinalProfile `
                    -State $State `
                    -Logger $Logger

            if (-not $State.FinalVerified) {

                throw 'Final verification failed.'
            }

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFilePath `
                -Logger $Logger
        }
    }

    # ------------------------------------------------------------------------
    # COMPLETE
    # ------------------------------------------------------------------------

    $State.UpdatePhase([MigrationPhase]::COMPLETED)

    Save-MigrationState `
        -State $State `
        -StateFilePath $StateFilePath `
        -Logger $Logger

    $Logger.Section('MIGRATION COMPLETED')

    return $State
}

# ============================================================================
# MAIN
# ============================================================================

$Logger = $null
$State = $null

try {

    if (-not (Test-IsAdministrator)) {
        throw 'This script must be run from an elevated PowerShell session.'
    }

    $logDirectory =
        Join-Path $env:TEMP 'ProfileMigration'

    if (-not (Test-Path -LiteralPath $logDirectory)) {

        New-Item `
            -ItemType Directory `
            -Path $logDirectory `
            -Force |
            Out-Null
    }

    $logPath =
        Join-Path `
            $logDirectory `
            "ProfileMove_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    $Logger =
        [Logger]::new(
            $logPath,
            $Silent
        )

    $Logger.Section(
        'PROFILE MIGRATION - SAFE VERSION'
    )

    $Logger.Info("Source: $SourceUser")
    $Logger.Info("Target: $TargetUser")
    $Logger.Info("Destination: $DestinationPath")
    $Logger.Info("KeepSource: $KeepSource")
    $Logger.Info("Force: $Force")
    $Logger.Info("Backup: $Backup")
    $Logger.Info("Verify: $Verify")
    $Logger.Info("Resume: $Resume")
    $Logger.Info("Timeout: $TimeoutMinutes minutes")

    if (-not $StateFile) {

        $StateFile =
            Join-Path `
                $logDirectory `
                "state_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).json"
    }

    # ------------------------------------------------------------------------
    # RESUME
    # ------------------------------------------------------------------------

    if ($Resume) {

        $State =
            Load-MigrationState `
                -StateFilePath $StateFile `
                -Logger $Logger

        if ($null -eq $State) {

            throw (
                "Resume requested but state file was not found: $StateFile"
            )
        }

        $Logger.Info(
            "Resuming migration: $($State.MigrationId)"
        )

        # Never resume a completed migration.
        if ($State.Phase -eq [MigrationPhase]::COMPLETED) {

            $Logger.Warning(
                'Migration is already completed.'
            )

            Show-MigrationReport `
                -State $State `
                -Logger $Logger

            exit 0
        }

        # Never automatically continue after a rollback.
        if ($State.Phase -eq [MigrationPhase]::ROLLBACK) {

            throw 'State is in ROLLBACK phase. Start a new migration instead.'
        }

        # Never silently continue a state marked failed.
        if ($State.Phase -eq [MigrationPhase]::FAILED) {

            throw (
                'State is FAILED. Inspect the state/log and start a new migration.'
            )
        }
    }

    # ------------------------------------------------------------------------
    # NEW MIGRATION
    # ------------------------------------------------------------------------

    if ($null -eq $State) {

        $Logger.Section('USER RESOLUTION')

        $sourceInfo =
            [ProfileInfo]::new($SourceUser)

        $targetInfo =
            [ProfileInfo]::new($TargetUser)

        if ($DestinationPath) {

            $targetInfo.UpdateProfilePath(
                $DestinationPath
            )
        }

        $Logger.Info(
            "Source SID: $($sourceInfo.SID)"
        )

        $Logger.Info(
            "Source profile: $($sourceInfo.ProfilePath)"
        )

        $Logger.Info(
            "Target SID: $($targetInfo.SID)"
        )

        $Logger.Info(
            "Target profile: $($targetInfo.ProfilePath)"
        )

        # --------------------------------------------------------------------
        # SAFETY CHECKS
        # --------------------------------------------------------------------

        if ($sourceInfo.SID -eq $targetInfo.SID) {
            throw 'Source and target accounts cannot be identical.'
        }

        if (-not $sourceInfo.ProfileExists) {
            throw "Source profile not found: $($sourceInfo.ProfilePath)"
        }

        if ($sourceInfo.IsActive) {
            throw 'Source user appears to be active. Log off before migration.'
        }

        if ($targetInfo.IsActive) {
            throw 'Target user appears to be active. Log off before migration.'
        }

        if (
            (Normalize-PathForComparison $sourceInfo.ProfilePath) -eq
            (Normalize-PathForComparison $targetInfo.ProfilePath)
        ) {
            throw 'Source and target profile paths cannot be identical.'
        }

        if (
            Test-PathInsidePath `
                -ChildPath $targetInfo.ProfilePath `
                -ParentPath $sourceInfo.ProfilePath
        ) {
            throw (
                'Target profile cannot be located inside the source profile.'
            )
        }

        if (
            Test-PathInsidePath `
                -ChildPath $sourceInfo.ProfilePath `
                -ParentPath $targetInfo.ProfilePath
        ) {
            throw (
                'Target profile cannot be a parent of the source profile.'
            )
        }

        if (
            (Normalize-PathForComparison $targetInfo.ProfilePath) -eq
            (Normalize-PathForComparison $env:SystemRoot)
        ) {
            throw 'SystemRoot cannot be used as target profile.'
        }

        if ($targetInfo.ProfileExists -and -not $Force) {

            throw (
                "Target profile already exists: " +
                "$($targetInfo.ProfilePath). Use -Force."
            )
        }

        if (-not $Backup) {

            $Logger.Warning(
                '-Backup was not specified; the safe engine will still create a mandatory rollback backup.'
            )
        }

        $State =
            [MigrationState]::new()

        $State.SourceUser =
            $sourceInfo.NTAccount

        $State.SourceSID =
            $sourceInfo.SID

        $State.SourceProfile =
            $sourceInfo.ProfilePath

        $State.TargetUser =
            $targetInfo.NTAccount

        $State.TargetSID =
            $targetInfo.SID

        $State.TargetProfile =
            $targetInfo.ProfilePath

        $State.UpdatePhase(
            [MigrationPhase]::INIT
        )

        Save-MigrationState `
            -State $State `
            -StateFilePath $StateFile `
            -Logger $Logger

        $Logger.Success(
            "Migration initialized: $($State.MigrationId)"
        )
    }

    # ------------------------------------------------------------------------
    # WHATIF
    # ------------------------------------------------------------------------

    if ($WhatIfPreference) {

        $Logger.Warning(
            'WHATIF: no modifications will be made.'
        )

        Show-MigrationReport `
            -State $State `
            -Logger $Logger

        exit 0
    }

    # ------------------------------------------------------------------------
    # BACKUP ROOT
    # ------------------------------------------------------------------------

    $backupRootFinal = $null

    if ($BackupPath) {
        $backupRootFinal = $BackupPath
    }
    elseif ($State.BackupPath -and
            (Test-Path -LiteralPath $State.BackupPath -PathType Container)) {

        $backupRootFinal =
            Split-Path -Path $State.BackupPath -Parent
    }
    else {

        $backupRootFinal =
            Join-Path $env:TEMP 'ProfileMigration\Backup'
    }

    if (-not (Test-Path -LiteralPath $backupRootFinal)) {

        New-Item `
            -ItemType Directory `
            -Path $backupRootFinal `
            -Force |
            Out-Null
    }

    # ------------------------------------------------------------------------
    # ENGINE
    # ------------------------------------------------------------------------

    try {

        $State =
            Start-Migration `
                -State $State `
                -Logger $Logger `
                -KeepSource $KeepSource `
                -Force $Force `
                -Verify $Verify `
                -SkipNTUserUpdate $SkipNTUserUpdate `
                -TimeoutMinutes $TimeoutMinutes `
                -StateFilePath $StateFile `
                -BackupRoot $backupRootFinal `
                -BackupRequested $Backup

    }
    catch {

        $message =
            $_.Exception.Message

        $Logger.Error(
            "Migration failed: $message"
        )

        $State.AddError($message)
        $State.UpdatePhase([MigrationPhase]::FAILED)

        try {

            Save-MigrationState `
                -State $State `
                -StateFilePath $StateFile `
                -Logger $Logger
        }
        catch {
        }

        if (
            $State.BackupCompleted -and
            -not $State.Committed -and
            -not $State.SourceDeleted
        ) {

            $Logger.Warning(
                'Migration failed before commit. Starting automatic rollback.'
            )

            try {

                Invoke-Rollback `
                    -State $State `
                    -Logger $Logger |
                    Out-Null

            }
            catch {

                $Logger.Error(
                    "Rollback exception: $($_.Exception.Message)"
                )
            }
        }
        else {

            $Logger.Warning(
                'Automatic rollback is not safe after commit/source deletion.'
            )
        }

        throw
    }

    Show-MigrationReport `
        -State $State `
        -Logger $Logger

    if ($State.Phase -eq [MigrationPhase]::COMPLETED) {

        $Logger.Success(
            'Migration completed successfully.'
        )

        $Logger.Success(
            "Target: $($State.TargetProfile)"
        )

        if ($KeepSource) {

            $Logger.Info(
                "Source preserved: $($State.SourceProfile)"
            )
        }
        elseif ($State.SourceDeleted) {

            $Logger.Info(
                "Source deleted: $($State.SourceProfile)"
            )
        }

        exit 0
    }

    exit 1
}
catch {

    if ($null -ne $Logger) {

        $Logger.Error(
            "CRITICAL ERROR: $($_.Exception.Message)"
        )

        if ($_.ScriptStackTrace) {

            $Logger.Error(
                "Stack: $($_.ScriptStackTrace)"
            )
        }
    }

    exit 1
}