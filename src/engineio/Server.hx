package engineio;

import hx_webserver.HTTPServer;
import hx_webserver.HTTPRequest;
import hx_webserver.HTTPResponse;
import hx_webserver.RouteMap;
import hx_webserver.Query;

import haxe.net.WebSocket;
import haxe.net.Socket2;


typedef ClientInfo = {
    nextPing: Float,
    lastPong: Float,
    socket: WebSocket,
}


class Server {

    private static var SID_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYA0123456789";

    public var pingInterval: Int;
    public var pingTimeout: Int;
    public var maxPayload = 100000;

    private var route: String;
    private var http: HTTPServer;
    private var sessions: Map<String, ClientInfo> = [];

    public function new(
        ?webserver: HTTPServer,
        route = "/engine.io/",
        pingInterval = 25,
        pingTimeout = 20
    ): Void {
        this.pingInterval = pingInterval;
        this.pingTimeout = pingTimeout;
        this.route = route;

        if (webserver == null) {
            webserver = this.createWebserver();
        }
        this.attachWebserver(webserver);
        this.http = webserver;
    }

    public function process() {
        // TODO: move to thread
        var now = haxe.Timer.stamp();
        var toRemove: Array<String> = [];
        for (sid => state in this.sessions.keyValueIterator()) {
            try {
                var expiry = state.lastPong + this.pingInterval + this.pingTimeout;
                if (expiry < now) {
                    // end session
                    state.socket.close();
                    toRemove.push(sid);
                    continue;
                }
                if (state.nextPing <= now) {
                    this.sendPacket(state, new Packet(PING, null));
                    state.nextPing = now + this.pingInterval;
                }
                if (state.socket != null) {
                    state.socket.process();
                }
            } catch (err) {
                trace('error processing client: $err');
                toRemove.push(sid);
            }
        }

        for (sid in toRemove) {
            this.sessions.remove(sid);
        }
    }

    private function createWebserver() {
        var webserver = new HTTPServer("0.0.0.0", 8080, true);
        return webserver;
    }

    private function attachWebserver(webserver: HTTPServer) {
        var routes = new RouteMap();
        routes.add(this.route, this.websocketRoute);
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
                    this.sessions[sid] = {
                        socket: null,
                        nextPing: haxe.Timer.stamp() + this.pingInterval,
                        lastPong: haxe.Timer.stamp()
                    };
                    var packet = new Packet(OPEN, PString(payload));
                    return this.packetResponse(packet);
                } else if (this.sessions.exists(sid) && this.sessions[sid].socket == null) {
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
        if (!this.sessions.exists(sid) || this.sessions[sid].socket != null) {
            return new HTTPResponse(BadRequest);
        }

        var state = this.sessions[sid];

        var socket = Socket2.createFromExistingSocket(request.client);
        var ws = WebSocket.createFromAcceptedSocket(socket);
        ws.onmessageString = this.onWsString.bind(state);
        ws.onmessageBytes = this.onWsBytes.bind(state);
        ws.onopen = this.onWsOpen.bind(state);

        state.socket = ws;

        // we alrady read the http request, inject that data into ws
        var wsDynamic: Dynamic = ws;
        @:privateAccess wsDynamic.httpHeader = request.methods.join(" ");
        @:privateAccess wsDynamic.httpHeader += "\r\n";
        @:privateAccess wsDynamic.httpHeader += request.data;
        @:privateAccess wsDynamic.needHandleData = true;

        var response = new HTTPResponse();
        response.suppress = true;
        return response;
    }

    private function onWsString(state: ClientInfo, s: String) {
        var packet = Packet.decodeString(s);
        this.handlePacket(state, packet);
    }

    private function onWsBytes(state: ClientInfo, b: haxe.io.Bytes) {
        var packet = Packet.decodeBytes(b);
        this.handlePacket(state, packet);
    }

    private function handlePacket(state: ClientInfo, packet: Packet) {
        switch (packet.type) {
            case UPGRADE: this.sendPacket(state, new Packet(NOOP, null));
            case MESSAGE: this.onMessage(state, packet.data);
            case CLOSE: // TODO
            case PING: this.handlePing(state, packet);
            case PONG: this.handlePong(state, packet);
            case OPEN:
            case NOOP:
        }
    }

    private function onWsOpen(state: ClientInfo) {
    }

    private function handlePing(state: ClientInfo, packet: Packet) {
        switch (packet.data) {
            case PString("probe"):
                this.sendWsPacket(state.socket, new Packet(PONG, packet.data));
            default:
        }
    }

    private function handlePong(state: ClientInfo, packet: Packet) {
        state.lastPong = haxe.Timer.stamp();
    }

    private function sendWsPacket(ws: WebSocket, packet: Packet) {
        switch (packet.encode()) {
            case PString(s):
                ws.sendString(s);
            case PBinary(b):
                ws.sendBytes(b);
        }
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

    private function sendPacket(state: ClientInfo, packet: Packet) {
        if (state.socket != null) {
            this.sendWsPacket(state.socket, packet);
        } else {
            // TODO: enqueue polling packet
        }
    }

    public dynamic function onMessage(state: ClientInfo, data: StringOrBinary) {
    }
}
