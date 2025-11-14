############################################################
#region debug
import { createLogFunctions } from "thingy-debug"
{log, olog} = createLogFunctions("scicoremodule")
#endregion

############################################################
#region modules from the Environment
import http from "node:http"
import fs from "node:fs"
import crypto from "node:crypto"

#endregion

############################################################
#region defaultParameters
defaultBodySizeLimit = 500_000
defaultHeadersTimeout = 8_000
defaultRequestTimeout = 50_000
defaultKeepAliveTimeout = 120_000
defaultMaxHeadersCount = 50
defaultMaxHeaderSize = 2_048

#endregion

############################################################
#region Local Variables
globalBodySizeLimit = 0

listeningMode = ""

############################################################
serverObj = null

############################################################
sciRegistry = Object.create(null)
routeInfoMap = Object.create(null)

############################################################
createValidator = null

#endregion


############################################################
#region Allmighty Server Listening and Termination

############################################################
terminateServer = ->
    return unless serverObj?

    onClosed = ->
        console.log("Gracefully Terminated. Bye!")
        process.exit(0)
        return
    
    serverObj.close(onClosed)
    return

############################################################
setServerListening = (p) ->
    ## Always use provided socket on Socket Activation
    listenFds = parseInt(process.env.LISTEN_FDS)
    listenPid = parseInt(process.env.LISTEN_PID)
    ourPid = process.pid

    if ourPid  == listenPid and listenFds > 0
        return handleSocketActivation(p.backlog)
    
    ## Env dictates SocketMode but not Socket
    if process.env.SOCKETMODE == "true"
        throw new Error("No Socket for SOCKETMODE!")

    ## simply Overwrite when we have a valid env.PORT
    envPort = parseInt(process.env.PORT)
    if envPort > 0 then p.listenOn = envPort
    
    ## no Env. but "systemd" set -> SocketMode but no socket :(
    if p.listenOn == "systemd" 
        throw new Error("option systemd failed: no Socket!")
    
    return portUnixListen(p) ## otherwise go with what is configured

############################################################
handleSocketActivation = (backlog) ->
    log "handleSocketActivation"
    cb = null
    listening = new Promise( ((res) -> cb = res) )
    listeningMode = "SystemD FD 3"
    ## always use fd 3 for  Socket Activation - ignore the rest here
    handle = {fd: 3}
    serverObj = serverObj.listen(handle, backlog, cb)
    return listening

############################################################
portUnixListen = (p) ->
    cb = null
    listening = new Promise( ((res) -> cb = res) )
    
    options = { backlog: p.backlog }
    
    if typeof p.listenOn == "string" 
        options.path = p.listenOn
        listeningMode = "unix: #{options.path}"

    else 
        options.port = p.listenOn
        listeningMode = "tcp: #{options.port}"

    serverObj = serverObj.listen(options, cb)
    return listening

#endregion

############################################################
#region Upgrade/Error Handlers
## By default there is no upgrade
conectionUpgradeHandler = (req, sock) -> 
    console.warn("Attempt to upgrade!")
    sock.end("HTTP/1.1 403 Forbidden\r\n\r\n")
    return

############################################################
clientErrorHandler = (err, socket) ->
    console.warn(err.message)
    # err contains bytesParsed + rawPacket 
    if err.code == 'ECONNRESET' || !socket.writable then return
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n")
    return

#endregion 

