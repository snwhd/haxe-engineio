# haxe-engineio

A Haxe implementation of the engine.io protocol.

- Server depends on sys, (tested on cpp and neko)
- Client tested on cpp, neko

## Install
Dependencies for websocket, url parsing, http server and client.

```
haxelib git haxe-engineio https://github.com/snwhd/haxe-engineio.git
# TODO: haxelib install haxe-engineio
```

## Example Server

```haxe
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
                    // received string data
                    trace('echoing "$s" to ${client.sid}');
                    server.sendStringMessage(client, s);
                case PBinary(b):
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
        while (true) {
            Sys.sleep(1.0);
        }
    }

}
```
