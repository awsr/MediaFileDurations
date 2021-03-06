$FilesDir = Convert-Path "$PWD" -ErrorAction:Stop # Specify directory to search. Stop if invalid.
# === Settings ===
$RecursiveSearch = $true # Search sub-directories?
$IncludeFormattedTotal = $true # Include total time in the output file?
$FileExtensions = "*.ogg" # File types to include. Use array to specify multiple types. (e.x. $FileExtensions = "*.wav","*.mp3","*.ogg")
# === Paths ===
$XmlFile = "$PWD/MFDexport.xml" # Specify where to save processed file info for speeding up future script runs.
$OutputFile = "$PWD/durations.txt" # Specify where to save results.


$SearchArgs = @{File = $true; Recurse = $RecursiveSearch; Include = $FileExtensions}
$TotalDurationMethod = {[math]::Round(($this.Duration | Measure-Object -Sum).Sum, 4)}

# Check for ffprobe in system path and current directory. Offer to download ffprobe if missing.
if (-not ((Get-Command ffprobe -ErrorAction:Ignore) -or (Get-Command ./ffprobe -ErrorAction:Ignore)) ) {
    Write-Host -BackgroundColor Black -ForegroundColor Yellow "Missing ffprobe. Not found in PATH or local directories.`n`n"
    Write-Host -BackgroundColor Black -ForegroundColor Green "Download ffprobe?"
    $GetFFprobe = Read-Host "(Y)/(N)"

    if ($GetFFprobe -like "y") {
        Try {
            # Use API to get latest file binaries.
            $FFResponse = Invoke-WebRequest -DisableKeepAlive -Method Get -Uri "http://ffbinaries.com/api/v1/version/latest" -ErrorAction:Stop
        }
        Catch {
            Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Unable to get data from ffbinaries API."
            Write-Host $_
            Start-Sleep -s 2
            Break
        }

        # Set architecture string based on whether 64-bit or 32-bit OS.
        if ([System.Environment]::Is64BitOperatingSystem) {
            $OSArch = "64"
        }
        else {
            $OSArch = "32"
        }

        # Set platform if using PowerShell Core.
        if ($PSEdition -eq "Core") {
            if ($IsWindows) {
                $Platform = "windows-$OSArch"
            }
            elseif ($IsLinux) {
                $Platform = "linux-$OSArch"
            }
            elseif ($IsMacOS) {
                # Mac only has 64-bit version.
                $Platform = "osx-64"
            }
            else {
                Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Unable to determine OS platform."
                Start-Sleep -s 2
                Break
            }
        }
        else {
            # If not using PowerShell Core then we're running on the built-in Windows PowerShell.
            $Platform = "windows-$OSArch"
        }

        $FFBinaries = ConvertFrom-Json $FFResponse.Content

        # Create temporary file for downloading.
        $TempFile = New-TemporaryFile

        Try {
            # Download ffprobe binary.
            Invoke-WebRequest -Uri $FFBinaries.bin.$Platform.ffprobe -OutFile $TempFile -ErrorAction:Stop

            Expand-Archive -Path $TempFile -DestinationPath $PWD -ErrorAction:Stop

            # Remove unneeded artifact from OS X zip file creation if not running on OS X.
            if (-not $IsMacOS) {
                Remove-Item -Recurse "$PWD/__MACOSX" -ErrorAction:Ignore
            }
        }
        Catch {
            Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Something went wrong with processing the ffprobe binary."
            Write-Host $_
            Start-Sleep -s 2
            Break
        }
        Finally {
            # Remove temporary file.
            Remove-Item $TempFile -ErrorAction:Ignore
        }
    }
}

# Run check again to allow for use immediately after downloading ffprobe. Store which command was successful.
if ( ((Get-Command ffprobe -ErrorAction:Ignore) -and ($FFPath = "ffprobe")) -or ((Get-Command ./ffprobe -ErrorAction:Ignore) -and ($FFPath = "./ffprobe")) ) {
    $Progress = 0
    [System.Collections.ArrayList]$ProcessedArray = @()

    # If XML file exists, attempt to import it.
    if (Test-Path -Path $XmlFile -PathType Leaf) {
        Try {
            $ProcessedArray = Import-Clixml $XmlFile -ErrorAction:Stop
            
            # Verify required member properties exist.
            $MemberCheck = $ProcessedArray | Get-Member -Name FullName, Name, Duration, LastWriteTimeUtc
            if ($MemberCheck.Count -ne 4) {
                throw "Imported data does not match expected format."
            }

            # Verify all properties are populated.
            if (($ProcessedArray.FullName.Count, $ProcessedArray.Name.Count, $ProcessedArray.Duration.Count, $ProcessedArray.LastWriteTimeUtc.Count) -ne $ProcessedArray.Count) {
                throw "Imported data contains incomplete entries."
            }
        }
        Catch {
            Write-Host -BackgroundColor Black -ForegroundColor Yellow "$_"
            Write-Host -BackgroundColor Black -ForegroundColor Yellow "Continuing without previous data."
            # Re-create blank array.
            [System.Collections.ArrayList]$ProcessedArray = @()
        }
    }

    Add-Member -InputObject $ProcessedArray -MemberType ScriptMethod -Name "TotalDuration" -Value $TotalDurationMethod

    $MediaFileObjects = Get-ChildItem ($FilesDir + "/*") @SearchArgs

    $MediaFileObjects.ForEach({
        Write-Progress -Activity "Getting durations of $FileExtensions files." -Status "Processing file $($Progress + 1) of $($MediaFileObjects.Length)" -PercentComplete (($Progress/$MediaFileObjects.Length)*100) -CurrentOperation $_.Name

        # Check to see if file was already processed. If not, process and add it.
        # If newer version of file exists, process and update it.
        if ($_.FullName -notin $ProcessedArray.FullName) {
            [double]$Duration = & $FFPath -loglevel error -show_entries format=duration -print_format default=nokey=1:noprint_wrappers=1 $_.FullName

            # Create object to add to array.
            $obj = [pscustomobject]@{
                FullName         = $_.FullName
                Name             = $_.Name
                LastWriteTimeUtc = $_.LastWriteTimeUtc
                Duration         = $Duration
            }

            # Add object to array.
            $ProcessedArray.Add($obj) | Out-Null
        }
        else {
            # Get the index value for the whole object based on the index of the FullName value from all processed FullName members.
            $IndexVal = $ProcessedArray.FullName.IndexOf($_.FullName)

            if ($_.LastWriteTimeUtc -gt $ProcessedArray[$IndexVal].LastWriteTimeUtc) {
                [double]$Duration = & $FFPath -loglevel error -show_entries format=duration -print_format default=nokey=1:noprint_wrappers=1 $_.FullName

                # Update object values.
                $ProcessedArray[$IndexVal].LastWriteTimeUtc = $_.LastWriteTimeUtc
                $ProcessedArray[$IndexVal].Duration = $Duration
            }
        }

        $Progress += 1
    })

    # Prepare data for output to file
    $Output = $ProcessedArray | Select-Object -Property Name,Duration | Out-String

    if ($IncludeFormattedTotal) {
        $Output += "Total " + (New-TimeSpan -Seconds $ProcessedArray.TotalDuration()).ToString()
    }

    # Output to file while trimming excess whitespace.
    Out-File -FilePath $OutputFile -InputObject $Output.Trim()
    
    # Export data for the next time the script is run.
    $ProcessedArray | Export-Clixml -Path $XmlFile
}