############################################################
#region Request Processing
mainRequestHandler = (req, res) ->
    log "mainRequestHandler_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-\n"

    log "req.url: #{req.url}"
    log "req.method: #{req.method}"
    log "req.headers[Content-Type]: #{req.headers['content-type']}"
    log "req.headers[Content-Length]: #{req.headers['content-length']}" 
    log "req.headers[Transfer-Encoding]: #{req.headers['transfer-encoding']}"

    olog req.headers

    res.on("error", (error) -> console.error(error.message))
    req.on("error", (error) -> console.error(error.message))

    if !(req.method == "GET" || req.method == "POST") then return respondWith405(res)

    route = req.url
    prefix = req.method[0]
    key = "#{prefix}#{route}"

    # olog {route, key2}
    info = routeInfoMap[key]
    if !info? then return respondWith404(res)

    bodySizeLimit = info.bodySizeLimit || globalBodySizeLimit
    cLength = parseInt(req.headers['content-length']) || 0
    cType = req.headers['content-type']
    isJson = (cType == "application/json")

    hasBody = (cLength > 0)

    olog { cLength, cType, isJson, hasBody }

    if isJson and !hasBody then return respondWith400(res)
    if hasBody and bodySizeLimit == 0 then return respondWith400(res)
    
    context = {
        meta: extractMetaData(req)
        bodyString: ""
        bodyObj: undefined
        auth: undefined
        args: undefined
    }
    Object.freeze(context.meta) # should be one level object

    if !hasBody # undefined or "" is no valid json -> no body ==  no json
        if isJson then return respondWith400(res)
        return processRequest(req, res, info, context)
    
    if cLength > bodySizeLimit then return respondWith413(res)
    
    # case has Body - > wait for Body to be read    
    bodyChunks = []
    bodyLength = 0

    dataRead = (d) ->
        log "dataRead"
        bodyLength += d.length
        if bodyLength > bodySizeLimit or bodyLength > cLength
            olog { bodyLength, bodySizeLimit, cLength }
            respondWith413(res)
            return req.destroy() # prevent further data read
        bodyChunks.push(d)
            
    req.on('data', dataRead)
    
    handleBodyAndProcessRequest = ->
        log 'dataStreamEnd'
        if bodyLength != cLength
            olog { bodyLength,cLength }
            respondWith413(res)
            return req.destroy() # prevent further data read

        context.bodyString = Buffer.concat(bodyChunks, bodyLength).toString('utf8');
        if isJson
            try context.bodyObj = JSON.parse(context.bodyString)
            catch err then return respondWith400(res)
        processRequest(req, res, info, context)
        return

    req.on("end", handleBodyAndProcessRequest)
    return

############################################################
extractMetaData = (req) ->
    meta = Object.create(null)

    ## remote ip address
    forwardedFor = req.headers['x-forwarded-for']
    ## usually forwarded -> first entry in the list
    if typeof forwardedFor == "string" and forwardedFor.length > 6
        meta.ip = forwardedFor.split(",")[0]
    else meta.ip = req.socket.remoteAddress

    ## used hostname and user agent
    meta.host = req.headers['host']
    meta.userAgent = req.headers['user-agent']
    return meta

############################################################
processRequest = (req, res, info, ctx) ->
    log "processRequest"

    if ctx.bodyObj == undefined
        ## no body object -> we only have the body string
        ctx.auth = ctx.bodyString
        ctx.args = ctx.bodyString
    else if ctx.bodyObj == null
        ## can also be the null object -> prevent reading null.auth^^
        ctx.auth = null
        ctx.args = null
    else ## might have separated args and auth
        auth = ctx.bodyObj.auth
        args = ctx.bodyObj.args

        if auth == undefined and args == undefined
            ctx.auth = ctx.bodyObj
            ctx.args = ctx.bodyObj
        else
            ctx.auth = auth
            ctx.args = args
    
    ## All ready :-) handle it!
    try await info.handler(req, res, ctx)
    catch err then respondWith500(res, err)
    return


#endregion

############################################################
#region Compile RouteInfo Entries
compileRoutes = (sciRegistry) ->
    log "compileRoutes"
    return [] unless sciRegistry? and typeof sciRegistry == "object"
    
    keys = Object.keys(sciRegistry)
    # log keys
    routes = []
    try routes.push(...compile(k, sciRegistry[k])) for k in keys
    catch err then console.error(err.message)
    return routes

