package engineio;

import hx_webserver.HTTPServer;
import hx_webserver.HTTPRequest;
import hx_webserver.HTTPResponse;
import hx_webserver.RouteMap;
import hx_webserver.Query;

import haxe.net.WebSocket;
import haxe.net.Socket2;


class Server {

    private static var SID_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYA0123456789";

    public var pingInterval: Int;
    public var pingTimeout: Int;
    public var maxPayload = 100000;

    private var http: HTTPServer;
    private var sessions: Map<String, WebSocket> = [];

    public function new(
        ?webserver: HTTPServer,
        pingInterval = 25,
        pingTimeout = 20,
    ): Void {
        this.pingInterval = pingInterval;
        this.pingTimeout = pingTimeout;

        if (webserver == null) {
            webserver = this.createWebserver();
        }
        this.attachWebserver(webserver);
        this.http = webserver;
    }

    public function process() {
        // TODO: move to thread
        for (sid => ws in this.sessions.keyValueIterator()) {
            ws.process();
        }
    }

    private function createWebserver() {
        var webserver = new HTTPServer("0.0.0.0", 8080, true);
        return webserver;
    }

    private function attachWebserver(webserver: HTTPServer) {
        var routes = new RouteMap();
        routes.add("/engine.io/", this.websocketRoute);
        routes.attach(webserver);
    }

    private function websocketRoute(request: HTTPRequest): HTTPResponse {
        var query = Query.fromRequest(request);
        if (query.get("EIO") != "4") {
            return new HTTPResponse(BadRequest);
        }

        var sid = query.get("sid");
        var transport = query.get("transport");
        return switch (request.methods[0]) {
            case "GET": this.handleGet(request, sid, transport);
            case "POST": this.handlePost(request, sid, transport);
            default: new HTTPResponse(MethodNotAllowed);
        }
    }

    private function handleGet(
        request: HTTPRequest,
        sid: String,
        transport: String
    ): HTTPResponse {
        var response: HTTPResponse;
        switch (transport) {
            case "websocket":
                response = this.upgradeToWebsocket(request, sid);
            case "polling":
                if (sid == null) {
                    // a new connection, send OPEN
                    var sid = this.generateSid();
                    var payload = haxe.Json.stringify({
                        sid: sid,
                        upgrades: ["websocket"],
                        pingInterval: this.pingInterval * 1000,
                        pingTimeout: this.pingTimeout * 1000,
                        maxPayload: this.maxPayload,
                    });
                    this.sessions[sid] = null;
                    var packet = new Packet(OPEN, PString(payload));
                    return this.packetResponse(packet);
                } else if (this.sessions.exists(sid) && this.sessions[sid] == null) {
                    response = new HTTPResponse();
                    // TODO wait for data
                } else {
                    response = new HTTPResponse(BadRequest);
                }
            default:
                response = new HTTPResponse(BadRequest);
        }
        return response;
    }

    private function packetResponse(packet: Packet) {
        var response = new HTTPResponse(Ok);
        response.addHeader("Content-Type", "text/plain; charset=UTF-8");
        response.content = switch (packet.encode()) {
            case PString(s): s;
            case PBinary(b): b;
        };
        return response;
    }

    private function handlePost(
        request: HTTPRequest,
        sid: String,
        transport: String
    ): HTTPResponse {
        if (sid == null || transport != "polling") {
            return new HTTPResponse(BadRequest);
        }
        // TODO: receive packet
        return new HTTPResponse(Ok, "ok");
    }

    private function upgradeToWebsocket(request: HTTPRequest, sid: String) {
        if (!this.sessions.exists(sid) || this.sessions[sid] != null) {
            return new HTTPResponse(BadRequest);
        }

        var socket = Socket2.createFromExistingSocket(request.client);
        var ws = WebSocket.createFromAcceptedSocket(socket);
        ws.onmessageString = this.onWsString;
        ws.onmessageBytes = this.onWsBytes;
        ws.onopen = this.onWsOpen;

        // we alrady read the http request, inject that data into ws
        var wsDynamic: Dynamic = ws;
        @:privateAccess wsDynamic.httpHeader = request.methods.join(" ");
        @:privateAccess wsDynamic.httpHeader += "\r\n";
        @:privateAccess wsDynamic.httpHeader += request.data;
        @:privateAccess wsDynamic.needHandleData = true;

        sessions[sid] = ws;

        var response = new HTTPResponse();
        response.suppress = true;
        return response;
    }

    private function onWsString(string: String) {
        trace('s: $string');
    }

    private function onWsBytes(bytes: haxe.io.Bytes) {
        trace('b: $bytes');
    }

    private function onWsOpen() {
        trace('opened');
    }

    private function generateSid() {
        function nextSid() {
            var sid = "";
            for (i in 0 ... 20) {
                var j = Math.floor(Math.random() * SID_CHARS.length);
                sid += SID_CHARS.charAt(j);
            }
            return sid;
        }

        var sid = nextSid();
        while (this.sessions.exists(sid)) {
            sid = nextSid();
        }
        return sid;
    }

}
