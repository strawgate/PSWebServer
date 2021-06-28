Set-StrictMode -version 3
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

$Script:DefaultWebServer = $null

class FromBodyAttribute : Attribute 
{
    FromBodyAttribute() {}
}
class FromRouteAttribute : Attribute 
{
    FromRouteAttribute() {}
}


class WebServer {
	[RequestHandler] $RequestHandler
	[System.Net.HttpListener] $HttpListener
	
	WebServer () {
		$this.Initialize()
	}
	
	WebServer ([string] $Binding) {
		$this.Initialize()
		$this.AddBinding($Binding)
	}
	
	WebServer ([string] $Binding, [bool] $SetDefault = $true) {
		$this.Initialize()
		$this.AddBinding($Binding)

		if ($SetDefault) {
			$Script:DefaultWebServer = $this
		}
	}
	
	[void] HandleOneRequest() {

		$wasStartedForThisRequest = $false
		if ($this.isStopped()) { $wasStartedForThisRequest = $true; $this.Start() }
		
		$contextTask = $this.HttpListener.GetContextAsync()
		while (-not $contextTask.AsyncWaitHandle.WaitOne(10)) {
			# Do nothing
		}
		
		$this.RequestHandler.HandleRequest( $ContextTask.GetAwaiter().GetResult() )
		
		if ($wasStartedForThisRequest) { $this.stop() }
		# For unit testing it might be useful to return a clone of the context object to the caller of HandleOneRequest
	}
	
	[void] HandleRequests () {
		$this.Start()
		while ($true) {
			$this.HandleOneRequest()
		}
		$this.Stop()
	}
	
	[void] AddBinding ( [string] $Prefix ) {
		$this.HttpListener.Prefixes.Add($Prefix)
	}
	
	[void] Initialize () {
		$this.HttpListener = [System.Net.HttpListener]::new()
		$this.RequestHandler = [RequestHandler]::new()
	}
	
	[void] Start () {
		write-verbose "Starting Web Server with $($this.Requesthandler.routes.count) routes defined"
		$this.HttpListener.Start()
	}
	
	[bool] isStarted() { return $this.HttpListener.IsListening }
	[bool] isStopped() { return ! $this.isStarted() }
	
	[void] Stop () {
		$this.HttpListener.Stop()
	}
}


class RequestHandler {
	[RequestController[]] $RequestControllers = @()
	[MiddleWareController[]] $MiddleWareControllers = @()
	[Route[]] $Routes = @()
	
	
	RequestHandler () { }
	
	[void] AddMiddlewareController ([MiddlewareController] $MiddleWareController) {
		$this.MiddleWareControllers += $MiddleWareController
	}
		
	[void] AddRequestController ([RequestController] $RequestController) {
		$this.RequestControllers += $RequestController
	}
	
	[void] AddRoute ([Route] $Route) {
		$this.Routes += $Route
	}
	
	[Controller[]] GetControllersForUri ([string] $uri) {
		return $this.Routes.Where{$_.testMatchesUri($uri)}.foreach{$_.GetController()}
	}
	
	[void] HandleRequest ($Context) {
		$Request = $Context.Request
		$Response = $Context.Response
		
		write-verbose "$(ConvertTo-Json -Compress -InputObject $Request)"
		
		$Uri = $Request.rawUrl
		
		$RelevantControllers = $this.GetControllersForUri($uri)
		
		$relevantRequestControllers = $RelevantControllers.Where{$_.type -eq [ControllerTypeEnum]::Request}
		
		$RelevantMiddleWareControllers = $RelevantControllers.Where{$_.type -eq [ControllerTypeEnum]::Middleware}
		$RelevantBeforeMiddlewareControllers = $RelevantMiddleWareControllers.Where{$_.Order -eq [MiddlewareControllerOrderEnum]::Before}
		$RelevantAfterMiddlewareControllers  = $RelevantMiddleWareControllers.Where{$_.Order -eq [MiddlewareControllerOrderEnum]::After}
		
		write-verbose "Request matches $($relevantRequestControllers.count) request controllers"
		write-verbose "Request matches $($RelevantMiddleWareControllers.count) middleware controllers"
		
		$RelevantBeforeMiddlewareControllers.Foreach{$_.HandleRequest($context)}
		
		$Body = $null
		
		try {
			$Body = $RelevantRequestControllers.Foreach{$_.HandleRequest($context)}
			$Response.statuscode = 200
		}
		catch {
			write-error $_ -erroraction "continue"
			$Response.statuscode = 500
		}
		$RelevantAfterMiddlewareControllers.Foreach{$_.HandleRequest($context)}
		
		# Controller wants us to return a body
		if ($Body -ne $Null) {
				
			$buffer = [Text.Encoding]::UTF8.GetBytes($Body)
			$Response.ContentLength64 = $buffer.length
			$Response.OutputStream.Write($buffer, 0, $buffer.length)
		}
		
		# Close the request
		$Response.Close()
	}
}

