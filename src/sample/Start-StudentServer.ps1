Set-StrictMode -version 3
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

Import-Module ..\PSWebServer.psm1 -force

$Models = Get-item (Join-Path $PSScriptRoot "Models") 
$Repositories = Get-item (Join-Path $PSScriptRoot "Repositories") 

$Env:PSModulePath = $Env:PSModulePath + [IO.Path]::PathSeparator + $Models.Fullname + [IO.Path]::PathSeparator  + $Repositories.FullName

$thisWebServer = New-PSWebServer

& (Join-Path "$PSScriptRoot" "Controllers\StudentController\StudentController.ps1") -WebServer $thisWebServer

$thisWebServer.HandleOneRequest()