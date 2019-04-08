$FilesDir = Convert-Path "$PWD" # Specify directory to search.
$RecursiveSearch = $true # Use $true or $false
$OutputFile = Convert-Path "$PWD\durations.txt" # Specify where to save results.
$FileExtensions = "*.ogg" # Use array to specify multiple types. (e.x. $FileExtensions = "*.wav", "*.mp3", "*.ogg")

# Use Leaf PathType to make sure we're checking for a file and not a directory.
if (!((test-path .\ffprobe -PathType Leaf) -or (test-path .\ffprobe.exe))) {
	Write-Host -BackgroundColor Black -ForegroundColor Yellow "Missing ffprobe. Must be in same directory as script.`n`n"
	Write-Host -BackgroundColor Black -ForegroundColor Green "Download ffprobe?"
	$GetFFprobe = Read-Host "(Y)/(N)"
	if ($GetFFprobe -like "y") {
		Try {
			# Use API to get latest file binaries.
			$FFresponse = Invoke-WebRequest -DisableKeepAlive -Method Get -Uri "http://ffbinaries.com/api/v1/version/latest"
			}
		Catch {
			Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Something went wrong with getting ffprobe info."
			Start-Sleep -s 2
			Break
		}
		# Set platform.
		if ($IsWindows) {$Platform = "windows-32"}
		elseif ($IsLinux) {$Platform = "linux-32"}
		elseif ($IsMacOS) {$Platform = "osx-64"}
		else {
			Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Unable to determine OS platform."
			Start-Sleep -s 2
			Break
		}
		$FFbinaries = ConvertFrom-Json $FFresponse.Content
		# Create temporary file for downloading.
		$TempFile = New-TemporaryFile
		Try {
			# Download ffprobe binary.
			Invoke-WebRequest -Uri $FFbinaries.bin.$Platform.ffprobe -OutFile $TempFile
			}
		Catch {
			Write-Host -BackgroundColor Black -ForegroundColor Red "ERROR: Something went wrong with getting ffprobe binary."
			Remove-Item $TempFile
			Start-Sleep -s 2
			Break
		}
		Expand-Archive -Path $TempFile -DestinationPath "$PWD"
		# Remove unneeded artifact from OS X zip file creation.
		Remove-Item -Recurse "$PWD\__MACOSX" -ErrorAction Ignore
		# Remove temporary file.
		Remove-Item $TempFile
	}
}

if ((test-path .\ffprobe -PathType Leaf) -or (test-path .\ffprobe.exe)) {
	$Output = @()
	$TotalTime = 0.0
	$i = 0
	if ($RecursiveSearch) {
		$MediaFileObjects = Get-ChildItem ($FilesDir + "\*") -Recurse -Include $FileExtensions
	}
	else {
		$MediaFileObjects = Get-ChildItem ($FilesDir + "\*") -Include $FileExtensions
	}

	$MediaFileObjects | ForEach-Object -Process {
		$i += 1
		Write-Progress -Activity "Getting durations of $FileExtensions files." -Status "Processing file $i of $($MediaFileObjects.Length)" -PercentComplete (($i/$MediaFileObjects.Length)*100) -CurrentOperation $_.Name
		# Works without the forced quotes (`"), but they're used just in case.
		$Duration = .\ffprobe -loglevel error -show_entries format=duration -print_format default=nokey=1:noprint_wrappers=1 `"$_`"
		$Output += $_.Name + " " + $Duration
		$TotalTime += $Duration
	}
	$Output += "Total " + (New-TimeSpan -Seconds $TotalTime).ToString()
	# Output to file.
	Out-File -FilePath $OutputFile -InputObject $Output
	Start-Sleep -m 500
}