class ControllerTypeEnum {
	static [string] $Middleware = "Middleware"
	static [string] $Request = "Request"
}
class MiddlewareControllerOrderEnum {
	static [string] $Before = "Before"
	static [string] $After = "After"
}

class Controller {
	[string] $Name
	[scriptblock] $ScriptBlock
	[string] $Type
	
	Controller () {}
	
	Controller ([string] $Name, [scriptBlock] $ScriptBlock) {
		$this.Name = $Name
		$this.ScriptBlock = $ScriptBlock
	}
	
	HandleRequest ($Context) {
		write-host "Running through $($This.Type) $($This.Name) Controller"
		
		function _getRequestBody {
			param ($Context)
			$Length = $Context.Request.contentlength64

			$buffer = [byte[]]::new($Length)
			[void]$Context.Request.InputStream.read($buffer, 0, $length)
			write-output [system.text.encoding]::UTF8.getstring($buffer)

		}
		
		function _getRequestBodyJson {
			param ($Context)
			$RequestBody = _getRequestBody -Context $context
			
			write-output (ConvertFrom-Json -AsHashtable -InputObject $RequestBody)
		}
		
		
		# Look at the AST to find out what params our scriptblock has defined
		# map fields from the body into the params 
		$Params = @{}
		
		foreach ($Parameter in $this.ScriptBlock.Ast.ParamBlock.Parameters) {
			$ParameterName = $Parameter.Name.VariablePath.UserPath.toLower()
			$ParameterAttributes = $Parameter.Attributes
			
			Foreach ($ScriptBlockParam in $ParameterAttributes) {
				if ($ScriptBlockParam.TypeName.Name -eq "FromBody") {
					$thisRequestBody = _getRequestBodyJson -Context $Context
					
					$Params.Add($ParameterName, $thisRequestBody[$ParameterName])
				}
			}
		}
		
		& $this.ScriptBlock @Params
	}
}

class RequestController : Controller {
	
	[string] $Type = "Request"
		
	RequestController () {}
	
	RequestController ([string] $Name, [scriptBlock] $ScriptBlock) {
		$this.Name = $Name
		$this.ScriptBlock = $ScriptBlock
	}
	
}

class MiddlewareController : Controller {
		
	[string] $Type = "Middleware"
	[string] $Order
	
	MiddlewareController () {}
	
	MiddlewareController ([string] $Name, [scriptBlock] $ScriptBlock, [string] $Order) {
		$this.Name = $Name
		$this.ScriptBlock = $ScriptBlock
		$this.Order = $Order
	}
	
}

class Route {
	[string] $Match
	[Controller] $Controller
	
	Route ([string] $Match, [Controller] $Controller) {
		$this.match = $Match
		$this.Controller = $Controller
	}
	
	[Controller] getController () {
		return $this.Controller
	}
	
	[bool] testMatchesUri ([string] $uri) {
		if ($uri -like $this.Match) {
			return $true
		}
		return $false
	}
	
	[Controller] matchesUri ([string] $uri) {
		if ($this.testMatchesUri($uri)) {
			return $this.Controller
		}
		
		return $null
	}
}

Function New-PSWebserver {
	param (
		$Binding = "http://*:8080/",
		$IsDefault = $true
	)

	return [WebServer]::new($Binding,$IsDefault)
}

Function New-PSWebServerMiddlewareController {
	param (
		$Name,
		$ScriptBlock,
		$Order
	)
	return [MiddlewareController]::New($Name,$ScriptBlock, $Order)
}

Function New-PSWebServerRequestController {
	param (
		$Name,
		$ScriptBlock
	)
	
	return [RequestController]::New($Name,$ScriptBlock)
}

Function New-PSWebServerRoute {
	param (
		[string] $Match,
		[Controller] $Controller,
		$WebServer = $Script:DefaultWebServer
	)
	$thisRoute = [Route]::New($Match, $Controller)
	if ($WebServer) { $WebServer.RequestHandler.AddRoute($thisRoute)}

	else {
		return $thisRoute
	}
}

