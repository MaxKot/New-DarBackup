[CmdletBinding(SupportsShouldProcess=$true)]
param
(
    [Parameter(Mandatory = $false, Position = 0)]
    [Object[]] $Target,

    [Parameter(Mandatory = $false)]
    [String] $Config,

    [Parameter(Mandatory = $false)]
    [String] $DarConfig,

    [Parameter(Mandatory = $false)]
    [String] $BackupPath,

    [Parameter(Mandatory = $false)]
    [String] $LogPath,

    [Parameter(Mandatory = $false)]
    [String] $FullSuffix,

    [Parameter(Mandatory = $false)]
    [String] $DiffSuffix,

    [Parameter(Mandatory = $false)]
    [String] $DarPath,

    [Parameter(Mandatory = $false)]
    [Switch][Boolean] $DisableTiming = $false,

    [Parameter(Mandatory = $false, ParameterSetName = 'Auto')]
    [Switch][Boolean] $Auto,

    [Parameter(Mandatory = $true, ParameterSetName = 'Full')]
    [Switch][Boolean] $Full,

    [Parameter(Mandatory = $true, ParameterSetName = 'Diff')]
    [Switch][Boolean] $Diff
);

# Function declarations.
# =============================

function Get-CygwinPath
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $Path
    );

    if(-not (Split-Path -IsAbsolute -Path $Path) -and $Path -notlike '\\*')
    {
        throw "Expected an aboslute path, got: '$Path'.";
    }

    # Have to treat UNC paths in a special way.
    if($Path -like '\\*')
    {
        $cygQualifier = '/';
        $Path = $Path.Substring(2);
    }
    else
    {
        $qualifier = Split-Path -Qualifier -Path $Path;
        if($qualifier -like '*:')
        {
            $cygQualifier = '/cygdrive/' + $qualifier.Substring(0, $qualifier.Length - 1).ToLower();
        }
        else
        {
            $cygQualifier = $qualifier;
        }
    }
    Write-Debug "qualifier: '$qualifier', cygQualifier: '$cygQualifier'.";

    $parts = New-Object -TypeName System.Collections.Generic.Stack[string];
    $remainingPath = Split-Path -NoQualifier -Path $Path;
    Write-Debug "remainingPath: '$remainingPath'.";
    while($remainingPath -ne '' -and $remainingPath -ne '\')
    {
        $leaf = Split-Path -Leaf -Path $remainingPath;
        $parts.Push($leaf);
        $remainingPath = Split-Path -Parent -Path $remainingPath;
        Write-Debug "remainingPath: '$remainingPath', leaf: $leaf, parts: [$([String]::Join(', ', ($parts | %{ `"'$_'`" })))].";
    }

    $allParts = @(,$cygQualifier) + $parts;
    $cygPath = [String]::Join('/', $allParts);
    Write-Verbose "Translated Windows path '$Path' to Cygwin path '$cygPath'. Cygwin path parts: [$([String]::Join(', ', ($allParts | %{ `"'$_'`" })))].";
    return $cygPath;
}

function Write-Timing
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $Format,
        [Parameter(Mandatory = $false)]
        [DateTime] $Time
    );

    if(-not $DisableTiming)
    {
        if($Time -eq $null)
        {
            $Time = Get-Date;
        }
        Write-Host ($Format -f $Time) -ForegroundColor Cyan;
    }
}

