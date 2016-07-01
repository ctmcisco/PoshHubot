﻿properties {
    $moduleName = 'PoshHubot'
    $unitTests = "$PSScriptRoot\Tests\unit"

    $filesToTest = Get-ChildItem *.psm1,*.psd1,*.ps1 -Recurse -Exclude *build.ps1,*.pester.ps1,*Tests.ps1
}

task default -depends Analyze, Test, BuildArtifact, UploadToPSGallery

task TestProperties { 
  Assert ($build_version -ne $null) "build_version should not be null"
}

task Analyze {
    ForEach ($testPath in $filesToTest)
    {
        try
        {
            Write-Output "Running ScriptAnalyzer on $($testPath)"

            if ($env:APPVEYOR)
            {
                Add-AppveyorTest -Name "PsScriptAnalyzer" -Outcome Running
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
            }

            $saResults = Invoke-ScriptAnalyzer -Path $testPath -Verbose:$false
            if ($saResults) {
                $saResults | Format-Table
                $saResultsString = $saResults | Out-String
                if ($saResults.Severity -contains 'Error' -or $saResults.Severity -contains 'Warning')
                {
                    if ($env:APPVEYOR)
                    {
                        Add-AppveyorMessage -Message "PSScriptAnalyzer output contained one or more result(s) with 'Error or Warning' severity.`
                        Check the 'Tests' tab of this build for more details." -Category Error
                        Update-AppveyorTest -Name "PsScriptAnalyzer" -Outcome Failed -ErrorMessage $saResultsString                  
                    }               

                    Write-Error -Message "One or more Script Analyzer errors/warnings where found in $($testPath). Build cannot continue!"  
                }
                else
                {
                    Write-Output "All ScriptAnalyzer tests passed"

                    if ($env:APPVEYOR)
                    {
                        Update-AppveyorTest -Name "PsScriptAnalyzer" -Outcome Passed -StdOut $saResultsString -Duration $timer.ElapsedMilliseconds
                    }
                }
            }
        }
        catch
        {
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            Write-Output $ErrorMessage
            Write-Output $FailedItem
            Write-Error "The build failed when working with $($testPath)."
        }  
    }     
        
}

task Test {
    $testResults = .\Tests\appveyor.pester.ps1 -Test -TestPath $unitTests
    # $testResults = Invoke-Pester -Path $unitTests -PassThru
    if ($testResults.FailedCount -gt 0) {
        $testResults | Format-List
        Write-Error -Message 'One or more Pester unit tests failed. Build cannot continue!'
    }
}

task BuildArtifact -depends Analyze, Test {
    New-Item -Path "$PSScriptRoot\Artifact" -ItemType Directory -Force
    Start-Process -FilePath 'robocopy.exe' -ArgumentList "`"$($PSScriptRoot)`" `"$($PSScriptRoot)\Artifact\$($moduleName)`" /S /R:1 /W:1 /XD Artifact .kitchen .vagrant .git /XF .gitignore build.ps1 psakeBuild.ps1 *.yml PesterResults*.xml TestResults*.xml" -Wait -NoNewWindow
    
    $manifest = Join-Path -Path "$PSScriptRoot\Artifact\$($moduleName)" -ChildPath "$($moduleName).psd1"

    # Only want proper releases when tagged
    if ($env:APPVEYOR -and $env:APPVEYOR_REPO_TAG)
    {
        Write-Output "Changing module version to Github tag version $($env:APPVEYOR_REPO_TAG_NAME)"
        (Get-Content $manifest -Raw).Replace("1.0.2", $env:APPVEYOR_REPO_TAG_NAME) | Out-File $manifest
        Compress-Archive -Path $PSScriptRoot\Artifact\$moduleName -DestinationPath $PSScriptRoot\Artifact\$moduleName-$env:APPVEYOR_REPO_TAG_NAME.zip -Force
    }
    # Artifiacts are built every time but not published unless tagged. This is for local testing
    else
    {
        (Get-Content $manifest -Raw).Replace("1.0.2", $build_version) | Out-File $manifest
        Compress-Archive -Path $PSScriptRoot\Artifact\$moduleName -DestinationPath $PSScriptRoot\Artifact\$moduleName-CI-$build_version.zip -Force
    }

    if ($env:APPVEYOR -and ($env:APPVEYOR_REPO_BRANCH -eq 'master'))
    {
        Write-Output "Publishing artifacts as build was done against master"
        $zip = Get-ChildItem -Path $PSScriptRoot\Artifact\*.zip |  % { Push-AppveyorArtifact $_.FullName -FileName $_.Name }
    }
}

task UploadToPSGallery -depends Analyze, Test, BuildArtifact  {
    # Upload artifiact only on tagging
    if ($env:APPVEYOR -and $env:APPVEYOR_REPO_TAG)
    {
        Write-Output "Publishing Module Located In $($PSScriptRoot)\Artifact\$($moduleName) to the PSGallery"
        Publish-Module -Path $PSScriptRoot\Artifact\$moduleName -NuGetApiKey $env:PSGalleryKey
    }
    else
    {
        Write-Output "If this was master in Appveyor, module would be published to PSGallery from $($PSScriptRoot)\Artifact\$($moduleName)."
        Get-ChildItem $PSScriptRoot\Artifact\$moduleName | Remove-Item -Force -Recurse
    }
}