compile = (route, sciObj) ->
    log "compile #{route}"
    olog sciObj    
    if route[0] == "/" then route = route.slice(1)

    f = sciObj.func
    c = sciObj.conf
    if !(typeof f  == "function") then throw new Error("No func for '#{route}'!")
    if !(typeof c == "object") or !c? then throw new Error("No conf for '#{route}'!")
    

    postRoute = "P/#{route}"
    getRoute = null    

    if !c.authOption? and !c.argsSchema?
        if !c.bodySizeLimit? then c.bodySizeLimit = 0
        if route.length > 3 and route.indexOf("get") == 0
            getRoute = "G/"
            getRoute += route.slice(3,4).toLowerCase()
            getRoute += route.slice(4)

    # aO = authOption -> "1xxx"
    if c.authOption? then aO = "1"
    else  aO = "0"

    # aS = argsSchema -> "x1xx"
    if c.argsSchema? then aS = "1"
    else  aS = "0"

    # rS = resultSchema -> "xx1x"
    if c.resultSchema? then rS = "1"
    else  rS = "0"

    # rA = responseAuth -> "xxx1"
    if c.responseAuth? then rA = "1"
    else  rA = "0"

    ## no defined Validator then ignore the schemas :-)
    if createValidator == null
        aS = "0"
        rS = "0"

    handlerCreatorKey = "#{aO}#{aS}#{rS}#{rA}"
    log "handlerType: #{handlerCreatorKey}"
    handlerFunction = handlerCreators[handlerCreatorKey](route, f, c)

    olog { postRoute, getRoute }
    # olog c

    routeInfo = {
        handler: handlerFunction 
        bodySizeLimit: c.bodySizeLimit
    }
    Object.freeze(routeInfo)

    if getRoute? then return [
        [getRoute, routeInfo]
        [postRoute, routeInfo]
    ]
    
    return [[postRoute, routeInfo]]

#endregion

############################################################
#region All Response Functions

############################################################
## Error Responses as text/plain
respondWith400 = (response) ->
    response.statusCode = 400
    response.setHeader('Content-Type', 'text/plain')
    response.end('400 "Request Malformed!"\n')
    console.error(arguments[1]) if arguments[1]?
    return

respondWith401 = (response) ->
    response.statusCode = 401
    response.setHeader("Content-Type", "text/plain")
    response.end('401 "Not Authorized!"\n')
    console.error(arguments[1]) if arguments[1]?
    return

respondWith404 = (response) ->
    response.statusCode = 404
    response.setHeader('Content-Type', 'text/plain')
    response.end('404 "No Endpoint here!"\n')
    console.error(arguments[1]) if arguments[1]?
    return

respondWith405 = (response) ->
    response.statusCode = 405
    response.setHeader('Content-Type', 'text/plain')
    response.end('405 "No Endpoint here!"\n')
    console.error(arguments[1]) if arguments[1]?
    return

respondWith413 = (response) ->
    response.statusCode = 413
    response.setHeader('Content-Type', 'text/plain')
    response.end('413 "Payload too large!"\n')
    console.error(arguments[1]) if arguments[1]?
    return

respondWith500 = (response) ->
    response.statusCode = 500
    response.setHeader("Content-Type", "text/plain")
    response.end('500 "Execution Error!"\n')
    console.error(arguments[1]) if arguments[1]?
    return

respondWithError = (response, errorString) ->
    response.statusCode = 422
    response.setHeader("Content-Type", "text/plain")
    response.end("422 #{errorString}\n")
    console.error(errorString) if arguments[1]?
    return

############################################################
## Result Response as application/json
respondWithResult = (response, jsonString) ->
    response.setHeader("Content-Type", "application/json")
    
    if typeof jsonString == "string" and jsonString.length > 0
        response.statusCode = 200
        response.end(jsonString)
    else
        response.statusCode = 204
        response.end()
    return

#endregion

############################################################
#region handler Creator functions
handlerCreators = Object.create(null)

############################################################
#region All Implementation
# allImplementations = (route, func, conf) ->
#     ## authOption is provided
#     authenticateRequest = conf.authOption
#     if typeof authenticateRequest != "function" 
#         throw new Error("authOption not a function @#{route}!")

#     ## argsSchema is provided
#     validateArgs = createValidator(conf.argsSchema)
#     if typeof validateArgs != "function"
#         throw new Error("validateArgs is not a function @#{route}!")

