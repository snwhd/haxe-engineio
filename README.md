# haxe-engineio

A Haxe implementation of the engine.io protocol.

- Server depends on sys, (tested on cpp and neko)
- Client tested on cpp, neko

## Install
```
haxelib git haxe-engineio https://github.com/snwhd/haxe-engineio.git
# TODO: haxelib install haxe-engineio
```

Depends on other packages for websocket, url parsing, http server and client.

## Example Server

```haxe
import engineio.Server;


class Main {

    public static function main() {

        var server = new Server(); // immediately spawns http server. Packets
                                   // are not processed until main thread starts

        server.debug = true;       // optionally enable logging

        // setup handlers
        server.onOpened = function(client) {
            trace('new connection: ${client.sid}');
        }
        server.onUpgraded = function(client) {
            trace('upgrade to websocket: ${client.sid}');
        }
        server.onMessage = function(client, data: StringOrBinary) {
            switch (data) {
                case PString(s):
                    // received String data
                    trace('echoing "$s" to ${client.sid}');
                    server.sendStringMessage(client, s);
                case PBinary(b):
                    // received haxe.io.Bytes data
                    trace('echoing binary data to ${client.sid}');
                    server.sendBytesMessage(client, b);
            }
        }
        server.onClosed = function(sid: String) {
            trace('disconnected: $sid');
        }

        // start thread for handling engine.io packets
        server.startMainThread();

        // start thead for handling websocket connections
        server.startWebsocketThread();

        // do whatever your app does - engine.io is handled in
        // background threads
    }

}
```

## Example Client

```haxe
import engineio.Client;


class Main {

    public static function main() {
        var client = new Client();
        client.onConnect = function() {
            trace('connected: ${client.sid}');
        }
        client.onMessage = function(data) {
            trace(data);
        }
        client.onDisconnect = function() {
            trace("disconnected");
        }

        client.connect("ws://localhost:8080");
        while (true) {
            // call client.process in an update loop or another thread
            client.process();
            Sys.sleep(0.1);
        }
    }

}
```

## Testing

`eioclient.py` and `uiserver.py` use python's engineio implementation for
testing haxe-engineio.
