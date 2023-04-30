package engineio;


class Packet {

    public var type (default, null): PacketType;
    public var data (default, null): StringOrBinary;
    public var json (get, null): Dynamic;

    public function new(type: PacketType, data: StringOrBinary) {
        this.type = type;
        this.data = data;
    }

    public function get_json(): Dynamic {
        if (this.json == null ) {
            this.json = haxe.Json.parse(switch(this.data) {
                case PString(s): s;
                case PBinary(b): b.toString();
            });
        }
        return this.json;
    }

    public function encode(b64=false) : StringOrBinary {
        var typeInt: Int = this.type;

        switch (this.data) {
            case PString(s): {
                return PString('$typeInt$s');
            }
            case PBinary(b): {
                if (b64) {
                    var b64data = haxe.crypto.Base64.encode(b);
                    // TODO: this returns a string?
                    return  PString('b$b64data');
                } else {
                    return PBinary(b);
                }
            }
            case null: return PString('$typeInt');
        }
    }

    public static function decode(encoded: StringOrBinary) {
        return switch (encoded) {
            case PString(s): Packet.decodeString(s);
            case PBinary(b): Packet.decodeBytes(b);
        }
    }

    public static function decodeString(s: String): Packet {
        if (s.charAt(0) == 'b') {
            // base64 encoded binary payload
            // TODO: these are always MESSAGE type?
            return Packet.decodeBytes(haxe.crypto.Base64.decode(s.substr(1)));
        }

        var type: PacketType = Std.parseInt(s.charAt(0));
        var data: StringOrBinary = PString(s.substr(1));
        return new Packet(type, data);
    }

    public static function decodeBytes(b: haxe.io.Bytes): Packet {
        return new Packet(MESSAGE, PBinary(b));
    }

}
