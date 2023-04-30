package engineio;

import com.akifox.asynchttp.HttpRequest;
import com.akifox.asynchttp.HttpResponse;
import haxe.net.WebSocket;
import tink.url.Query;
import tink.Url;


enum ClientState {
    DISCONNECTED;
    CONNECTED;
}


enum Transport {
    POLLING;
    WEBSOCKET;
}


class Client {

    private var state: ClientState = DISCONNECTED;
    private var url: Url;

    private var supportedTransports: Array<Transport>;
    private var currentTransport: Transport;
    private var upgrading = false;
    private var fetching = false;
    private var ws: WebSocket;


    public var sid (default, null): String = null;

    private var pingInterval: Int;
    private var pingTimeout: Int;
    private var maxPayload: Int;

    public function new() {
    }

    public function connect(
        url: String,
        ?transports: Array<Transport>,
        ?headers: Map<String, String>,
        ?path = "/engine.io/"
    ): Void {
        if (this.state != DISCONNECTED) throw "Client is not disconnected";
        if (transports != null && transports.length == 0) throw "No transports";

        if (transports == null) transports = [POLLING, WEBSOCKET];
        if (headers == null) headers = [];

        this.supportedTransports = transports;
        this.currentTransport = transports[0];
        switch (this.currentTransport) {
            case POLLING: this.connectPolling(url, path, headers);
            case WEBSOCKET: this.connectWebsocket(url, path, headers);
        }
    }

    public function process() {
        if (this.ws != null) {
            this.ws.process();
        }
        if (this.currentTransport == POLLING) {
            this.fetchPollingPackets();
        }
    }

    public function disconnect() {
        switch (this.currentTransport) {
            case POLLING: this.disconnectPolling();
            case WEBSOCKET: this.disconnectWebsocket();
        }
        this.currentTransport = null;
        this.state = DISCONNECTED;
        this.upgrading = false;
        this.fetching = false;
        this.sid = null;
        this.url = null;
    }

    //
    // http polling
    //

    private function connectPolling(
        baseUrl: String,
        path: String,
        headers: Map<String, String>
    ): Void {
        var url: Url = baseUrl;
        var secure = switch (url.scheme) {
            case "https", "wss": "s";
            default: "";
        };
        var scheme = 'http$secure';
        this.url = Url.make({
            scheme: scheme,
            hosts: [url.host],
            path: path,
            query: {
                "EIO": "4",
                "transport": "polling",
            },
        });

        // TODO: headers

        new HttpRequest({
            url: this.url.toString(),
            callback: this.onConnectHttpResponse.bind(baseUrl, path, headers),
            callbackError: this.onConnectHttpError,
        }).send();
    }

    private function onConnectHttpResponse(
        baseUrl: String,
        path: String,
        headers: Map<String, String>,
        response: HttpResponse
    ): Void {
        if (response.status < 200 || response.status >= 300) {
            // TODO: connection refused
            return;
        }
        var payload = response.content;
        var packets: Array<Packet> = [];
        if (payload.substr(0, 2) == "d=") {
            throw "TODO: support jsonp post";
        } else {
            packets = [Packet.decodeString(payload)];
        }

        var openPacket = packets.shift();
        if (openPacket.type != OPEN) {
            throw "No OPEN packet";
        }

        var json = openPacket.json;
        this.pingInterval = Std.int(json.pingInterval / 1000);
        this.pingTimeout = Std.int(json.pingTimeout / 1000);
        this.maxPayload = json.maxPayload;
        this.sid = openPacket.json.sid;

        // rewrite the url to include sid in future requests
        this.url = Url.make({
            scheme: this.url.scheme,
            hosts: [this.url.host],
            path: this.url.path,
            query: {
                "EIO": "4",
                "transport": "polling",
                "sid": this.sid,
            },
        });

        this.currentTransport = POLLING;
        this.state = CONNECTED;
        this.onConnect();

        for (packet in packets) {
            this.handlePacket(packet);
        }

        var upgrades = json.upgrades;
        if (
            upgrades.contains("websocket") &&
            this.supportedTransports.contains(WEBSOCKET)
        ) {
            this.upgrading = true;
            this.connectWebsocket(baseUrl, path, headers);
        }
    }

    private function onConnectHttpError(response: HttpResponse) {
        this.disconnect();
    }

    private function sendPollingPacket(packet: Packet) {
        // TODO: batch send
        var content: Dynamic = switch (packet.encode()) {
            case PString(s): s;
            case PBinary(b): b;
        }

        new HttpRequest({
            method: "POST",
            content: content,
            url: this.url.toString(),
            callback: this.onSendHttpResponse,
            callbackError: this.onSendHttpError,
        }).send();
    }

