# =============================================
# PowerShell Script: SQL Server Backup Utility
# Dev Script By: Meshary Alali
# =============================================

# Temporarily bypass ExecutionPolicy for this process
#Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force



function Is-ValidDatabaseName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + '\'
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.IndexOfAny($invalid) -ge 0) { return $false }
    return $Name -match '^[a-zA-Z0-9_\-]+$'
}

function Is-ValidPath {
    param([string]$Path)
    $invalid = [System.IO.Path]::GetInvalidPathChars()
    return ($Path.IndexOfAny($invalid) -lt 0)
}

function Is-ValidRootedPath {
    param([string]$Path)
    # تحقق أن المسار يبدأ بحرف قرص متبوع بـ :\
    if ($Path -match '^[a-zA-Z]:\\') {
        $drive = $Path.Substring(0, 2)
        # تحقق أن القرص موجود فعلاً
        return (Test-Path "$drive\")
    }
    return $false
}

function CenterText($text, $width) {
    if ($null -eq $text) { $text = "" }
    $text = "$text"
    if ($text.Length -ge $width) { return $text.Substring(0, $width) }
    $pad = $width - $text.Length
    $left = [Math]::Floor($pad / 2)
    $right = $pad - $left
    return (" " * $left) + $text + (" " * $right)
}

# ----------- User Input -----------

# 1. Server Name Input Loop & Authentication
do {
    $serverInstance = Read-Host "Enter Server Name (e.g. localhost or IP)"
    $useWindowsAuth = Read-Host "Use Windows Authentication? (Y/N)"
    $useWindowsAuth = $useWindowsAuth.Trim().ToUpper()
    $username = $null
    $password = $null

    if ($useWindowsAuth -eq "Y") {
        $connectionString = "Server=$serverInstance;Database=master;Trusted_Connection=True;"
    } else {
        $credential = Get-Credential -Message "Enter SQL Server Login"
        $username = $credential.UserName
        $password = $credential.GetNetworkCredential().Password
        $connectionString = "Server=$serverInstance;Database=master;User ID=$username;Password=$password;"
    }

    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()
        $connection.Close()
        break
    } catch {
        Write-Host "`n Failed to connect to server using provided credentials." -ForegroundColor Red
        Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Yellow
        $tryAgain = Read-Host "Do you want to try another server or credentials? (Y/N)"
        if ($tryAgain.Trim().ToUpper() -ne "Y") {
            Read-Host "Press any key to exit..."
            exit
        }
    }
} while ($true)

# 2. Database Name Input and Existence Check Loop
do {
    do {
        $database = Read-Host "Enter Database Name"
        if (-not (Is-ValidDatabaseName $database)) {
            Write-Host "Invalid database name format. Use only [A-Z][a-z][0-9] _ -" -ForegroundColor Red
            $tryAgain = Read-Host "Do you want to try again? (Y/N)"
            if ($tryAgain.Trim().ToUpper() -ne "Y") {
                Read-Host "Press any key to exit..."
                exit
            }
        }
    } while (-not (Is-ValidDatabaseName $database))

    try {
        if ($useWindowsAuth -eq "Y") {
            $connectionString = "Server=$serverInstance;Database=master;Trusted_Connection=True;"
        } else {
            $connectionString = "Server=$serverInstance;Database=master;User ID=$username;Password=$password;"
        }
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()
        $checkDbQuery = "SELECT name FROM sys.databases WHERE name = @dbName"
        $checkDbCmd = $connection.CreateCommand()
        $checkDbCmd.CommandText = $checkDbQuery
        $param = $checkDbCmd.Parameters.Add("@dbName", [System.Data.SqlDbType]::NVarChar, 128)
        $param.Value = $database
        $dbExists = $checkDbCmd.ExecuteScalar()
        $connection.Close()
        if (-not $dbExists) {
            Write-Host "`nDatabase '$database' does not exist." -ForegroundColor Red
            $tryAgain = Read-Host "Do you want to enter a different database name? (Y/N)"
            if ($tryAgain.Trim().ToUpper() -ne "Y") {
                Read-Host "Press any key to exit..."
                exit
            } else {
                $database = $null
            }
        } else {
            break
        }
    } catch {
        Write-Host "Failed while checking database existence." -ForegroundColor Red
        Write-Host "Details: $($_.Exception | Format-List * -Force | Out-String)" -ForegroundColor Yellow
        if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
        Read-Host "Press any key to exit..."
        exit
    }
} while ($true)

