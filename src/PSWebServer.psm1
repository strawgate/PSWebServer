Set-StrictMode -version 3
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

$Script:DefaultWebServer = $null

class FromBodyAttribute : Attribute {
	FromBodyAttribute() {}
}
class FromRouteAttribute : Attribute {
	FromRouteAttribute() {}
}
class FromDependencyAttribute : Attribute {
	FromDependencyAttribute() {}
}

class Request {

}

class Response {
	[object] $Body
	[int] $StatusCode
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
		#$Duration = measure-command {
			$this.RequestHandler.HandleRequest( $ContextTask.GetAwaiter().GetResult() )
		#}
		#write-verbose "Request took $($Duration.TotalMilliseconds) ms"
		
		
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
		return $this.Routes.Where{ $_.testMatchesUri($uri) }

	}

	[Route[]] GetOrderedRoutesForUri ([string] $Uri) {
		[Route[]] $AllRoutes = $this.GetRoutesForUri($uri)

		[Route[]] $OrderedRoutes = @(
			$AllRoutes.Where{ $_.GetController().Type -eq [ControllerTypeEnum]::Middleware -and $_.GetController().Order -eq [MiddlewareControllerOrderEnum]::Before }
			$AllRoutes.Where{ $_.GetController().Type -eq [ControllerTypeEnum]::Request }
			$AllRoutes.Where{ $_.GetController().Type -eq [ControllerTypeEnum]::Middleware -and $_.GetController().Order -eq [MiddlewareControllerOrderEnum]::After }
		)
		return $OrderedRoutes
	}


	[Controller[]] GetControllersForUri ([string] $uri) {
		return $this.GetRoutesForUri($uri).foreach{ $_.GetController() }
	}
	
	[void] HandleRequest ($Context) {
		$Request = [PSWebServerRequest]::new($Context)
		$Response = [PSWebServerResponse]::new($Context)
		
		write-verbose "$(ConvertTo-Json -Compress -InputObject $Request)"
		
		$RelevantRoutes = $this.GetOrderedRoutesForUri($Request.Uri)

		foreach ($Route in $RelevantRoutes) {
			$thisController = $Route.GetController()

			write-verbose "$($Route.QuickMatch) matches Controller $($thisController.Name)"

			$RouteParams = $Route.getParamsFromRoute($Request.Uri)

			$ServiceParams = @{}
			$this.Services.Foreach{[void] ($ServiceParams.Add($_.Name,$_.Value))}

			$Result = $ThisController.HandleRequest($RouteParams, $ServiceParams, $Request, $Response)

			if ($Response.Body -eq $Null -and $Result -ne $null) { $Response.Body = $Result }
		}

		$Response.WriteAndClose()
	}
}

class PSWebServerHeader {
	[string] $Name
	[string] $Value

	PSWebServerHeader ([string] $Name, [string] $Value) {
		$this.Name = $Name
		$this.Value = $Value
	}

}
class StatusCodeEnum {
	$OK = 200
	$NotFound = 404
}

class PSWebServerRequestResponseBase {
	$Body
	[PSWebServerHeader[]] $Headers = @()
	$Context

	PSWebServerRequestResponseBase () {}

	PSWebServerRequestResponseBase ($Context){

		$ThisRequest = $Context.Request

		foreach ($HeaderName in $ThisRequest.Headers) {
			$this.Headers += [PSWebServerHeader]::New($HeaderName, $ThisRequest.Headers.Get($HeaderName))
		}

		$this.Context = $Context
	}

	[bool]   TryGetBody() { return ($This.Body -ne $null) }
	[object] GetBody() { return $This.Body }
	[void]   SetBody($Body) { $This.Body = $Body }


	[PSWebServerHeader[]] GetHeaders() { return $This.Headers }
	[PSWebServerHeader] GetHeader([string] $Name) { return $This.Headers.Where{ $_.Name -eq $Name }[0] }

	[bool] TryGetHeader([string] $Name) {
		try {
			$this.GetHeader($Name)
			return $True
		}
		catch {
			return $False
		}
	}

	[void]  SetHeaders([PSWebServerHeader[]] $Headers) { $This.Headers = $Headers }

	[void]  AddHeader([PSWebServerHeader] $Header) { $This.Headers += $Header }
	[void]  AddHeader([string] $Name, [string] $Value) { $This.AddHeader([PSWebServerHeader]::New($Name, $Value)) }
	[void]  RemoveHeader([PSWebServerHeader] $Header) { $This.Headers = $This.Headers.GetHeaders().Where{ $_.Name -eq $Header.Name } }
	[void]  RemoveHeader([string] $Name) { $This.Headers = $This.Headers.GetHeaders().Where{ $_.Name -eq $Name } }

}