    private function onSendHttpResponse(response: HttpResponse) {
    }

    private function onSendHttpError(response: HttpResponse) {
        this.disconnect();
    }

    private function fetchPollingPackets() {
        if (!this.fetching && this.sid != null) {
            this.fetching = true;
            new HttpRequest({
                url: this.url.toString(),
                callback: this.onPacketsHttpResponse,
                callbackError: this.onPacketsHttpError,
                timeout: this.pingInterval + this.pingTimeout,
            }).send();
        }
    }

    private function onPacketsHttpResponse(response: HttpResponse) {
        this.fetching = false;
        if (response.status < 200 || response.status >= 300) {
            // TODO: connection refused
            return;
        }
        var payload = response.content;
        var packets: Array<Packet> = [];
        if (payload.substr(0, 2) == "d=") {
            throw "TODO: support jsonp post";
        } else {
            packets = [Packet.decodeString(payload)];
        }
        for (packet in packets) {
            this.handlePacket(packet);
        }
    }

    private function onPacketsHttpError(response: HttpResponse) {
        this.disconnect();
    }

    private function disconnectPolling() {
    }

    //
    // websocket
    //

    private function connectWebsocket(
        baseUrl: String,
        path: String,
        headers: Map<String, String>,
    ): Void {
        var url: Url = baseUrl;
        var secure = switch (url.scheme) {
            case "https", "wss": "s";
            default: "";
        };
        var scheme = 'ws$secure';
        var query = url.query;
        if (this.upgrading) {
            query = query.with([
                "sid" => this.sid,
                "transport" => "websocket",
                "EIO" => "4",
            ]);
        }

        this.url = Url.make({
            scheme: scheme,
            hosts: [url.host],
            path: path,
            query: query,
        });

        // TODO: upgrade cookies and headers

        this.currentTransport = WEBSOCKET;
        var origin = 'http$secure://${this.url.host}';
        this.ws = WebSocket.create(this.url, null, origin);
        this.ws.onmessageString = this.onWsString;
        this.ws.onmessageBytes = this.onWsBytes;
        this.ws.onopen = this.onWsOpen;
    }

    private function sendWebsocketPacket(packet: Packet) {
        switch (packet.encode()) {
            case PString(s):
                this.ws.sendString(s);
            case PBinary(b):
                this.ws.sendBytes(b);
        }
    }

    private function disconnectWebsocket() {
        if (this.ws != null && this.ws.readyState != Closed) {
            this.ws.close();
        }
        this.ws = null;
    }

    private function onWsOpen() {
        if (this.upgrading) {
            this.sendPacket(new Packet(PING, PString("probe")));
        }
    }

    private function onWsString(s: String) {
        var packet = Packet.decodeString(s);
        switch (this.state) {
            case DISCONNECTED: {
                if (packet.type != OPEN) throw "no OPEN packet";
                var json = packet.json;
                this.pingInterval = Std.int(json.pingInterval / 1000);
                this.pingTimeout = Std.int(json.pingTimeout / 1000);
                this.maxPayload = json.maxPayload;
                this.sid = json.sid;

                this.currentTransport = WEBSOCKET;
                this.state = CONNECTED;
                this.onConnect();
            }
            case CONNECTED: {
                this.handlePacket(packet);
            }
        }
    }

    private function onWsBytes(b: haxe.io.Bytes) {
        if (this.state != CONNECTED) throw "binary payload before OPEN";
        var packet = Packet.decodeBytes(b);
        this.handlePacket(packet);
    }

    //
    // transport agnostic
    //

    private function handlePacket(packet: Packet) {
        switch (packet.type) {
            case UPGRADE, OPEN: throw 'received ${packet.type}';
            case MESSAGE: this.onMessage(packet.data);
            case CLOSE: this.disconnect();
            case PING: this.sendPong(packet.data);
            case PONG: this.handlePong(packet);
            case NOOP:
        }
    }

    private function sendPong(data) {
        this.sendPacket(new Packet(PONG, data));
    }

    private function handlePong(packet: Packet) {
        if (!this.upgrading) {
            throw 'received PONG, but not upgrading';
        }
        this.sendPacket(new Packet(UPGRADE, null));
        this.upgrading = false;
    }

    private function sendPacket(packet: Packet) {
        switch (this.currentTransport) {
            case POLLING: this.sendPollingPacket(packet);
            case WEBSOCKET: this.sendWebsocketPacket(packet);
        }
    }

    //
    // callbacks
    //

    public dynamic function onConnect() {
    }

    public dynamic function onMessage(data: StringOrBinary) {
    }

    public dynamic function onDisconnect() {
    }

}
