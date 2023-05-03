package engineio.test;

import engineio.PacketType;
import engineio.Packet;
import engineio.Client;
import engineio.Server;


class Main {

    public static function main() {
        // Main.testClient();
        Main.startServer();
    }

    private static function startServer() {
        var server = new Server();
        server.onOpened = function(client) {
            trace('opened');
        }
        server.onUpgraded = function(client) {
            trace('upgraded');
            server.enqueueOutgoingPacket(client, new Packet(MESSAGE, PString("success")));
        }

        server.debug = true;
        server.startMainThread();
        server.startWebsocketThread();
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
