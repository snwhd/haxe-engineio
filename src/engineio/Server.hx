package engineio;

import hx_webserver.HTTPServer;
import hx_webserver.HTTPRequest;
import hx_webserver.HTTPResponse;
import hx_webserver.RouteMap;
import hx_webserver.Query;

import haxe.net.WebSocket;
import haxe.net.Socket2;

import thx.Set;


typedef ClientInfo = {
    nextPing: Float,
    lastPong: Float,
    socket: WebSocket,
    queue: sys.thread.Deque<Packet>,
    sid: String,
}


enum StateChange {
    OPENED;
    CLOSED;
}


/*
 *   On thread is created on start in HTTPServer for accepting new connectiosn,
 *   and spawns a new thread for each incoming request.
 *      - long-polling get requests
 *      - incoming packet posts
 *      - websocket upgrade
 *
 *   One is used for processing websockets, this is started via
 *   Server.startWebsocketThread(), or manually with Server.processWebsocketThread()
 *
 *   Both threads above place packets into a queue for processing in another
 *   thread, which will trigger the dynamic callbacks (onOpened, onUpgraded,
 *   onMessage). This thread is started with Server.startMainThread, or
 *   manuall with Server.processMainThread()
 *
 */


class Server {

    private static var SID_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYA0123456789";

    public var debug = false;

    public var pingInterval: Int;
    public var pingTimeout: Int;
    public var maxPayload = 100000;

    private var route: String;
    private var http: HTTPServer;

    public var processDowntime = 0.2;

    private var sessions: Map<String, ClientInfo> = [];
    private var sessionsMutex = new sys.thread.Mutex();
    private var sessionsToClose = Set.createString();

    private var queue: sys.thread.Deque<{packet: Packet, sid: String}>;
    private var stateQueue: sys.thread.Deque<{state: StateChange, sid: String}>;

    public var cors: String;
    private var host: String;
    private var port: Int;

    public function new(
        ?webserver: HTTPServer,
        route = "/engine.io/",
        pingInterval = 25,
        pingTimeout = 20,
        host = "0.0.0.0",
        port = 8080
    ): Void {
        this.pingInterval = pingInterval;
        this.pingTimeout = pingTimeout;
        this.route = route;

        this.host = host;
        this.port = port;

        this.queue = new sys.thread.Deque();
        this.stateQueue = new sys.thread.Deque();
        this.http = this.setupWebserver(webserver);
    }

    private function setupWebserver(webserver: HTTPServer): HTTPServer {
        if (webserver == null) {
            webserver = new HTTPServer(this.host, this.port, false);
        }
        var routes = new RouteMap();
        routes.add(this.route, this.websocketRoute);
        routes.attach(webserver);
        return webserver;
    }

    public function startMainThread() {
        sys.thread.Thread.create(() -> {
            _debug("main thread started");
            while (true) {
                this.processMainThread();
                Sys.sleep(this.processDowntime);
            }
        });
    }

    private function processMainThread() {
        // callback for new connections
        var item = this.stateQueue.pop(false);
        while (item != null) {
            switch (item.state) {
                case CLOSED:
                    this.onClosed(item.sid);
                case OPENED: {
                    var state = this.getSession(item.sid);
                    if (state != null) {
                        this.onOpened(state);
                    }
                }
            }
            item = this.stateQueue.pop(false);
        }

        // handling incoming packets
        var item = this.queue.pop(false);
        while (item != null) {
            var state = this.getSession(item.sid);
            if (state != null) {
                this.handlePacket(state, item.packet);
            }
            item = this.queue.pop(false);
        }
    }

    public function startWebsocketThread() {
        sys.thread.Thread.create(() -> {
            _debug("websocket thread started");
            while (true) {
                this.processWebsocketThread();
                Sys.sleep(this.processDowntime);
            }
        });
    }

    public function processWebsocketThread() {
        var now = haxe.Timer.stamp();

        var toRemove = [];

        this.sessionsMutex.acquire();
        var toClose = this.sessionsToClose;
        this.sessionsToClose = Set.createString();
        for (sid => state in this.sessions.keyValueIterator()) {
            try {
                if (!this.processClient(state, now) || toClose.exists(sid)) {
                    toRemove.push(sid);
                }
            } catch (err) {
                var session = this.sessions[sid];
                if (session.socket != null) {
                    session.socket.close();
                }
                toRemove.push(sid);
                _debug('error processing client: $err');
                _debug('------- Exception -------');
                for (item in haxe.CallStack.exceptionStack()) {
                    _debug(' $item');
                }
                _debug('-------------------------');
            }
        }
        this.sessionsMutex.release();

        for (sid in toRemove) {
            this.removeSession(sid);
            this.stateChanged(sid, CLOSED);
        }
    }

