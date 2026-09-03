import bytes;
import strconv;
import utf8;

pub struct Member {
    pub key: []u8,
    pub value: Json,
}

pub enum Json {
    null,
    boolean(bool),
    number([]u8),
    string([]u8),
    array([]Json),
    object([]Member),
}

pub struct Error {
    pub message: []u8,
    pub offset: u64,
}

pub enum Parse {
    ok(Json),
    error(Error),
}

enum StringParse {
    ok([]u8),
    error(Error),
}

struct Reader {
    data: const []u8,
    pos: u64,
}

fn make_error(message: []u8, offset: u64) -> Error {
    return Error { message: message, offset: offset };
}

fn is_digit(ch: u8) -> bool {
    return ch >= '0' && ch <= '9';
}

fn is_hex(ch: u8) -> bool {
    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}

fn hex_value(ch: u8) -> u32 {
    if (ch >= '0' && ch <= '9') { return (ch - '0') as u32; }
    if (ch >= 'a' && ch <= 'f') { return (ch - 'a' + 10) as u32; }
    if (ch >= 'A' && ch <= 'F') { return (ch - 'A' + 10) as u32; }
    trap;
}

fn skip_ws(reader: ref Reader) {
    while (reader.pos < len(reader.data)) {
        var ch = reader.data[reader.pos];
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
            reader.pos += 1;
        } else {
            return;
        }
    }
}

fn read_hex4(reader: ref Reader) -> ?u32 {
    if (reader.pos + 4 > len(reader.data)) { return none; }
    var value: u32 = 0;
    for (var i: u64 = 0; i < 4; i += 1) {
        var ch = reader.data[reader.pos + i];
        if (!is_hex(ch)) { return none; }
        value = (value << 4) | hex_value(ch);
    }
    reader.pos += 4;
    return some(value);
}

fn parse_string(reader: ref Reader) -> StringParse {
    if (reader.pos >= len(reader.data) || reader.data[reader.pos] != '"') {
        return StringParse.error(make_error("expected string", reader.pos));
    }
    reader.pos += 1;
    var out: []u8 = [];
    while (reader.pos < len(reader.data)) {
        var ch = reader.data[reader.pos];
        reader.pos += 1;
        if (ch == '"') {
            return StringParse.ok(out);
        }
        if (ch < 0x20) {
            return StringParse.error(make_error("control byte in string", reader.pos - 1));
        }
        if (ch != '\\') {
            push(out, ch);
        } else {
            if (reader.pos >= len(reader.data)) {
                return StringParse.error(make_error("unfinished escape", reader.pos));
            }
            var esc = reader.data[reader.pos];
            reader.pos += 1;
            if (esc == '"' || esc == '\\' || esc == '/') { push(out, esc); }
            else if (esc == 'b') { push(out, 8); }
            else if (esc == 'f') { push(out, 12); }
            else if (esc == 'n') { push(out, '\n'); }
            else if (esc == 'r') { push(out, '\r'); }
            else if (esc == 't') { push(out, '\t'); }
            else if (esc == 'u') {
                var high_opt = read_hex4(reader);
                match (high_opt) {
                    none { return StringParse.error(make_error("bad unicode escape", reader.pos)); }
                    some(high) {
                        var cp = high;
                        if (high >= 0xd800 && high <= 0xdbff) {
                            if (reader.pos + 6 > len(reader.data) || reader.data[reader.pos] != '\\' || reader.data[reader.pos + 1] != 'u') {
                                return StringParse.error(make_error("missing low surrogate", reader.pos));
                            }
                            reader.pos += 2;
                            var low_opt = read_hex4(reader);
                            match (low_opt) {
                                none { return StringParse.error(make_error("bad low surrogate", reader.pos)); }
                                some(low) {
                                    if (low < 0xdc00 || low > 0xdfff) {
                                        return StringParse.error(make_error("invalid low surrogate", reader.pos - 4));
                                    }
                                    cp = 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);
                                }
                            }
                        } else if (high >= 0xdc00 && high <= 0xdfff) {
                            return StringParse.error(make_error("unexpected low surrogate", reader.pos - 4));
                        }
                        utf8.append_codepoint(out, cp);
                    }
                }
            } else {
                return StringParse.error(make_error("unknown escape", reader.pos - 1));
            }
        }
    }
    return StringParse.error(make_error("unterminated string", reader.pos));
}

fn match_bytes_at(data: const []u8, pos: u64, text: const []u8) -> bool {
    if (pos + len(text) > len(data)) { return false; }
    for (var i: u64 = 0; i < len(text); i += 1) {
        if (data[pos + i] != text[i]) { return false; }
    }
    return true;
}

