package engineio.test;

import engineio.PacketType;
import engineio.Packet;
import engineio.Client;
import engineio.Server;


class Main {

    public static function main() {
        // Main.testClient();
        Main.startServer();
        Main.waitForever();
    }

    private static function startServer() {
        var server = new Server();
        server.debug = true;
        server.startMainThread();
        server.startWebsocketThread();
    }

    private static function waitForever() {
        while (true) {
            Sys.sleep(0.5);
        }
    }

    private static function testClient() {
        var client = new Client();
        client.onConnect = function() {
            trace(client.sid);
        }
        client.onMessage = function(data) {
            trace(data);
        }
        client.onDisconnect = function() {
            trace('disconnected');
        }

        client.connect('ws://localhost:8080');
        while (true) {
            client.process();
            Sys.sleep(0.1);
        }
    }

}
