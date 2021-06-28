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
		$Duration = measure-command {
			$this.RequestHandler.HandleRequest( $ContextTask.GetAwaiter().GetResult() )
		}
		write-verbose "Request took $($Duration.TotalMilliseconds) ms"
		
		
		if ($this.isStarted() -and $WasStartedForThisRequest) { $this.Stop() }
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

	[void] Dispose () {
		$this.Stop()
	}
}
class Service {
	[string] $Name
	[object] $Value

	Service ([string] $Name, [object] $Value) {
		$this.Name = $Name
		$this.Value = $value
	}

}

class RequestHandler {
	[RequestController[]] $RequestControllers = @()
	[MiddleWareController[]] $MiddleWareControllers = @()
	[Route[]] $Routes = @()
	[Service[]] $Services = @()

	
	RequestHandler () { }
	
	[void] AddMiddlewareController ([MiddlewareController] $MiddleWareController) {
		$this.MiddleWareControllers += $MiddleWareController
	}
		
	[void] AddRequestController ([RequestController] $RequestController) {
		$this.RequestControllers += $RequestController
	}
	
	[void] RegisterService ([string] $name, [object] $value) {
		$this.Services += [Service]::new($Name, $Value)
	}

	[void] RegisterService ([service] $Service) {
		$this.Services += $Service
	}

	[void] AddRoute ([Route] $Route) {
		$this.Routes += $Route
	}
	
	[Route[]] GetRoutesForUri ([string] $Uri) {
		return $this.Routes.Where{$_.testMatchesUri($uri)}
	}

	[Controller[]] GetControllersForUri ([string] $uri) {
		return $this.GetRoutesForUri($uri).foreach{$_.GetController()}
	}
	
	[void] HandleRequest ($Context) {
		$Request = [PSWebServerRequest]::new($Context)
		$Response = $Context.Response
		
		write-verbose "$(ConvertTo-Json -Compress -InputObject $Request)"
		
		$Uri = $Request.Uri
		
		$RelevantRoutes = $this.GetRoutesForUri($Uri)
		$RelevantControllers = $this.GetControllersForUri($uri)
		
		$RelevantRoutesWithRequestControllers = $RelevantRoutes.Where{$_.Controller.Type -eq [ControllerTypeEnum]::Request}

		if ($RelevantRoutesWithRequestControllers.count -eq 0) { throw "Zero controllers matche route $uri" }
		if ($RelevantRoutesWithRequestControllers.count -gt 1) { throw "More than one controller matches route $uri" }

		$RelevantRouteWithRequestController = $RelevantRoutesWithRequestControllers[0]

		$RelevantMiddleWareControllers = $RelevantControllers.Where{$_.type -eq [ControllerTypeEnum]::Middleware}
		$RelevantBeforeMiddlewareControllers = $RelevantMiddleWareControllers.Where{$_.Order -eq [MiddlewareControllerOrderEnum]::Before}
		$RelevantAfterMiddlewareControllers  = $RelevantMiddleWareControllers.Where{$_.Order -eq [MiddlewareControllerOrderEnum]::After}
		
		write-verbose "Request matches Request Controller: $($RelevantRouteWithRequestController.Controller.Name) and Middleware Controllers: $($RelevantMiddleWareControllers.Foreach{$_.Name} -join ", ")"
		
		$RelevantBeforeMiddlewareControllers.Foreach{$_.HandleRequest($context)}
		
		$Body = $null
		
		try {
			$Body = $RelevantRouteWithRequestController.Controller.HandleRequest($context, $RelevantRouteWithRequestController, $this)
			$Response.statuscode = 200
		}
		catch {
			write-error $_ -erroraction "continue"
			$Response.statuscode = 500
		}
		$RelevantAfterMiddlewareControllers.Foreach{$_.HandleRequest($context)}
		
		if ($Body -ne $null -and $Body -is [PSWebServerResponse]) {
			$Response.statuscode = $Body.StatusCode
			$buffer = [Text.Encoding]::UTF8.GetBytes($Body.Body)
			$Response.ContentLength64 = $buffer.length
			$Response.ContentType = "text/plain; charset=utf-8";
			$Response.OutputStream.Write($buffer, 0, $buffer.length)
		}

		# Controller wants us to return a body
		elseif ($Body -ne $Null -and $Body -is [string]) {
				
			$buffer = [Text.Encoding]::UTF8.GetBytes($Body)
			$Response.ContentLength64 = $buffer.length
			$Response.ContentType = "text/plain; charset=utf-8";
			$Response.OutputStream.Write($buffer, 0, $buffer.length)
		}

		elseif ($Body -ne $Null) {
				
			$buffer = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject $Body -depth 10))
			$Response.ContentLength64 = $buffer.length
			$Response.ContentType = "application/json; charset=utf-8";
			$Response.OutputStream.Write($buffer, 0, $buffer.length)
		}
		
		# Close the request
		$Response.Close()
	}
}
class Header {
	[string] $Name
	[string] $Value