#     ## resultSchema is provided
#     validateResult = createValidator(conf.resultSchema)
#     if typeof validateResult != "function"
#         throw new Error("validateResult is not a function @#{route}!")

#     ## responseAuth is provided
#     addResponseAuth = conf.responseAuth
#     if typeof addResponseAuth != "function"
#         throw new Error("addResponseAuth is not a function @#{route}!")


#     handlerFunctionFragments = ->
#         ## 00xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Expectation without authOption or argsSchema -> no Body!
#         if ctx.bodyString != "" or ctx.bodyObj != undefined or
#         ctx.auth != undefined or ctx.args != undefined
#             return respondWith400(res, "Invalid Context for handler 0000 @#{route}!") 
        
#         ## Execution without argsSchema
#         Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
#         ## TODO: maybe set a timer to protect against forever hanging Promises
#         result = await func(undefined, ctx)

#         ## 10xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Execution with authOption
#         err = await authenticateRequest(req, ctx)
#         if err then return respondWith401(res, "Authentication fail! (#{err})")
#         Object.freeze(ctx.auth)

#         ctx.args = undefined
        
#         ## Execution without argsSchema
#         Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
#         ## TODO: maybe set a timer to protect against forever hanging Promises
#         result = await func(undefined, ctx)

#         ## 01xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Execution with argsSchema
#         err = validateArgs(ctx.args)
#         if err then return respondWith400(res, "Validation fail! (#{err})")

#         Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
#         ## TODO: maybe set a timer to protect against forever hanging Promises
#         result = await func(ctx.args, ctx)

#         ## 11xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Execution with authOption
#         err = await authenticateRequest(req, ctx)
#         if err then return respondWith401(res, "Authentication fail! (#{err})")
#         Object.freeze(ctx.auth)

#         ## Execution with argsSchema
#         err = validateArgs(ctx.args)
#         if err then return respondWith400(res, "Validation fail! (#{err})")

#         Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
#         ## TODO: maybe set a timer to protect against forever hanging Promises
#         result = await func(ctx.args, ctx)

#         ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

#         ## RESPONSE FRAGMENTS ######################################

#         ## xx00 - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Result Response without responseAuth or resultSchema
#         ## Fast Return on expected empty result
#         if !result then return respondWithResult(res, "")

#         ## Error String Response
#         if typeof result ==  "string" and result.length > 0
#            errorString = JSON.stringify(result)
#            return respondWithError(res, errorString)
        
#         ## Error String in Array
#         if Array.isArray(result) and result.length == 1 and 
#         typeof result[0] == "string" and result[0].length > 0
#             errorString = JSON.stringify(result[0])
#             return respondWithError(res, errorString)
        
#         ## Error Object?
#         err = checkForValidErrorObject(result)
#         if err then return respondWith500(res, "Invalid result!")

#         ## Here we have a valid ErrorObject for the Response
#         errorString = '{"error":'+JSON.stringify(result.error)+'}'        
#         return respondWithError(res, errorString)

#         ## xx10 - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Result Response with resultSchema
#         err  = validateResult(result)
#         if !err ## valid result then return fast
#             return respondWithResult(res, JSON.stringify(result))

#         ## Invalid result is definitely an Error, just what type of Error? 
#         ## Error String Response
#         if typeof result == "string" and result.length > 0
#             errorString = JSON.stringify(result)
#             return respondWithError(res, errorString)

#         ## Error String in Array
#         if Array.isArray(result) and result.length == 1 and 
#         typeof result[0] == "string" and result[0].length > 0
#             errorString = JSON.stringify(result[0])
#             return respondWithError(res, errorString)
        
#         ## Error Object?
#         err = checkForValidErrorObject(result)
#         if err then return respondWith500(res, "Invalid result!")

#         ## Here we have a valid ErrorObject for the Response
#         errorString = '{"error":'+JSON.stringify(result.error)+'}'        
#         return respondWithError(res, errorString)

#         ## xx01 - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Result Response with responseAuth
#         if !result ## fast Return on expected empty result
#             resultString = await addResponseAuth('{"result":""}', ctx)
#             return respondWithResult(res, resultString)
        