class PSWebServerTransaction { 

}

class PSWebServerRequest : PSWebServerRequestResponseBase {
	[string] $Uri

	PSWebServerRequest () {}

	PSWebServerRequest ($Context) : base($Context) {
		$thisRequest = $context.Request

		# Pull the Body from the context into this request

		$Length = $thisRequest.contentlength64

		if ($Length -ne 0) {
			$buffer = [byte[]]::new($Length)
			[void] $thisRequest.InputStream.read($buffer, 0, $length)
			$this.Body = ([system.text.encoding]::UTF8.getstring($buffer))
		}

		$this.Uri = $thisRequest.rawUrl
	}

}


class PSWebServerResponse : PSWebServerRequestResponseBase {
	[int32] $StatusCode

	PSWebServerResponse () {}

	PSWebServerResponse ($Context) : base($Context) {}
	
	[int32] GetStatusCode() { return $This.StatusCode }
	[void]  SetStatusCode([int32] $StatusCode) { $This.StatusCode = $StatusCode }
	
	[System.Net.WebHeaderCollection] ConvertHeadersToHeaderCollection () {
		$headerCollection = [System.Net.WebHeaderCollection]::new()
		
		foreach ($header in $this.Headers){
			$headerCollection.add($header.name, $header.value)
		}
		
		return $HeaderCollection
	}
	
	[void] Close () {
		$this.Context.Response.Close()
	}

	[void] Write() {
		$This.Context.Response

		$RestrictedHeaders = @("Content-Type")
		$This.Context.Response.Headers.Add($this.ConvertHeadersToHeaderCollection())
		$this.Headers.Where{$_.Name -in $RestrictedHeaders}.Foreach{
			if ($_.Name -eq "Content-Type") { $This.Context.Response.ContentType = $_.Value }
		}
		write-host $(ConvertTo-Json -InputObject $this.Context.Response.Headers)
		$buffer = [Text.Encoding]::UTF8.GetBytes($this.Body)
		$This.Context.Response.SendChunked = $true
		$This.Context.Response.ContentLength64 = $buffer.length
		$This.Context.Response.OutputStream.Write($buffer, 0, $buffer.length)
		$This.Context.Response.OutputStream.Close()
	}

	[void] WriteAndClose() {
		$this.Write()
		$this.Close()
	}
	
	static [PSWebServerResponse] OK ($Body) {
		Return [PSWebServerResponse]::new($Body, 200)
	}

	static [PSWebServerResponse] NOTFOUND ($Body) {
		Return [PSWebServerResponse]::new($Body, 404)
	}

	static [PSWebServerResponse] INTERNALSERVERERROR ($Body) {
		Return [PSWebServerResponse]::new($Body, 500)
	}
}

Enum ControllerTypeEnum {
	Middleware
	Request
}
Enum MiddlewareControllerOrderEnum {
	Before
	After
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
	

	[hashtable] GetParamsFromScriptBlock() {
		$Hashtable = @{}
		if ($this.ScriptBlock.Ast.ParamBlock -ne $Null) {
			foreach ($Parameter in $this.ScriptBlock.Ast.ParamBlock.Parameters) {
				$ParameterName = $Parameter.Name.VariablePath.UserPath

				$ParameterType = $Parameter.Attributes.Where{$_.TypeName.Name -eq "FromBody" -or $_.TypeName.Name -eq "FromRoute"}

				$Hashtable.Add($ParameterName, $ParameterType)
			}
		}
		return $Hashtable
	}
	
	[string[]] GetServiceParamsFromScriptBlock() {
		[string[]] $returnList = @()
		
		foreach ($ParamKV in $this.GetParamsFromScriptBlock().GetEnumerator()) {
			$ParamName = $ParamKV.Name
			$ParamType = $ParamKV.Value

			if ($ParamType -eq "FromService") {
				$returnList += $ParamName
			}
		} 

		return $ReturnList
	}

	[string[]] GetRouteParamsFromScriptBlock() {
		[string[]] $returnList = @()
		
		foreach ($ParamKV in $this.GetParamsFromScriptBlock().GetEnumerator()) {
			$ParamName = $ParamKV.Name
			$ParamType = $ParamKV.Value

			if ($ParamType -eq "FromRoute") {
				$returnList += $ParamName
			}
		} 

		return $ReturnList
	}

	[string[]] GetBodyParamsFromScriptBlock() {
		[string[]] $returnList = @()
		
		foreach ($ParamKV in $this.GetParamsFromScriptBlock().GetEnumerator()) {
			$ParamName = $ParamKV.Name
			$ParamType = $ParamKV.Value

			if ($ParamType -eq "FromBody") {
				$returnList += $ParamName
			}
		} 

		return $ReturnList
	}

	[object] HandleRequest ([hashtable] $ServiceParams, [hashtable] $RouteParams, [PSWebServerRequest] $Request, [PSWebServerResponse] $Response) {
		write-host "Running through $($This.Type) $($This.Name) Controller"
		
		# Look at the AST to find out what params our scriptblock has defined
		# map fields from the body into the params 
		$Params = @{
			"Request" = $Request
			"Response" = $Response
		}
		$Params += $ServiceParams

		foreach ($FromBodyParamName in $this.GetBodyParamsFromScriptBlock()) {
			if ($Request.Body -is [hashtable]) {
				$Params.Add($FromBodyParamName, $Request.Body[$FromBodyParamName])
			} else {
				write-warning "A parameter ($FromBodyParamName) was requested from the body, but the body is not a readable object."
			}
		}
		
		foreach ($FromRouteParamName in $this.GetRouteParamsFromScriptBlock()) {
			if ($RouteParams.ContainsKey($FromRouteParamName)) {
				$Params.Add($FromRouteParamName, [System.Web.HttpUtility]::UrlDecode($RouteParams[$FromRouteParamName]))
			}
		}
	
		
		foreach ($FromServiceParamName in $this.GetServiceParamsFromScriptBlock()) {
			if ($ServiceParams.ContainsKey($FromServiceParamName)) {
				$Params.Add($FromServiceParamName, [System.Web.HttpUtility]::UrlDecode($ServiceParams[$FromServiceParamName]))
			}
		}
	

		$Result = & $this.ScriptBlock @Params

		return $result
	}
}

