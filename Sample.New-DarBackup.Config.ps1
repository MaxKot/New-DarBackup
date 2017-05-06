$local:DefaultTarget = @(
    @{
        Target = 't-profile-main';
        Name = 'profile-{0:yyyy-MM-dd}-{1}';
        NameParser = '^profile-(?<date>\d{4}-\d{2}-\d{2})-(?<kind>full|diff)$';
    },
    @{
        Target = 't-profile-private';
        Name = 'profile-{0:yyyy-MM-dd}-{1}-private';
        NameParser = '^profile-(?<date>\d{4}-\d{2}-\d{2})-(?<kind>full|diff)-private$';
    }
);
$local:DefaultDarConfig = Join-Path $PSScriptRoot 'New-DarBackup.Config.dcf';
$local:DefaultBackupPath = '\\NAS\Backup\dar';
$local:DefaultLogPath = '';
$local:DefaultDarPath = 'C:\Program Files (x86)\dar\dar.exe';
$local:DefaultFullSuffix = 'full';
$local:DefaultDiffSuffix = 'diff';
$local:DefaultIncompleteBackupHandling = 'Delete';
$local:MaxDiffBackupsSinceLastFull = 31;
$local:MaxDiffBackupSizeToFullBackupSizeRatio = 0.10;