    private function processClient(state: ClientInfo, now: Float): Bool {
        // kill sockets who don't respond to pings
        var expiry = state.lastPong + this.pingInterval + this.pingTimeout;
        if (expiry < now) {
            state.socket.close();
            return false;
        }

        // send new pings
        if (state.nextPing <= now) {
            this.enqueueOutgoingPacket(state, new Packet(PING, null));
            state.nextPing = now + this.pingInterval;
        }

        // send all websocket outgoing packets
        if (state.socket != null && state.socket.readyState == Open) {
            var packet = state.queue.pop(false);
            while (packet != null) {
                this.sendWsPacket(state.socket, packet);
                packet = state.queue.pop(false);
            }
        }

        // process incoming packets
        if (state.socket != null) {
            state.socket.process();
        }

        return true;
    }

    //
    // transport: polling
    //

    private function websocketRoute(request: HTTPRequest): HTTPResponse {
        _debug('http request: ${request.methods}');

        var query = Query.fromRequest(request);
        if (query.get("EIO") != "4") {
            _debug("invalid request: EIO");
            return new HTTPResponse(BadRequest);
        }

        var sid = query.get("sid");
        var transport = query.get("transport");
        var response = switch (request.methods[0]) {
            case "GET": this.handleGet(request, sid, transport);
            case "POST": this.handlePost(request, sid, transport);
            case method:
                _debug('invalid request: method $method');
                new HTTPResponse(MethodNotAllowed);
        }

        if (this.cors != null) {
            response.addHeader("Access-Control-Allow-Origin", this.cors);
        }
        return response;
    }

    private function handleGet(
        request: HTTPRequest,
        sid: String,
        transport: String
    ): HTTPResponse {
        if (transport == "websocket") {
            _debug('[${sid}] request to upgrade');
            return this.upgradeToWebsocket(request, sid);
        }

        if (transport != "polling") {
            _debug('[$sid] invalid transport: $transport');
            return new HTTPResponse(BadRequest);
        }

        if (sid != null) {
            var state = this.getSession(sid);
            if (state == null) {
                // invalid session id
                _debug('no such session: $sid');
                return new HTTPResponse(BadRequest);
            }

            var packet = null;
            var timeout = haxe.Timer.stamp() + 30;
            while (haxe.Timer.stamp() < timeout) {
                packet = state.queue.pop(false);
                if (packet != null) {
                    break;
                }
                Sys.sleep(0.1);
            }

            if (packet == null) {
                // timed out
                return new HTTPResponse();
            }

            var content: String = '';
            function appendPacket(packet: Packet) {
                if (content != '') {
                    content += "\x1e";
                }
                switch (packet.encode(true)) {
                    case PString(s): content += s;
                    default: throw "invalid packet encoding for HTTP";
                }
                return content.length < this.maxPayload;
            }

            appendPacket(packet);
            packet = state.queue.pop(false);
            while (packet != null) {
                if (!appendPacket(packet)) {
                    break;
                }
                packet = state.queue.pop(false);
            }

            var response = new HTTPResponse(Ok);
            response.addHeader("Content-Type", "text/plain; charset=UTF-8");
            response.content = content;
            return response;
        }

        // no sid, new session
        // a new connection, send OPEN
        var sid = this.generateSid();
        _debug('new session: $sid');
        var payload = haxe.Json.stringify({
            sid: sid,
            upgrades: ["websocket"],
            pingInterval: this.pingInterval * 1000,
            pingTimeout: this.pingTimeout * 1000,
            maxPayload: this.maxPayload,
        });
        var state = {
            sid: sid,
            socket: null,
            queue: new sys.thread.Deque(),
            nextPing: haxe.Timer.stamp() + this.pingInterval,
            lastPong: haxe.Timer.stamp()
        };
        this.addSession(state);
        this.stateChanged(sid, OPENED);
        var packet = new Packet(OPEN, PString(payload));
        return this.packetResponse(packet);
    }