fn parse_number(reader: ref Reader) -> ?[]u8 {
    var start = reader.pos;
    if (reader.pos < len(reader.data) && reader.data[reader.pos] == '-') { reader.pos += 1; }
    if (reader.pos >= len(reader.data)) { reader.pos = start; return none; }
    if (reader.data[reader.pos] == '0') {
        reader.pos += 1;
    } else {
        if (reader.data[reader.pos] < '1' || reader.data[reader.pos] > '9') { reader.pos = start; return none; }
        while (reader.pos < len(reader.data) && is_digit(reader.data[reader.pos])) { reader.pos += 1; }
    }
    if (reader.pos < len(reader.data) && reader.data[reader.pos] == '.') {
        reader.pos += 1;
        if (reader.pos >= len(reader.data) || !is_digit(reader.data[reader.pos])) { reader.pos = start; return none; }
        while (reader.pos < len(reader.data) && is_digit(reader.data[reader.pos])) { reader.pos += 1; }
    }
    if (reader.pos < len(reader.data) && (reader.data[reader.pos] == 'e' || reader.data[reader.pos] == 'E')) {
        reader.pos += 1;
        if (reader.pos < len(reader.data) && (reader.data[reader.pos] == '+' || reader.data[reader.pos] == '-')) { reader.pos += 1; }
        if (reader.pos >= len(reader.data) || !is_digit(reader.data[reader.pos])) { reader.pos = start; return none; }
        while (reader.pos < len(reader.data) && is_digit(reader.data[reader.pos])) { reader.pos += 1; }
    }
    return some(bytes.slice(reader.data, start, reader.pos));
}

fn parse_value(reader: ref Reader) -> Parse {
    skip_ws(reader);
    if (reader.pos >= len(reader.data)) { return Parse.error(make_error("expected value", reader.pos)); }
    var ch = reader.data[reader.pos];
    if (ch == '"') {
        var string_result = parse_string(reader);
        match (string_result) {
            StringParse.error(err) { return Parse.error(err); }
            StringParse.ok(value) { return Parse.ok(Json.string(value)); }
        }
    }
    if (ch == '{') {
        reader.pos += 1;
        skip_ws(reader);
        var members: []Member = [];
        if (reader.pos < len(reader.data) && reader.data[reader.pos] == '}') {
            reader.pos += 1;
            return Parse.ok(Json.object(members));
        }
        while (true) {
            var key_result = parse_string(reader);
            var key: []u8 = [];
            match (key_result) {
                StringParse.error(err) { return Parse.error(err); }
                StringParse.ok(value) { key = value; }
            }
            skip_ws(reader);
            if (reader.pos >= len(reader.data) || reader.data[reader.pos] != ':') {
                return Parse.error(make_error("expected :", reader.pos));
            }
            reader.pos += 1;
            var value_result = parse_value(reader);
            var member_value = Json.null;
            match (value_result) {
                Parse.error(err) { return Parse.error(err); }
                Parse.ok(value) { member_value = value; }
            }
            push(members, Member { key: key, value: member_value });
            skip_ws(reader);
            if (reader.pos >= len(reader.data)) { return Parse.error(make_error("unterminated object", reader.pos)); }
            if (reader.data[reader.pos] == '}') {
                reader.pos += 1;
                return Parse.ok(Json.object(members));
            }
            if (reader.data[reader.pos] != ',') { return Parse.error(make_error("expected , or }", reader.pos)); }
            reader.pos += 1;
            skip_ws(reader);
        }
    }
    if (ch == '[') {
        reader.pos += 1;
        skip_ws(reader);
        var values: []Json = [];
        if (reader.pos < len(reader.data) && reader.data[reader.pos] == ']') {
            reader.pos += 1;
            return Parse.ok(Json.array(values));
        }
        while (true) {
            var value_result = parse_value(reader);
            match (value_result) {
                Parse.error(err) { return Parse.error(err); }
                Parse.ok(value) { push(values, value); }
            }
            skip_ws(reader);
            if (reader.pos >= len(reader.data)) { return Parse.error(make_error("unterminated array", reader.pos)); }
            if (reader.data[reader.pos] == ']') {
                reader.pos += 1;
                return Parse.ok(Json.array(values));
            }
            if (reader.data[reader.pos] != ',') { return Parse.error(make_error("expected , or ]", reader.pos)); }
            reader.pos += 1;
            skip_ws(reader);
        }
    }
    if (match_bytes_at(reader.data, reader.pos, "true")) { reader.pos += 4; return Parse.ok(Json.boolean(true)); }
    if (match_bytes_at(reader.data, reader.pos, "false")) { reader.pos += 5; return Parse.ok(Json.boolean(false)); }
    if (match_bytes_at(reader.data, reader.pos, "null")) { reader.pos += 4; return Parse.ok(Json.null); }
    var number_result = parse_number(reader);
    match (number_result) {
        none { return Parse.error(make_error("invalid value", reader.pos)); }
        some(raw) { return Parse.ok(Json.number(raw)); }
    }
}