#         ## Nonempty result is definitely an Error, just what type of Error? 
#         ## Error String response with responseAuth
#         if typeof result == "string" and result.length > 0
#             errorString = '{"error":'+JSON.stringify(result)+'}'
#             errorString = await addResponseAuth(errorString, ctx)
#             return respondWithError(res, errorString)

#         ## Error String in Array
#         if Array.isArray(result) and result.length == 1 and 
#         typeof result[0] == "string" and result[0].length > 0
#             errorString = '{"error":'+JSON.stringify(result[0])+'}'
#             errorString = await addResponseAuth(errorString, ctx)
#             return respondWithError(res, errorString)

#         ## Error Object?
#         err = checkForValidErrorObject(result)
#         ## No ResponseAuth on Complete Execution failure
#         if err then return respondWith500(res, "Invalid result!")

#         ## Here we hve a valid ErrorObject for the Response with responseAuth
#         errorString = '{"error":'+JSON.stringify(result.error)+'}'        
#         errorString = await addResponseAuth(errorString, ctx)
#         return respondWithError(res, errorString)

        
#         ## xx11 - - - - - - - - - - - - - - - - - - - - - - - - - - -
#         ## Result Response with resultSchema and responseAuth
#         err  = validateResult(result)
#         if !err ## valid result then return fast
#             resultString = '{"result":'+JSON.stringify(result)+'}'
#             resultString = await addResponseAuth(resultString, ctx)
#             return respondWithResult(res, resultString)

#         ## Invalid result is definitely an Error, just what type of Error? 
#         ## Error String response with responseAuth
#         if typeof result == "string" and result.length > 0
#             errorString = '{"error":'+JSON.stringify(result)+'}'
#             errorString = await addResponseAuth(errorString, ctx)
#             return respondWithError(res, errorString)
        
#         ## Error String in Array
#         if Array.isArray(result) and result.length == 1 and 
#         typeof result[0] == "string" and result[0].length > 0
#             errorString = '{"error":'+JSON.stringify(result[0])+'}'
#             errorString = await addResponseAuth(errorString, ctx)
#             return respondWithError(res, errorString)

#         ## Error Object?
#         err = checkForValidErrorObject(result)
#         ## No ResponseAuth on Complete Execution failure
#         if err then return respondWith500(res, "Invalid result!")

#         ## Here we have a valid ErrorObject as response Error
#         errorString = '{"error":'+JSON.stringify(result.error)+'}'        
#         errorString = await addResponseAuth(errorString, ctx)
#         return respondWithError(res, errorString)

#endregion

############################################################
handlerCreators["0000"] = (route, func, conf) -> #0
    # Nothing is provided

    handlerFunction = (req, res, ctx) ->
        ## 00xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Expectation without authOption or argsSchema -> no Body!
        ## bodyString must be empty string -> auth and args as well
        ## bodyObj must be undefined
        if ctx.bodyString != "" or ctx.auth != "" or ctx.args != "" or
        !(ctx.bodyObj == undefined)
            return respondWith400(res, "Invalid Context for handler 0000 @#{route}!") 
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx00 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response without responseAuth or resultSchema
        ## Fast Return on expected empty result
        if !result then return respondWithResult(res, "")

        ## Error String Response
        if typeof result ==  "string" and result.length > 0
           errorString = JSON.stringify(result)
           return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object 
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)

    return handlerFunction

############################################################
handlerCreators["1000"] = (route, func, conf) -> #1 aO
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function" 
        throw new Error("authOption not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 10xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ctx.args = undefined
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx00 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response without responseAuth or resultSchema
        ## Fast Return on expected empty result
        if !result then return respondWithResult(res, "")

        ## Error String Response
        if typeof result ==  "string" and result.length > 0
           errorString = JSON.stringify(result)
           return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object 
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)

    return handlerFunction

