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

    if (-not $Request.TryGetHeader("Content-Type")) { return }

    $ContentTypeHeader = $Request.GetHeader("Content-Type")

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

    if (-not $Request.TryGetHeader("Accept")) { return }

    $AcceptHeader = $Request.GetHeader("Accept")
    if ([string]::IsNullOrWhiteSpace($Response.GetBody())) { return }
	
    switch ($AcceptHeader.Value) {
        {$_ -like "*application/json*"} {
			$AcceptHeader = $Response.AddHeader("Content-Type","application/json; charset=utf-8")
            $Response.SetBody((ConvertTo-Json -InputObject $Response.GetBody() -depth 10))
        }
		default {
            
			$AcceptHeader = $Response.AddHeader("Content-Type","application/json; charset=utf-8")
            $Response.SetBody((ConvertTo-Json -InputObject $Response.GetBody() -depth 10))
			
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

GET "/large.json" -WebServer $thisWebServer  -ScriptBlock {
	return (ConvertFrom-Json (Get-Content -Raw -Path (join-path $PSSCriptRoot "largeDict.json")) -ashashtable -depth 10)
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

$thisWebServer.HandleRequests()