function New-Target
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [Object] $Template,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String] $FullSuffix,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [String] $DiffSuffix
    );

    Begin
    {
        $index = 0;
    }
    Process
    {
        function New-NameFunction
        {
            [CmdletBinding()]
            param
            (
                [Parameter(Mandatory = $true, Position = 0)]
                [Object] $Source
            );

            if($Source -is [String])
            {
                return {
                    [CmdletBinding()]
                    param
                    (
                        [Parameter(Mandatory = $true, Position = 0)]
                        [DateTime] $Date,

                        [Parameter(Mandatory = $true, Position = 1)]
                        [AllowEmptyString()]
                        [String] $Kind
                    );

                    return $Source -f $Date, $Kind;
                }.GetNewClosure();
            }
            elseif($Source -is [scriptblock])
            {
                return $Source;
            }
            else
            {
                throw 'Unexpected name format type. Expected String or ScriptBlock.';
            }
        }

        function New-NameParserFunction
        {
            [CmdletBinding()]
            param
            (
                [Parameter(Mandatory = $true, Position = 0)]
                [Object] $Source,

                [Parameter(Mandatory = $true)]
                [AllowEmptyString()]
                [String] $FullSuffix,
        
                [Parameter(Mandatory = $true)]
                [AllowEmptyString()]
                [String] $DiffSuffix
            );

            if($Source -is [String])
            {
                $Source = [regex] $Source;
            }
        
            if($Source -is [regex])
            {
                return {
                    [CmdletBinding()]
                    param
                    (
                        [Parameter(Mandatory = $true, Position = 0)]
                        [AllowEmptyString()]
                        [String] $Name
                    );

                    $m = $Source.Match($Name);
                    Write-Verbose "Matching name '$Name' again regular expression '$Source'. Match: $m.";

                    $ds = $m.Groups['date'];
                    if($ds -eq $null)
                    {
                        $ds = $m.Groups[1];
                    };
                    $ks = $m.Groups['kind'];
                    if($ks -eq $null)
                    {
                        $ks = $m.Groups[2];
                    };

                    $d = [DateTime]::MinValue;
                    $match = `
                        $m.Success -and `
                        $ds -ne $null -and [DateTime]::TryParse($ds.Value, [ref] $d) -and `
                        $ks -ne $null -and ($ks.Value -eq $FullSuffix -or $ks.Value -eq $DiffSuffix);
                                
                    if($match)
                    {
                        return @{
                            Date = $d;
                            Kind = $ks.Value;
                        };
                    }
                    else
                    {
                        return $null;
                    }
                }.GetNewClosure();
            }
            elseif($Source -is [scriptblock])
            {
                return $Source;
            }
            else
            {
                throw 'Unexpected name format parser type. Expected String, Regex or ScriptBlock.';
            }
        }

        $target = $null;
        $name = $null;
        $nameParser = $null;

        if($Template -eq $null)
        {
            Write-Error "Target at index $index is null. Expected String, Hashtable or object.";
        }
        elseif($Template -is [String])
        {
            $target = $Template;
            $name = "$($Template.Replace('{', '{{').Replace('}', '}}'))-{0:yyyy-MM-dd}-{1}";
            $nameParser = "$([regex]::Escape($name))-(?<date>\d{4}-\d{2}-\d{2})-(?<kind>\w+)";

            Write-Verbose "Automatically generated pattern from target name. Target: '$target', name format: '$name', name inspection pattern: '$nameParser'.";
        }
        elseif($Template -is [Hashtable])
        {
            $target = $Template['Target'];
            $name = $Template['Name'];
            $nameParser = $Template['NameParser'];

            Write-Verbose "Read target parameters from hash table. Target: '$target', name format: '$name', name inspection pattern: '$nameParser'.";
        }
        else
        {
            $target = $Template.Target;
            $name = $Template.Name;
            $nameParser = $Template.NameParser;

            Write-Verbose "Read target parameters from an object. Target: '$target', name format: '$name', name inspection pattern: '$nameParser'.";
        }

        $result = New-Object -TypeName psobject -Property @{
            Target = $target;
            Name = (New-NameFunction -Source $name);
            NameParser = (New-NameParserFunction -Source $nameParser -FullSuffix $FullSuffix -DiffSuffix $DiffSuffix);
        };
        Write-Output $result;

        ++$index;
    }
    End
    {

    }
}

function Get-BackupParameter
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [Object] $Target
    );

    function Get-ExistingBackup
    {
        [CmdletBinding()]
        param
        (
            [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
            [Object] $Target
        );

        $backups = @{
            $FullSuffix = @();
            $DiffSuffix = @();
        };
        foreach($file in Get-ChildItem -Path $BackupPath -Filter '*.dar')
        {
            $fileName = $file.Name;
            $partName = [System.IO.Path]::GetFileNameWithoutExtension($fileName);
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($partName);
            Write-Verbose "Checking a possible backup file. Filename: '$fileName'. Detected base name: '$baseName'.";

            $backupInfo = & $to.NameParser -Name $baseName;
            if($backupInfo -ne $null)
            {
                Write-Verbose "Found a backup file of current target. Filename: '$fileName'.";
                $backup = @{ File = $file; BaseName = $baseName; } + $backupInfo;
                $backups[$backup.Kind] += @(,$backup);
            }
            else
            {
                Write-Verbose "File is not a backup of current target. Filename: '$fileName'.";
            }
        }

        return $backups;
    }

    function Get-LastBackup
    {
        [CmdletBinding()]
        param
        (
            [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
            [AllowNull()]
            [Object] $Backup
        );

        $lastBackup = $Backup |
            Sort-Object -Property { return $_.Date; } -Descending |
            Select-Object -First 1;
        return $lastBackup;
    }

    $kind = '';
    $referenceBackup = $null;

    if($Full)
    {
        $kind = $FullSuffix;
        $referenceBackup = $null;
    }
    elseif($Diff)
    {
        $backups = Get-ExistingBackup -Target $Target;
        $lastFullBackup = Get-LastBackup -Backup $backups[$FullSuffix];
        if($lastFullBackup -eq $null)
        {
            throw 'Unable to perform diff backup - reference backup could not be determined.';
        }

        $kind = $DiffSuffix;
        $referenceBackup = $lastFullBackup.BaseName;
    }
    elseif($Auto)
    {
        $backups = Get-ExistingBackup -Target $Target;
        $lastFullBackup = Get-LastBackup -Backup $backups[$FullSuffix];

        if($lastFullBackup -eq $null -or $lastFullBackup.File.Length -le 0)
        {
            Write-Verbose "Creating a full backup - full backups not found.";
            $kind = $FullSuffix;
            $referenceBackup = $null;
        }
        else
        {
            $lastFullBackupDate = $lastFullBackup.Date;

            $diffBackupsSinceLastFull = $backups[$DiffSuffix] |
                ?{ $_.Date -gt $lastFullBackupDate; };

            if($diffBackupsSinceLastFull.Count -gt $MaxDiffBackupsSinceLastFull)
            {
                Write-Verbose "Creating a full backup - there are too many diff backups. Diff backups count: $($diffBackupsSinceLastFull.Count).";
                $kind = $FullSuffix;
                $referenceBackup = $null;
            }
            else
            {
                $lastFullBackupSize = $lastFullBackup.File.Length;
                $lastDiffBackupSize = Get-LastBackup -Backup $diffBackupsSinceLastFull |
                    %{ return $_.File.Length; };

                if($lastDiffBackupSize / $lastFullBackupSize -ge $MaxDiffBackupSizeToFullBackupSizeRatio)
                {
                    Write-Verbose "Creating a full backup - last diff backup was too large. Last full backup size: $lastFullBackupSize. Last diff backup size: $lastDiffBackupSize.";
                    $kind = $FullSuffix;
                    $referenceBackup = $null;
                }
                else
                {
                    Write-Verbose "Creating a diff backup.";
                    $kind = $DiffSuffix;
                    $referenceBackup = $lastFullBackup.BaseName;
                }
            }
        }
    }
    else
    {
        throw 'Unrecognized backup kind settings.';
    }

    return @{
        Kind = $kind;
        ReferenceBackup = $referenceBackup;
    };
}

# Script body.
# =============================

$private:start = Get-Date;
Write-Timing -Format 'Backup script started at {0:O}' -Time $private:start;

# Apply configuration file.
# =============================
if([String]::IsNullOrWhiteSpace($Config))
{
    $Config = Join-Path $PSScriptRoot 'New-DarBackup.Config.ps1';
    if(Test-Path $Config)
    {
        .$Config
    }
    else
    {
        Write-Warning "Default configuration file '$Config' does not exist.";
    }
}
else
{
    .$Config
}

# Use default values from configuration file to fill in missing values.
# =============================

if($Target -eq $null -or $Target -is [String] -and [String]::IsNullOrWhiteSpace($Target))
{
    $Target = $DefaultTarget;
}

if([String]::IsNullOrWhiteSpace($DarConfig))
{
    $DarConfig = $local:DefaultDarConfig;
}
$DarConfigCyg = Get-CygwinPath -Path $DarConfig;

if([String]::IsNullOrWhiteSpace($BackupPath))
{
    $BackupPath = $local:DefaultBackupPath;
}
$BackupPathCyg = Get-CygwinPath -Path $BackupPath;

if([String]::IsNullOrWhiteSpace($LogPath))
{
    if([String]::IsNullOrWhiteSpace($local:DefaultLogPath))
    {
        $LogPath = $BackupPath;
    }
    else
    {
        $LogPath = $local:DefaultLogPath;
    }
}

if([String]::IsNullOrWhiteSpace($DarPath))
{
    $DarPath = $local:DefaultDarPath;
}

if([String]::IsNullOrWhiteSpace($FullSuffix))
{
    $FullSuffix = $local:DefaultFullSuffix;
}

if([String]::IsNullOrWhiteSpace($DiffSuffix))
{
    $DiffSuffix = $local:DefaultDiffSuffix;
}

# Normalize $Target.
# =============================

Write-Verbose "Input backup targets: [$($Target | Out-String)].";
$targetObjects = $Target | New-Target -FullSuffix $FullSuffix -DiffSuffix $DiffSuffix;

# Determine backup kind
# =============================

if(-not $Full -and -not $Diff)
{
    $Auto = $true;
}

# Run backup.
# =============================

foreach($to in $targetObjects)
{
    $parameters = Get-BackupParameter -Target $to;
    $kind = $parameters.Kind;
    $reference = $parameters.ReferenceBackup;

    $darTarget = $to.Target;
    $name = &$to.Name -Date $start -Kind $kind;
    $fullNameCyg = $BackupPathCyg + '/' + $name;
    
    $referenceArg = '';
    if(-not [String]::IsNullOrWhiteSpace($reference))
    {
        $referenceCyg = $BackupPathCyg + '/' + $reference;
        $referenceArg = " -A `"$referenceCyg`"";
    }

    $logFullName = Join-Path $LogPath ($name + '.log');

    Write-Timing -Format "Creating backup with target $darTarget at {0:O}";
    $createCommand = "$DarPath -c `"$fullNameCyg`"$referenceArg -B `"$DarConfigCyg`" $darTarget";
    if ($pscmdlet.ShouldProcess("$createCommand", "Create dar archive"))
    {
        Write-Host "$createCommand >> $logFullName";
        cmd /C $createCommand >> $logFullName;
    }
    Write-Timing -Format "Created backup with target $darTarget at {0:O}";

    Write-Timing -Format "Testing backup with target $darTarget at {0:O}";
    $testCommand = "$DarPath -t `"$fullNameCyg`" -B `"$DarConfigCyg`" $darTarget";
    if ($pscmdlet.ShouldProcess("$testCommand", "Test dar archive"))
    {
        Write-Host "$testCommand >> $logFullName";
        cmd /C $testCommand >> $logFullName;
    }
    Write-Timing -Format "Tested backup with target $darTarget at {0:O}";
}

$private:end = Get-Date;
$elapsed = ($private:end - $private:start).ToString("c");
Write-Timing -Format "Backup script complete at {0:O} in $elapsed" -Time $private:end;