Function New-PSWebServerRouteWithController {
	param (
		[string] $Match,
		[ScriptBlock] $ScriptBlock,
		[string] $Name,
		$WebServer = $Script:DefaultWebServer
	)
	
	if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Match }
	$thisController = [Controller]::new($Name,$ScriptBlock)
	
	New-PSWebServerRoute -Match $Match -Controller $thisController -WebServer $Webserver
}

Set-Alias -Name Get -Value New-PSWebServerRouteWithController


<#
# <string,scriptblock>
$Script:Controllers = @{
}

# <string,<string,string>>
$Script:Routes = @{
}

[System.Collections.Arraylist[Route]] $Script:Routes = [System.Collections.Arraylist[Route]]::new()
[System.Collections.Arraylist[Controllers]] $Script:Controllers = [System.Collections.Arraylist[Controllers]]::new()

$Script:RouteList = @()


class FromBodyAttribute : Attribute 
{
    FromBodyAttribute() {}
}
class FromRouteAttribute : Attribute 
{
    FromRouteAttribute() {}
}

Function Add-Route {
	param (
		$Match,
		$Controller
	)
}

Function Get-Route {
	param (
		$uri
	)
	
	if ($uri) { $Script:Routes.Where{$_
	return $Script:Routes
}

Function New-PSWebServer {
	[RequestHandler] $requestHandler = [RequestHandler]::new()
}

Function Start-PSWebServer {
	param (
		$Binding
	)
	
    [void] ( $LISTENER.Prefixes.Add($BINDING) )
    [void] ( $LISTENER.Start() )
}

Function Stop-PSWebServer {
	[void] ( $LISTENER.Stop() )
}

Function Register-PSWebServerRoute {
	param (
		[string] $Method,
		[string] $Route,
		[string] $ControllerName
	)
	
	[void] ($Script:Routes.Add($Route, $ControllerName))
}

Function Register-PSWebServerController {
	param (
		[string] $Name,
		[scriptblock] $Code
	)
	
	[void] ($Script:Controllers.Add($Name, $Code))
}

Function Wait-PSWebServerRequest {
	param ()
	
	#$context = $listener.GetContext()
	
	# Use an Async Request 
	$contextTask = $listener.GetContextAsync()
	while (-not $contextTask.AsyncWaitHandle.WaitOne(10)) {
		# Do nothing
	}
	Handle-PSWebServerRequest -Context $ContextTask.GetAwaiter().GetResult()
	
	return $Response
}

Function Handle-PSWebServerRequest {
	param (
		$Context
	)
	
	$Url = $Context.Url
	$RequestBody = Read-PSWebServerRequestBody -InputStream $Context.Request.InputStream -Length $Context.request.contentlength64

	$RequestBodyObj = ConvertFrom-Json -AsHashtable $RequestBody

	write-verbose (Convertto-Json $Context.request)
	
	foreach ($RouteKV in $Routes.GetEnumerator()) {
		
		$RouteMatch = $RouteKV.Name
		$ControllerName = $RouteKV.Value

		if ($URL -like $RouteMatch) {
			$scriptBlock = $Controllers[$ControllerName]
			
			$Params = @{
			}
			
			foreach ($Parameter in $ScriptBlock.Ast.ParamBlock.Parameters) {
				$ParameterName = $Parameter.Name.VariablePath.UserPath.toLower()
				$ParameterAttributes = $Parameter.Attributes
				
				Foreach ($ScriptBlockParam in $ParameterAttributes) {
					if ($ScriptBlockParam.TypeName.Name -eq "FromBody") {
						$Params.Add($ParameterName, $RequestBodyObj[$ParameterName])
					}
				}
			}
			
			$result = & $Controllers[$ControllerName] @Params
			
			Write-PSWebServerRequestResponse -Context $Context -Body $Result -StatusCode 200
		}
	}
}

Function Read-PSWebServerRequestBody {
	param (
		$InputStream,
		$Length
	)
	$buffer = [byte[]]::new($Length)
  
	[void]$InputStream.read($buffer, 0, $length)
	return [system.text.encoding]::UTF8.getstring($buffer)
}

Function Write-PSWebServerRequestResponse {
	param (
		$Context,
		$Body,
		$StatusCode
	)
	
	$Response = $context.Response

    $Response.statuscode = $StatusCode
    
    $buffer = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.ContentLength64 = $buffer.length
    $Response.OutputStream.Write($buffer, 0, $buffer.length)
    
    $Response.Close()
}

#>