# 3. Backup Path Input Loop (مطور)
do {
    $backupDir = Read-Host "Enter Backup Path (e.g. C:\SQLBackups)"
    if (-not (Is-ValidPath $backupDir)) {
        Write-Host "Backup path contains invalid characters." -ForegroundColor Red
    }
    elseif (-not (Is-ValidRootedPath $backupDir)) {
        Write-Host "Backup path must start with a valid drive letter (e.g. C:\SQLBackups) and the drive must exist." -ForegroundColor Red
    }
    else {
        break
    }
    $tryAgain = Read-Host "Do you want to try again? (Y/N)"
    if ($tryAgain.Trim().ToUpper() -ne "Y") {
        Read-Host "Press any key to exit..."
        exit
    }
} while ($true)

# Ensure path is valid
if (-not (Test-Path $backupDir)) {
    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    } catch {
        Write-Host "Failed to create or access directory: $backupDir" -ForegroundColor Red
        Write-Host "Details: $($_.Exception | Format-List * -Force | Out-String)" -ForegroundColor Yellow
        Read-Host "Press any key to exit..."
        exit
    }
}

# Update connection string to point to actual DB
if ($useWindowsAuth -eq "Y") {
    $connectionString = "Server=$serverInstance;Database=$database;Trusted_Connection=True;"
} else {
    $connectionString = "Server=$serverInstance;Database=$database;User ID=$username;Password=$password;"
}
$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
$connection.Open()

# ========== Generate File Names ==========
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFileName = "${database}_Backup_$timestamp.bak"
$txtFileName = "BackupReport_${database}_$timestamp.txt"
$backupPath = Join-Path $backupDir $backupFileName
$txtPath = Join-Path $backupDir $txtFileName

# Validate backup path (file name)
if ([System.IO.Path]::GetInvalidFileNameChars() | ForEach-Object { $backupFileName.Contains($_) } | Where-Object { $_ }) {
    Write-Host "Invalid backup file name." -ForegroundColor Red
    Read-Host "Press any key to exit..."
    exit
}

