$FilesDir = Convert-Path "$PWD" -ErrorAction:Stop # Specify directory to search. Stop if invalid.
# === Settings ===
$RecursiveSearch = $true # Search sub-directories?
$IncludeFormattedTotal = $true # Include total time in the output file?
$FileExtensions = "*.ogg" # File types to include. Use array to specify multiple types. (e.x. $FileExtensions = "*.wav","*.mp3","*.ogg")
# === Paths ===
$xmlFile = "$PWD/MFDexport.xml" # Specify where to save processed file info for speeding up future script runs.
$OutputFile = "$PWD/durations.txt" # Specify where to save results.

# Check for ffprobe in system path and current directory. Offer to download ffprobe if missing.
if (! ((Get-Command ffprobe -ErrorAction Ignore) -or (Get-Command ./ffprobe -ErrorAction Ignore)) ) {
    Write-Host -BackgroundColor Black -ForegroundColor Yellow "Missing ffprobe. Not found in PATH or local directories.`n`n"
    Write-Host -BackgroundColor Black -ForegroundColor Green "Download ffprobe?"
    $GetFFprobe = Read-Host "(Y)/(N)"
    if ($GetFFprobe -like "y") {
        Try {
            # Use API to get latest file binaries.
            $FFresponse = Invoke-WebRequest -DisableKeepAlive -Method Get -Uri "http://ffbinaries.com/api/v1/version/latest"
        } Catch {
            Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Something went wrong with getting ffprobe info."
            Start-Sleep -s 2
            Break
        }
        # Set platform if using PowerShell Core.
        if ($PSEdition -eq "Core") {
            if ($IsWindows) {
                $Platform = "windows-32"
            } elseif ($IsLinux) {
                $Platform = "linux-32"
            } elseif ($IsMacOS) {
                $Platform = "osx-64"
            } else {
                Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Unable to determine OS platform."
                Start-Sleep -s 2
                Break
            }
        } else {
            # If not using PowerShell Core then we're running on the built-in Windows PowerShell.
            $Platform = "windows-32"
        }

        $FFbinaries = ConvertFrom-Json $FFresponse.Content
        # Create temporary file for downloading.
        $TempFile = New-TemporaryFile
        Try {
            # Download ffprobe binary.
            Invoke-WebRequest -Uri $FFbinaries.bin.$Platform.ffprobe -OutFile $TempFile
        } Catch {
            Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Something went wrong with getting ffprobe binary."
            Remove-Item $TempFile
            Start-Sleep -s 2
            Break
        }
        Expand-Archive -Path $TempFile -DestinationPath "$PWD"
        # Remove unneeded artifact from OS X zip file creation if not running on OS X.
        if (! $IsMacOS) {
            Remove-Item -Recurse "$PWD/__MACOSX" -ErrorAction Ignore
        }
        # Remove temporary file.
        Remove-Item $TempFile
    }
}

# Run check again to allow for use immediately after downloading ffprobe. Store which command was successful.
if ( ((Get-Command ffprobe -ErrorAction Ignore) -and ($ffPath = "ffprobe")) -or ((Get-Command ./ffprobe -ErrorAction Ignore) -and ($ffPath = "./ffprobe")) ) {
    [decimal]$TotalTime = 0.0
    [int]$Progress = 0

    [System.Collections.ArrayList]$ProcessedArray = @()
    Add-Member -InputObject $ProcessedArray -NotePropertyName TotalTime -NotePropertyValue $TotalTime

    # If XML file exists, attempt to import it.
    if (Test-Path -Path $xmlFile -PathType Leaf){
        Try {
            [System.Collections.ArrayList]$ProcessedArray = Import-Clixml $xmlFile
            $TotalTime = $ProcessedArray.TotalTime
        } Catch {
            Write-Host -BackgroundColor Black -ForegroundColor Yellow "Error importing previously processed files."
            Write-Host -BackgroundColor Black -ForegroundColor Yellow "Continuing without previous data."
        }
    }

    if ($RecursiveSearch) {
        $MediaFileObjects = Get-ChildItem $FilesDir -File -Recurse -Include $FileExtensions
    } else {
        $MediaFileObjects = Get-ChildItem ($FilesDir + "/*") -File -Include $FileExtensions
    }

    $MediaFileObjects.ForEach({
        Write-Progress -Activity "Getting durations of $FileExtensions files." -Status "Processing file $($Progress + 1) of $($MediaFileObjects.Length)" -PercentComplete (($Progress/$MediaFileObjects.Length)*100) -CurrentOperation $_.Name
        # Check to see if file was already processed. If not, process it.
        # TODO: Use LastWriteTime to determine if file was changed and process/update it.
        if ($_.FullName -notin $ProcessedArray.FullName){
            [decimal]$Duration = & $ffPath -loglevel error -show_entries format=duration -print_format default=nokey=1:noprint_wrappers=1 $_.FullName
            # Create object to add to array.
            $obj = [pscustomobject]@{
                FullName = $_.FullName
                Name = $_.Name
                LastWriteTime = $_.LastWriteTime
                Duration = $Duration
            }
            # Update total time variable.
            $TotalTime += $Duration
            # Add object to array.
            $ProcessedArray.Add($obj) | Out-Null
        }
        $Progress += 1
    })

    # Update total time member.
    $ProcessedArray.TotalTime = $TotalTime
    # Prepare data for output to file
    $Output = $ProcessedArray | Select-Object -Property Name,Duration | Out-String
    if ($IncludeFormattedTotal){
        $Output += "Total " + (New-TimeSpan -Seconds $TotalTime).ToString()
    }
    # Output to file while trimming excess whitespace.
    Out-File -FilePath $OutputFile -InputObject $Output.Trim()
    # Export data for the next time the script is run.
    Export-Clixml -InputObject $ProcessedArray -Path $xmlFile

    Start-Sleep -m 500
}
