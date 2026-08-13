[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gitExecutable = 'C:\Program Files\Git\cmd\git.exe'
$logPath = Join-Path $repositoryPath 'auto-git-backup.log'
$mutex = New-Object System.Threading.Mutex($false, 'Local\IsamBuddha2023GitAutoBackup')
$hasLock = $false

function Write-BackupLog {
    param([string]$Message)

    Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')] $Message" -Encoding UTF8
}

function Invoke-Git {
    param([string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $output = @(& $gitExecutable -C $repositoryPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Text = ($output -join [Environment]::NewLine).Trim()
    }
}

try {
    $hasLock = $mutex.WaitOne(0)

    if (-not $hasLock) {
        exit 0
    }

    $remoteHead = Invoke-Git @('ls-remote', '--heads', 'origin', 'refs/heads/main')

    if ($remoteHead.ExitCode -eq 0 -and $remoteHead.Text) {
        $remoteHash = ($remoteHead.Text -split '\s+')[0]
        $knownRemoteCommit = Invoke-Git @('cat-file', '-e', "$remoteHash`^{commit}")

        if ($knownRemoteCommit.ExitCode -ne 0) {
            Write-BackupLog 'Push dilewati: GitHub memiliki commit yang belum tersedia secara lokal.'
            exit 2
        }

        $remoteIsAncestor = Invoke-Git @('merge-base', '--is-ancestor', $remoteHash, 'HEAD')

        if ($remoteIsAncestor.ExitCode -eq 1) {
            Write-BackupLog 'Push dilewati: riwayat GitHub berbeda. Lakukan pull/rebase secara manual.'
            exit 2
        }
        elseif ($remoteIsAncestor.ExitCode -ne 0) {
            Write-BackupLog "Gagal memeriksa posisi branch: $($remoteIsAncestor.Text)"
            exit 1
        }
    }
    elseif ($remoteHead.ExitCode -ne 0) {
        Write-BackupLog "Peringatan: GitHub tidak dapat diperiksa. Perubahan tetap dicommit lokal. $($remoteHead.Text)"
    }

    $status = Invoke-Git @('status', '--porcelain', '--untracked-files=all')

    if ($status.ExitCode -ne 0) {
        Write-BackupLog "Gagal membaca status Git: $($status.Text)"
        exit 1
    }

    if ($status.Text) {
        $add = Invoke-Git @('add', '-A')

        if ($add.ExitCode -ne 0) {
            Write-BackupLog "Gagal menambahkan perubahan: $($add.Text)"
            exit 1
        }

        $staged = Invoke-Git @('diff', '--cached', '--quiet')

        if ($staged.ExitCode -eq 1) {
            $message = 'Automated backup: {0} WIB' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            $commit = Invoke-Git @('commit', '-m', $message)

            if ($commit.ExitCode -ne 0) {
                Write-BackupLog "Gagal membuat commit: $($commit.Text)"
                exit 1
            }

            Write-BackupLog "Commit dibuat: $message"
        }
        elseif ($staged.ExitCode -ne 0) {
            Write-BackupLog "Gagal memeriksa staging: $($staged.Text)"
            exit 1
        }
    }

    $push = Invoke-Git @('push', '--quiet', 'origin', 'HEAD:main')

    if ($push.ExitCode -ne 0) {
        Write-BackupLog "Push gagal dan akan dicoba lagi: $($push.Text)"
        exit 1
    }

    if ($status.Text) {
        Write-BackupLog 'Backup berhasil dipush ke origin/main.'
    }
}
catch {
    Write-BackupLog "Kesalahan tak terduga: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($hasLock) {
        $mutex.ReleaseMutex()
    }

    $mutex.Dispose()
}