class RequestController : Controller {
	
	[string] $Type = "Request"
		
	RequestController () {}
	
	RequestController ([string] $Name, [scriptBlock] $ScriptBlock)  : Base($Name, $ScriptBlock) {
		$this.Name = $Name
		$this.ScriptBlock = $ScriptBlock
	}
	
}

class MiddlewareController : Controller {
		
	[string] $Type = "Middleware"
	[string] $Order
	
	MiddlewareController () {}
	
	MiddlewareController ([string] $Name, [scriptBlock] $ScriptBlock, [string] $Order) : Base($Name, $ScriptBlock) {
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
			$this.RegexMatch = $Match -replace ("{(.*?)}", '(?<$1>.*)')
			$this.QuickMatch = $Match -replace ("{.*?}", '*')
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
		$Binding = "http://localhost:8080/",
		$IsDefault = $true
	)

	return [WebServer]::new($Binding, $IsDefault)
}

Function New-PSWebServerMiddlewareController {
	param (
		[string] $Name,
		[scriptblock] $ScriptBlock,
		$Order,
		$WebServer = $Script:DefaultWebServer
	)

	$thisController = [MiddlewareController]::New($Name, $ScriptBlock, $Order)

	if ($WebServer) { $WebServer.RequestHandler.AddMiddlewareController($thisController); return $thisController }
	else { return $thisController }
}

Function New-PSWebServerRequestController {
	param (
		$Name,
		$ScriptBlock,
		$WebServer = $Script:DefaultWebServer
	)
	
	$thisController = [RequestController]::New($Name, $ScriptBlock)
	
	if ($WebServer) { $WebServer.RequestHandler.AddRequestController($thisController); return $thisController }
	else { return $thisController }
}

Function New-PSWebServerRoute {
	param (
		[string] $Match,
		[Controller] $Controller,
		$WebServer = $Script:DefaultWebServer
	)
	$thisRoute = [Route]::New($Match, $Controller)
	if ($WebServer) { $WebServer.RequestHandler.AddRoute($thisRoute) }

	else {
		return $thisRoute
	}
}

Function New-PSWebServerRouteWithRequestController {
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

Function New-PSWebServerRouteWithMiddlewareController {
	param (
		[string] $Match,
		[ScriptBlock] $ScriptBlock,
		[string] $Name,
		[switch] $Before,
		[switch] $After,
		$WebServer = $Script:DefaultWebServer
	)
	
	if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Match }
	$thisController = New-PSWebServerMiddlewareController -Name $Name -ScriptBlock $ScriptBlock -Order $(if ($Before) {"Before"} elseif ($After) {"After"})
	
	New-PSWebServerRoute -Match $Match -Controller $thisController -WebServer $Webserver
}

Set-Alias -Name Get -Value New-PSWebServerRouteWithRequestController

Set-Alias -Name Middleware -Value New-PSWebServerRouteWithMiddlewareController