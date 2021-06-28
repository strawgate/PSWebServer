using module StudentRepository

param (
	$WebServer
)

Set-StrictMode -version 3
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

Import-Module StudentRepository

$Script:Repository = [StudentRepository]::new((Join-Path $PSScriptRoot "..\..\data\students.json"))

$WebServer.RequestHandler.RegisterService("Repository", $Script:Repository) 

Get "/student" -webserver $thisWebServer {
	param ($Repository)
	[PSWebServerResponse]::Ok($Repository.GetStudents())
}

Get "/student/{FullName}" -webserver $thisWebServer {
	param ($Repository, [fromroute()][string]$FullName)
	write-output $Repository.GetStudent($Fullname)
}