pub fn parse(src: const []u8) -> Parse {
    var reader = new Reader { data: src, pos: 0 };
    var result = parse_value(reader);
    match (result) {
        Parse.error(err) { return Parse.error(err); }
        Parse.ok(value) {
            skip_ws(reader);
            if (reader.pos != len(src)) { return Parse.error(make_error("trailing data", reader.pos)); }
            return Parse.ok(value);
        }
    }
}

fn hex_digit(value: u8) -> u8 {
    if (value < 10) { return '0' + value; }
    return 'a' + (value - 10);
}

fn write_string(out: []u8, value: const []u8) {
    push(out, '"');
    for (ch in value) {
        if (ch == '"' || ch == '\\') {
            push(out, '\\'); push(out, ch);
        } else if (ch == '\n') { bytes.append(out, "\\n"); }
        else if (ch == '\r') { bytes.append(out, "\\r"); }
        else if (ch == '\t') { bytes.append(out, "\\t"); }
        else if (ch < 0x20) {
            bytes.append(out, "\\u00");
            push(out, hex_digit(ch >> 4));
            push(out, hex_digit(ch & 0x0f));
        } else { push(out, ch); }
    }
    push(out, '"');
}

fn write_value(out: []u8, value: Json) {
    match (value) {
        Json.null { bytes.append(out, "null"); }
        Json.boolean(flag) { if (flag) { bytes.append(out, "true"); } else { bytes.append(out, "false"); } }
        Json.number(raw) { bytes.append(out, raw); }
        Json.string(text) { write_string(out, text); }
        Json.array(values) {
            push(out, '[');
            for (var i: u64 = 0; i < len(values); i += 1) {
                if (i != 0) { push(out, ','); }
                write_value(out, values[i]);
            }
            push(out, ']');
        }
        Json.object(members) {
            push(out, '{');
            for (var i: u64 = 0; i < len(members); i += 1) {
                if (i != 0) { push(out, ','); }
                write_string(out, members[i].key);
                push(out, ':');
                write_value(out, members[i].value);
            }
            push(out, '}');
        }
    }
}

pub fn stringify(value: Json) -> []u8 {
    var out: []u8 = [];
    write_value(out, value);
    return out;
}

pub fn object() -> Json { return Json.object([]); }
pub fn array() -> Json { return Json.array([]); }
pub fn u64_value(value: u64) -> Json { return Json.number(strconv.format_u64(value)); }
pub fn i64_value(value: i64) -> Json { return Json.number(strconv.format_i64(value)); }

pub fn put(object_value: Json, key: const []u8, value: Json) {
    match (object_value) {
        Json.object(members) {
            for (var i: u64 = 0; i < len(members); i += 1) {
                if (bytes.equal(members[i].key, key)) {
                    members[i].value = value;
                    return;
                }
            }
            push(members, Member { key: bytes.clone(key), value: value });
        }
        _ { trap; }
    }
}

pub fn append(array_value: Json, value: Json) {
    match (array_value) {
        Json.array(values) { push(values, value); }
        _ { trap; }
    }
}

pub fn get(object_value: Json, key: const []u8) -> ?Json {
    match (object_value) {
        Json.object(members) {
            for (member in members) {
                if (bytes.equal(member.key, key)) { return some(member.value); }
            }
            return none;
        }
        _ { return none; }
    }
}

pub fn as_string(value: Json) -> ?[]u8 {
    match (value) {
        Json.string(text) { return some(text); }
        _ { return none; }
    }
}

pub fn as_u64(value: Json) -> ?u64 {
    match (value) {
        Json.number(raw) { return strconv.parse_u64(raw); }
        _ { return none; }
    }
}

pub fn as_i64(value: Json) -> ?i64 {
    match (value) {
        Json.number(raw) { return strconv.parse_i64(raw); }
        _ { return none; }
    }
}

pub fn as_array(value: Json) -> ?[]Json {
    match (value) {
        Json.array(values) { return some(values); }
        _ { return none; }
    }
}

pub fn as_object(value: Json) -> ?[]Member {
    match (value) {
        Json.object(members) { return some(members); }
        _ { return none; }
    }
}

pub fn get_string(object_value: Json, key: const []u8) -> ?[]u8 {
    var value_opt = get(object_value, key);
    match (value_opt) { none { return none; } some(value) { return as_string(value); } }
}

pub fn get_u64(object_value: Json, key: const []u8) -> ?u64 {
    var value_opt = get(object_value, key);
    match (value_opt) { none { return none; } some(value) { return as_u64(value); } }
}

pub fn get_i64(object_value: Json, key: const []u8) -> ?i64 {
    var value_opt = get(object_value, key);
    match (value_opt) { none { return none; } some(value) { return as_i64(value); } }
}
