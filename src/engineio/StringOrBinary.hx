package engineio;


enum StringOrBinary {

    PString(s: String);
    PBinary(b: haxe.io.Bytes);

}
