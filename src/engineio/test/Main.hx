package engineio.test;

import engineio.PacketType;
import engineio.Packet;


class Main {

    public static function main() {
        var p = Packet.decodeString('4{"asdf": 1}');
        trace(p.data);
        trace(p.json.asdf);
    }

}