############################################################
handlerCreators["0100"] = (route, func, conf) -> #2 aS
    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")
    
    handlerFunction = (req, res, ctx) ->
        ## 01xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx00 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response without responseAuth or resultSchema
        ## Fast Return on expected empty result
        if !result then return respondWithResult(res, "")

        ## Error String Response
        if typeof result ==  "string" and result.length > 0
           errorString = JSON.stringify(result)
           return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object 
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)

    return handlerFunction

############################################################
handlerCreators["1100"] = (route, func, conf) -> #3 aO + aS
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function" 
        throw new Error("authOption not a function @#{route}!")
    
    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 11xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx00 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response without responseAuth or resultSchema
        ## Fast Return on expected empty result
        if !result then return respondWithResult(res, "")

        ## Error String Response
        if typeof result ==  "string" and result.length > 0
           errorString = JSON.stringify(result)
           return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object 
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)


    return handlerFunction

############################################################
handlerCreators["0010"] = (route, func, conf) -> #4 rS

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 00xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Expectation without authOption or argsSchema -> no Body!
        ## bodyString must be empty string -> auth and args as well
        ## bodyObj must be undefined
        if ctx.bodyString != "" or ctx.auth != "" or ctx.args != "" or
        !(ctx.bodyObj == undefined)
            return respondWith400(res, "Invalid Context for handler 0010 @#{route}!") 
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx10 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema
        err  = validateResult(result)
        if !err ## valid result then return fast
            return respondWithResult(res, JSON.stringify(result))

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String Response
        if typeof result == "string" and result.length > 0
            errorString = JSON.stringify(result)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object?
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)

    return handlerFunction

############################################################
handlerCreators["1010"] = (route, func, conf) -> #5 a0 + rS
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function"
        throw new Error("authOption not a function @#{route}!")

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 10xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ctx.args = undefined
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx10 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema
        err  = validateResult(result)
        if !err ## valid result then return fast
            return respondWithResult(res, JSON.stringify(result))

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String Response
        if typeof result == "string" and result.length > 0
            errorString = JSON.stringify(result)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object?
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)
    return handlerFunction

############################################################
handlerCreators["0110"] = (route, func, conf) -> #6 aS + rS
    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 01xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with argsSchema
        # log "@handler 0110 of #{route}"
        # olog ctx
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx10 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema
        err  = validateResult(result)
        if !err ## valid result then return fast
            return respondWithResult(res, JSON.stringify(result))

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String Response
        if typeof result == "string" and result.length > 0
            errorString = JSON.stringify(result)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object?
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)

    return handlerFunction

############################################################
handlerCreators["1110"] = (route, func, conf) -> #7 aO + aS + rS
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function" 
        throw new Error("authOption not a function @#{route}!")

    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 11xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx10 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema
        err  = validateResult(result)
        if !err ## valid result then return fast
            return respondWithResult(res, JSON.stringify(result))

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String Response
        if typeof result == "string" and result.length > 0
            errorString = JSON.stringify(result)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = JSON.stringify(result[0])
            return respondWithError(res, errorString)
        
        ## Error Object?
        err = checkForValidErrorObject(result)
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject for the Response
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        return respondWithError(res, errorString)

    return handlerFunction

############################################################
handlerCreators["0001"] = (route, func, conf) -> #8 rA
    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 00xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Expectation without authOption or argsSchema -> no Body!
        ## bodyString must be empty string -> auth and args as well
        ## bodyObj must be undefined
        if ctx.bodyString != "" or ctx.auth != "" or ctx.args != "" or
        !(ctx.bodyObj == undefined)
            return respondWith400(res, "Invalid Context for handler 0001 @#{route}!") 
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx01 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with responseAuth
        if !result ## fast Return on expected empty result
            resultString = await addResponseAuth('{"result":""}', ctx)
            return respondWithResult(res, resultString)
        
        ## Nonempty result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we hve a valid ErrorObject for the Response with responseAuth
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