    private function handlePost(
        request: HTTPRequest,
        sid: String,
        transport: String
    ): HTTPResponse {
        var state = this.getSession(sid);
        if (state == null || transport != "polling") {
            return new HTTPResponse(BadRequest);
        }

        var content = StringTools.ltrim(request.postData);
        var packets = content.split("\x1e");
        for (packet in packets) {
            var p = Packet.decodeString(packet);
            this.enqueueIncomingPacket(state, p);
        }

        return new HTTPResponse(Ok, "ok");
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

    //
    // transport: websocket
    //

    private function upgradeToWebsocket(request: HTTPRequest, sid: String) {
        var state = this.getSession(sid);
        if (state == null || state.socket != null) {
            return new HTTPResponse(BadRequest);
        }

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
        this.enqueueIncomingPacket(state, packet);
    }

    private function onWsBytes(state: ClientInfo, b: haxe.io.Bytes) {
        var packet = Packet.decodeBytes(b);
        this.enqueueIncomingPacket(state, packet);
    }

    private function onWsOpen(state: ClientInfo) {
    }

    //
    // packet receiving
    //

    private function enqueueIncomingPacket(state: ClientInfo, packet: Packet) {
        this.queue.add({packet: packet, sid: state.sid});
    }

    private function handlePacket(state: ClientInfo, packet: Packet) {
        _debug('handling packet: ${packet.type}');
        switch (packet.type) {
            case UPGRADE:
                state.queue = new sys.thread.Deque(); // clear incoming
                this.enqueueOutgoingPacket(state, new Packet(NOOP, null));
                this.onUpgraded(state);
            case MESSAGE: this.handleMessage(state, packet);
            case CLOSE: this.handleClose(state, packet);
            case PING: this.handlePing(state, packet);
            case PONG: this.handlePong(state, packet);
            case OPEN: _debug("server received OPEN");
            case NOOP: _debug("received NOOP");
        }
    }

    private function handleMessage(state: ClientInfo, packet: Packet) {
        this.onMessage(state, packet.data);
    }

    private function handleClose(state: ClientInfo, packet: Packet) {
        this.removeSession(state.sid);
        this.stateChanged(state.sid, CLOSED);
    }

    private function handlePing(state: ClientInfo, packet: Packet) {
        switch (packet.data) {
            case PString("probe"):
                this.enqueueOutgoingPacket(state, new Packet(PONG, packet.data));
            default:
        }
    }

    private function handlePong(state: ClientInfo, packet: Packet) {
        state.lastPong = haxe.Timer.stamp();
    }

    //
    // packet sending
    //

    public function enqueueOutgoingPacket(state: ClientInfo, packet: Packet) {
        state.queue.add(packet);
    }

    public function sendStringMessage(state: ClientInfo, s: String) {
        this.enqueueOutgoingPacket(state, new Packet(MESSAGE, PString(s)));
    }

    public function sendBytesMessage(state: ClientInfo, b: haxe.io.Bytes) {
        this.enqueueOutgoingPacket(state, new Packet(MESSAGE, PBinary(b)));
    }

    private function sendWsPacket(ws: WebSocket, packet: Packet) {
        _debug('sending ws packet: ${packet.type}');
        switch (packet.encode()) {
            case PString(s):
                ws.sendString(s);
            case PBinary(b):
                ws.sendBytes(b);
        }
    }

    public function closeSession(sid: String) {
        this.sessionsMutex.acquire();
        this.enqueueOutgoingPacket(this.sessions[sid], new Packet(CLOSE, null));
        this.sessionsToClose.add(sid);
        this.sessionsMutex.release();
    }

    //
    // util
    //

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
        while (this.sessionExists(sid)) {
            sid = nextSid();
        }
        return sid;
    }

    private inline function _debug(s: String) {
        #if debug
        if (this.debug) trace(s);
        #end
    }

    private function sessionExists(sid: String): Bool {
        this.sessionsMutex.acquire();
        var result = this.sessions.exists(sid);
        this.sessionsMutex.release();
        return result;
    }

    private function getSession(sid: String) : Null<ClientInfo> {
        if (sid == null || sid == "") return null;
        this.sessionsMutex.acquire();
        var session = this.sessions.get(sid);
        this.sessionsMutex.release();
        return session;
    }

    private function addSession(info: ClientInfo) {
        if (info == null || info.sid == null || info.sid == "") return;
        this.sessionsMutex.acquire();
        sessions[info.sid] = info;
        this.sessionsMutex.release();
    }

    private function removeSession(sid: String) {
        if (sid == null || sid == "") return;
        this.sessionsMutex.acquire();
        sessions.remove(sid);
        this.sessionsMutex.release();
    }

    private function stateChanged(sid: String, state: StateChange) {
        this.stateQueue.add({sid: sid, state: state});
    }

    //
    // callbacks
    //

    public dynamic function onOpened(state: ClientInfo) {
        _debug('[${state.sid}] connection opened');
    }

    public dynamic function onUpgraded(state: ClientInfo) {
        _debug('[${state.sid}] upgrade success');
    }

    public dynamic function onMessage(state: ClientInfo, data: StringOrBinary) {
        _debug('[${state.sid}] message: $data');
    }

    public dynamic function onClosed(sid: String) {
        _debug('[$sid] closed');
    }
}