try {
    # ========== Check Stored Procedure ==========
    $spCheckQuery = "SELECT COUNT(*) FROM sys.objects WHERE type = 'P' AND name = @spName"
    $spCmd = $connection.CreateCommand()
    $spCmd.CommandText = $spCheckQuery
    $spParam = $spCmd.Parameters.Add("@spName", [System.Data.SqlDbType]::NVarChar, 128)
    $spParam.Value = "ReportBackup"
    $spExists = $spCmd.ExecuteScalar()

    if ($spExists -eq 0) {
        Write-Host "`n Stored Procedure 'ReportBackup' does not exist in the database." -ForegroundColor Red
        Write-Host "This script requires the stored procedure [dbo].[ReportBackup]." -ForegroundColor Yellow
        Read-Host "Press any key to exit..."
        exit
    }

    # ========== 1. Get DB Size Info ==========
    $command = $connection.CreateCommand()
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $command.CommandText = "dbo.ReportBackup"
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $dataSet = New-Object System.Data.DataSet
    $adapter.Fill($dataSet) | Out-Null
    $results = $dataSet.Tables[0]

    # ========== 2. Get SQL Server Info ==========
    $infoQuery = "SELECT SERVERPROPERTY('ProductVersion') AS ProductVersion, SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('ProductLevel') AS ProductLevel;"
    $infoCommand = $connection.CreateCommand()
    $infoCommand.CommandText = $infoQuery
    $infoAdapter = New-Object System.Data.SqlClient.SqlDataAdapter $infoCommand
    $infoDataSet = New-Object System.Data.DataSet
    $infoAdapter.Fill($infoDataSet) | Out-Null
    $infoRow = $infoDataSet.Tables[0].Rows[0]

    # ========== 3. Backup Database ==========
    $escapedPath = $backupPath.Replace("\", "\\")
    $backupQuery = "BACKUP DATABASE [$database] TO DISK = N'$escapedPath' WITH INIT, FORMAT"
    $backupCmd = $connection.CreateCommand()
    $backupCmd.CommandText = $backupQuery
    $backupCmd.ExecuteNonQuery()

    # ========== 4. Verify Backup ==========
    $verifyQuery = "RESTORE VERIFYONLY FROM DISK = N'$escapedPath'"
    $verifyCmd = $connection.CreateCommand()
    $verifyCmd.CommandText = $verifyQuery
    try {
        $verifyCmd.ExecuteNonQuery() | Out-Null
        $verifyStatus = "Passed"
    } catch {
        $verifyStatus = "Failed: $($_.Exception.Message)"
    }

    # ========== 5. Create Report ==========
    $cleanedResults = $results | Select-Object Database_Name, Date_Report, Schema_Name, Object_Name, Object_Type, Count_Rows, SizeMB
    $backupDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $backupSizeMB = if (Test-Path $backupPath) { [math]::Round(((Get-Item $backupPath).Length / 1MB), 2) } else { "N/A" }
    $backupStatus = if (Test-Path $backupPath) { "Completed" } else { "Error" }

    # ----------- Centered Table Output -----------
    $widths = @{
        Database_Name = 25
        Date_Report   = 19
        Schema_Name   = 15
        Object_Name   = 30
        Object_Type = 30
        Count_Rows = 12
        SizeMB         = 12
    }

    $header = (
        (CenterText "Database_Name" $widths.Database_Name) +
        (CenterText "Date_Report"   $widths.Date_Report) +
        (CenterText "Schema_Name"   $widths.Schema_Name) +
        (CenterText "Object_Name"   $widths.Object_Name) +
        (CenterText "Object_Type" $widths.Object_Type) +
        (CenterText "Count_Rows" $widths.Count_Rows) +
        (CenterText "SizeMB"         $widths.SizeMB)
    )

    $lines = @($header)
    foreach ($row in $cleanedResults) {
        $lines += (
            (CenterText $row.Database_Name $widths.Database_Name) +
            (CenterText $row.Date_Report   $widths.Date_Report) +
            (CenterText $row.Schema_Name   $widths.Schema_Name) +
            (CenterText $row.Object_Name   $widths.Object_Name) +
            (CenterText $row.Object_Type   $widths.Object_Type) +
            (CenterText $row.Count_Rows $widths.Count_Rows) +
            (CenterText $row.SizeMB $widths.SizeMB)
        )
    }
    $tableText = $lines -join "`r`n"

    $txtContent = @"
SQL Server Info:
 - Version       : $($infoRow.ProductVersion)
 - Edition       : $($infoRow.Edition)
 - Product Level : $($infoRow.ProductLevel)

--------------------------------------------
Database Objects:
$tableText

--------------------------------------------
Backup Info:
 - Backup Date   : $backupDate
 - Backup Size   : $backupSizeMB MB
 - Status        : $backupStatus
 - Verify Status : $verifyStatus

--------------------------------------------
             End Report
--------------------------------------------
Dev Script By Meshary Alali
--------------------------------------------
"@

    Set-Content -Path $txtPath -Value $txtContent -Encoding UTF8

    Write-Host "`n All Tasks Completed Successfully!" -ForegroundColor Green
    Write-Host " Report Saved: $txtPath" -ForegroundColor Cyan
    Write-Host " Backup Saved: $backupPath" -ForegroundColor Cyan

}
catch {
    Write-Host "`n An error occurred:" -ForegroundColor Red
    Write-Host "Details: $($_.Exception | Format-List * -Force | Out-String)" -ForegroundColor Yellow

}
finally {
    if ($connection -and $connection.State -eq 'Open') {
        $connection.Close()
    }
    Read-Host "Press any key to exit..."
    exit
}