############################################################
handlerCreators["1001"] = (route, func, conf) -> #9 aO + rA
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function" 
        throw new Error("authOption not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 10xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ctx.args = undefined
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx01 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with responseAuth
        if !result ## fast Return on expected empty result
            resultString = await addResponseAuth('{"result":""}', ctx)
            return respondWithResult(res, resultString)
        
        ## Nonempty result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we hve a valid ErrorObject for the Response with responseAuth
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

############################################################
handlerCreators["0101"] = (route, func, conf) -> #10 aS + rA
    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 01xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx01 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with responseAuth
        if !result ## fast Return on expected empty result
            resultString = await addResponseAuth('{"result":""}', ctx)
            return respondWithResult(res, resultString)
        
        ## Nonempty result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we hve a valid ErrorObject for the Response with responseAuth
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

############################################################
handlerCreators["1101"] = (route, func, conf) -> #11 aO + aS + rA
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function" 
        throw new Error("authOption not a function @#{route}!")

    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 11xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx01 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with responseAuth
        if !result ## fast Return on expected empty result
            resultString = await addResponseAuth('{"result":""}', ctx)
            return respondWithResult(res, resultString)
        
        ## Nonempty result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we hve a valid ErrorObject for the Response with responseAuth
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

############################################################
handlerCreators["0011"] = (route, func, conf) -> #12 rS + rA
    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 00xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Expectation without authOption or argsSchema -> no Body!
        ## bodyString must be empty string -> auth and args as well
        ## bodyObj must be undefined
        if ctx.bodyString != "" or ctx.auth != "" or ctx.args != "" or
        !(ctx.bodyObj == undefined)
            return respondWith400(res, "Invalid Context for handler 0011 @#{route}!") 
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)


        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx11 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema and responseAuth
        err  = validateResult(result)
        if !err ## valid result then return fast
            resultString = '{"result":'+JSON.stringify(result)+'}'
            resultString = await addResponseAuth(resultString, ctx)
            return respondWithResult(res, resultString)

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject as response Error
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)

    
    return handlerFunction

############################################################
handlerCreators["1011"] = (route, func, conf) -> #13 aO + rS + rA
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function" 
        throw new Error("authOption not a function @#{route}!")

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 10xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ctx.args = undefined
        
        ## Execution without argsSchema
        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(undefined, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx11 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema and responseAuth
        err  = validateResult(result)
        if !err ## valid result then return fast
            resultString = '{"result":'+JSON.stringify(result)+'}'
            resultString = await addResponseAuth(resultString, ctx)
            return respondWithResult(res, resultString)

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject as response Error
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

############################################################
handlerCreators["0111"] = (route, func, conf) -> #14 aS + rS + rA
    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 01xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx11 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema and responseAuth
        err  = validateResult(result)
        if !err ## valid result then return fast
            resultString = '{"result":'+JSON.stringify(result)+'}'
            resultString = await addResponseAuth(resultString, ctx)
            return respondWithResult(res, resultString)

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject as response Error
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

############################################################
handlerCreators["1111"] = (route, func, conf) -> #15 aO + aS + rS + rA
    # log "handlerCreator 1111 @#{route}"
    ## authOption is provided
    authenticateRequest = conf.authOption
    if typeof authenticateRequest != "function"
        throw new Error("authOption not a function @#{route}!")

    ## argsSchema is provided
    validateArgs = createValidator(conf.argsSchema)
    if typeof validateArgs != "function"
        throw new Error("validateArgs is not a function @#{route}!")

    ## resultSchema is provided
    validateResult = createValidator(conf.resultSchema)
    if typeof validateResult != "function"
        throw new Error("validateResult is not a function @#{route}!")

    ## responseAuth is provided
    addResponseAuth = conf.responseAuth
    if typeof addResponseAuth != "function"
        throw new Error("addResponseAuth is not a function @#{route}!")

    handlerFunction = (req, res, ctx) ->
        ## 11xx - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Execution with authOption
        err = await authenticateRequest(req, ctx)
        if err then return respondWith401(res, "Authentication fail! (#{err})")
        Object.freeze(ctx.auth)

        ## Execution with argsSchema
        err = validateArgs(ctx.args)
        if err then return respondWith400(res, "Validation fail! (#{err})")

        Object.freeze(ctx) ## some bit of added safety I guess... maybe deep freeze?
        ## TODO: maybe set a timer to protect against forever hanging Promises
        result = await func(ctx.args, ctx)

        ## ## ## EXECUTED ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##

        ## xx11 - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ## Result Response with resultSchema and responseAuth
        err  = validateResult(result)
        if !err ## valid result then return fast
            resultString = '{"result":'+JSON.stringify(result)+'}'
            resultString = await addResponseAuth(resultString, ctx)
            return respondWithResult(res, resultString)

        ## Invalid result is definitely an Error, just what type of Error? 
        ## Error String response with responseAuth
        if typeof result == "string" and result.length > 0
            errorString = '{"error":'+JSON.stringify(result)+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)
        
        ## Error String in Array
        if Array.isArray(result) and result.length == 1 and 
        typeof result[0] == "string" and result[0].length > 0
            errorString = '{"error":'+JSON.stringify(result[0])+'}'
            errorString = await addResponseAuth(errorString, ctx)
            return respondWithError(res, errorString)

        ## Error Object?
        err = checkForValidErrorObject(result)
        ## No ResponseAuth on Complete Execution failure
        if err then return respondWith500(res, "Invalid result!")

        ## Here we have a valid ErrorObject as response Error
        errorString = '{"error":'+JSON.stringify(result.error)+'}'        
        errorString = await addResponseAuth(errorString, ctx)
        return respondWithError(res, errorString)
    
    return handlerFunction

