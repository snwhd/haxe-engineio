package engineio.test;

import engineio.PacketType;
import engineio.Packet;
import engineio.Client;


class Main {

    public static function main() {
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

        // var p = Packet.decodeString('4{"asdf": 1}');
        // trace(p.data);
        // trace(p.json.asdf);
    }

}
