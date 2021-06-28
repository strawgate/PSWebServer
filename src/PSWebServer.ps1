Import-Module .\PSWebServer.psm1 -force

Set-StrictMode -version 3
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

$thisWebServer = New-PSWebServer

Get "/help/{ID}" -ScriptBlock {
    param (
		$Body,
        [FromBody()]
		[string]$Name,
        [FromRoute()]
        [int32]$ID
    )
	
    write-host "Request Body: $Body"
    write-host "ID from Route: $ID"
    write-host "Name from Body: $Name"
    write-output "help"
}

$thisWebServer.HandleOneRequest()

<#
Register-PSWebServerController -Name "HelpController" -Code {
    param (
		$Body,
        [FromBody()]
		$Name
    )
    write-host "Request Body: $Body"
    write-host "Name from Body: $Name"
    write-output "help"
}

Register-PSWebServerRoute -Method "Get" -Route "/help*" -ControllerName "HelpController"

Start-PSWebServer -Binding "http://*:8080/"

while ($true) {
    Wait-PSWebServerRequest
    start-sleep -seconds 1
}#>

