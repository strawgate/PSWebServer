Import-Module .\PSWebServer.psm1 -force

Set-StrictMode -version 3
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

$thisWebServer = New-PSWebServer

Function myTest {
    return "TOMATO"
}

New-PSWebServerMiddlewareController -Name "AddContent" -Order "Before" -ScriptBlock {
    param (
        $Response
    )

    $Response.Headers.Add("tomato", "potato")
}


Middleware -Name "ConvertRequestToRequestType" -Before -Match "*" -ScriptBlock {
    param (
        $Request
    )

    if (-not $Request.TryGetHeader("content-type")) { return }

    $ContentTypeHeader = $Request.GetHeader("content-type")

    if ([string]::IsNullOrWhiteSpace($Request.GetBody())) { return }

    switch ($ContentTypeHeader.Value) {
        "application/json" {
            $Request.SetBody((ConvertTo-Json -InputObject $Request.GetBody()))
        }
    }
}

Middleware -Name "ConvertResponseToContentType" -After -Match "*" -ScriptBlock {
    param (
        $Request,
        $Response
    )

    if (-not $Request.TryGetHeader("content-type")) { return }

    $ContentTypeHeader = $Request.GetHeader("content-type")
    if ([string]::IsNullOrWhiteSpace($Response.GetBody())) { return }

    switch ($ContentTypeHeader.Value) {
        "application/json" {
            $Response.SetBody((ConvertTo-Json -InputObject $Response.GetBody()))
        }
    }
}

Get "/help/{ID}" -WebServer $thisWebServer -ScriptBlock {
    param (
        [FromBody()]
		[string]$Name,
        [FromRoute()]
        [int32]$ID
    )
	
    write-host "ID from Route: $ID"
    write-host "Name from Body: $Name"
    write-output (myTest)
} 


Get "/assets" -WebServer $thisWebServer -ScriptBlock {
    param ()
	
    write-output @(
        @{
            "tomato" = "potato"
        }
        @{
            "potato" = "potato"
        }
    )
} 

$thisWebServer.HandleOneRequest()