	Header ([string] $Name, [string] $Value) {
		$this.Name = $Name
		$this.Value = $Value
	}

}
class StatusCodeEnum {
	$OK = 200
	$NotFound = 404
}

class PSWebServerRequest {
	[string] $Body
	[header[]] $Headers = @()
	[string] $Uri

	PSWebServerRequest () {}

	PSWebServerRequest ($Context) {
		$thisRequest = $context.Request

		$Length = $thisRequest.contentlength64

		$buffer = [byte[]]::new($Length)
		[void] $thisRequest.InputStream.read($buffer, 0, $length)

		$this.Body = ([system.text.encoding]::UTF8.getstring($buffer))
	
		foreach ($HeaderName in $ThisRequest.Headers) {
			$this.Headers += [Header]::New($HeaderName,$ThisRequest.Headers.Get($HeaderName))
		}

		$this.Uri = $thisRequest.rawUrl
	}

}

class PSWebServerResponse {
	[int32] $StatusCode
	[Object] $Body

	PSWebServerResponse () {}

	PSWebServerResponse ($Body, $StatusCode) {
		$this.Body = $Body
		$this.StatusCode = $StatusCode
	}

	static [PSWebServerResponse] OK ($Body) {
		Return [PSWebServerResponse]::new($Body, 200)
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
	
	[object] HandleRequest ($Context, [route] $Route, [requesthandler] $RequestHandler) {
		$Uri = $Context.Request.rawUrl

		write-host "Running through $($This.Type) $($This.Name) Controller"
		
		function _getRequestBody {
			param ($Context)
			$Length = $Context.Request.contentlength64

			$buffer = [byte[]]::new($Length)
			[void] $Context.Request.InputStream.read($buffer, 0, $length)

			write-output ([system.text.encoding]::UTF8.getstring($buffer))

		}
		
		function _getRequestBodyJson {
			param ($Context)

			$RequestBody = _getRequestBody -Context $context
			
			write-output (ConvertFrom-Json -AsHashtable -InputObject $RequestBody)
		}
		

		
		# Look at the AST to find out what params our scriptblock has defined
		# map fields from the body into the params 
		$Params = @{}

		$RouteParams = $Route.getParamsFromRoute($Uri)
		
		foreach ($Service in $RequestHandler.Services) {
			[Service] $Service = $Service
			$Params.Add($Service.Name, $service.Value )
		}

		# Process the params in the param block and provide them from the route or body if they are available
		if ($this.ScriptBlock.Ast.ParamBlock -ne $Null) {
			foreach ($Parameter in $this.ScriptBlock.Ast.ParamBlock.Parameters) {
				$ParameterName = $Parameter.Name.VariablePath.UserPath
				$ParameterAttributes = $Parameter.Attributes
				
				Foreach ($ScriptBlockParam in $ParameterAttributes) {
					if ($ScriptBlockParam.TypeName.Name -eq "FromBody") {
						$thisRequestBody = _getRequestBodyJson -Context $Context
						
						$Params.Add($ParameterName, $thisRequestBody[$ParameterName])
					}
					if ($ScriptBlockParam.TypeName.Name -eq "FromRoute") {					
						$Params.Add($ParameterName, [System.Web.HttpUtility]::UrlDecode($RouteParams[$ParameterName]))
					}
				}
			}
		}
		

		$Result = & $this.ScriptBlock @Params

		return $result
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
	[string] $RegexMatch
	[string] $QuickMatch
	[Controller] $Controller
	
	Route ([string] $Match, [Controller] $Controller) {
		# Route Interpretation
		$this.RegexMatch = $null
		$this.QuickMatch = $Match

		if ($Match -like "*{*") {
			$this.RegexMatch = $Match -replace ("{(.*?)}",'(?<$1>.*)')
			$this.QuickMatch = $Match -replace ("{.*?}",'*')
		}

		$this.Controller = $Controller
	}
	
	[Controller] getController () {
		return $this.Controller
	}
	
	[hashtable] getParamsFromRoute ( [string] $uri ) {
		if ($this.RegexMatch -eq $null) { return @{} }
		if ($uri -match $this.RegexMatch) {
			$params = $Matches
			[void] ($params.remove(0))
			return $Params
		}
		return @{}
	}

	[bool] testMatchesUri ([string] $uri) {
		if ($uri -like $this.QuickMatch) {
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
		$Order,
		$WebServer = $Script:DefaultWebServer
	)
	$thisController = [MiddlewareController]::New($Name,$ScriptBlock, $Order)

	if ($WebServer) { $WebServer.RequestHandler.AddMiddlewareController($thisController)}
	else {return $thisController}
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
	$thisController = New-PSWebServerRequestController -Name $Name -ScriptBlock $ScriptBlock
	
	New-PSWebServerRoute -Match $Match -Controller $thisController -WebServer $Webserver
}

Set-Alias -Name Get -Value New-PSWebServerRouteWithController
