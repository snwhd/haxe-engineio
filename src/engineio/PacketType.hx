package engineio;


enum abstract PacketType(Int) from Int to Int {

    var OPEN    = 0;
    var CLOSE   = 1;
    var PING    = 2;
    var PONG    = 3;
    var MESSAGE = 4;
    var UPGRADE = 5;
    var NOOP    = 6;

    @:to
    public static function toString(type: PacketType): String {
        return switch (type) {
            case OPEN:    'OPEN';
            case CLOSE:   'CLOSE';
            case PING:    'PING';
            case PONG:    'PONG';
            case MESSAGE: 'MESSAGE';
            case UPGRADE: 'UPGRADE';
            case NOOP:    'NOOP';
        }
    }

    @:from
    public static function fromString(type: String): PacketType {
        return switch (type.toLowerCase()) {
            case 'open':    OPEN;
            case 'close':   CLOSE;
            case 'ping':    PING;
            case 'pong':    PONG;
            case 'message': MESSAGE;
            case 'upgrade': UPGRADE;
            case 'NOOP':    NOOP;
            default: throw 'Invalid PacketType';
        }
    }

}