#endregion


############################################################
#region Function Exports
export sciAdd = (route, func, conf) ->
    throw new Error("Server already running!") unless serverObj == null
    throw new Error("Route not a string!") unless typeof route == "string"
    throw new Error("Func not a function!") unless typeof func == "function"
    throw new Error("Cannot add route twice!") if sciRegistry[route]?
    throw new Error("function must be defined!") if !func?
    if !conf? or typeof conf != "object" then conf = Object.create(null)
    sciRegistry[route] = { func, conf }
    return

############################################################
export setValidatorCreator = (func) ->
    throw new Error("Server already running!") unless serverObj == null
    throw new Error("Func not a function!") unless typeof func == "function"
    createValidator = func
    return

export setUpgradeHandler = (func) ->
    throw new Error("Server already running!") unless serverObj == null
    throw new Error("Func not a function!") unless typeof func == "function"
    conectionUpgradeHandler = func
    return

############################################################
export sciStartServer = (o) ->
    log "sciStartServer"
    o = Object.create(null) unless o? and typeof o == "object"

    globalBodySizeLimit = o.bodySizeLimit || defaultBodySizeLimit

    requestTimeout = o.requestTimeout || defaultRequestTimeout
    headersTimeout = o.headersTimeout || defaultHeadersTimeout
    keepAliveTimeout = o.keepAliveTimeout || defaultKeepAliveTimeout
    maxHeadersCount = o.maxHeadersCount || defaultMaxHeadersCount
    maxHeaderSize = o.maxHeaderSize || defaultMaxHeaderSize

    ## Compiling Routes from Registry
    ## Entry = [key, routeInfo] where routeInfo = { handler, bodySizeLimit }
    routeEntries = compileRoutes(sciRegistry)
    routeInfoMap[re[0]] = re[1] for re in routeEntries
    # olog routeInfoMap
    sciRegistry = null ## not needed anymore -> GC

    httpOptions = {
        headersTimeout, 
        maxHeaderSize,
        requestTimeout, 
        keepAliveTimeout   
    }

    serverObj = http.createServer(httpOptions)
    serverObj.on("request", mainRequestHandler)
    serverObj.on("upgrade", conectionUpgradeHandler)
    serverObj.on("clientError", clientErrorHandler)

    ## default backlog is undefined
    if typeof o.backlog == "number" then backlog = o.backlog
    ## default listenOn is 3333
    listenOn = o.listenOn || 3333

    listenParams = { backlog, listenOn }
    await setServerListening(listenParams)
    olog { listeningMode }

    ## Try to terminate gracefully
    process.on("SIGTERM", terminateServer)
    process.on("SIGINT", terminateServer)
    return 
        
#endregion