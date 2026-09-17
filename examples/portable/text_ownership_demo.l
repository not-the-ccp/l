import bytes;
import collections;
import json;
import utf8;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn require_text(actual: const []u8, expected: const []u8) {
    require(bytes.equal(actual, expected));
}

fn hash_text(value: []u8) -> u64 {
    var h: u64 = 14695981039346656037;
    for (ch in value) {
        h ^= ch as u64;
        h *= 1099511628211;
    }
    return h;
}

fn equal_text(a: []u8, b: []u8) -> bool {
    return bytes.equal(a, b);
}

fn main() -> i64 {
    // const-in/owned-out: `clone` takes const, returns a fresh owned buffer.
    var greeting: const []u8 = "hello";
    var owned: []u8 = bytes.clone(greeting);
    push(owned, '!');
    require_text(greeting, "hello");
    require_text(owned, "hello!");
    require(utf8.valid(owned));

    // clone-on-store: `put` keeps `bytes.clone(key)`, so the caller keeps its buffer.
    var obj = json.object();
    var keybuf: []u8 = "name";
    json.put(obj, keybuf, json.Json.string("ada"));
    push(keybuf, '!');
    require_text(keybuf, "name!");
    match (json.get_string(obj, "name")) {
        none { trap; }
        some(name) { require_text(name, "ada"); }
    }
    match (json.get(obj, "name!")) {
        none { }
        some(_) { trap; }
    }

    // map-with-owned-keys: clone the key, insert it, never mutate it again.
    var counts: ref collections.Map[[]u8, u64] = collections.map_new(hash_text, equal_text);
    var raw: const []u8 = "key-one";
    var map_key: []u8 = bytes.clone(raw);
    require(collections.map_set(counts, map_key, 1));
    require(collections.map_len(counts) == 1);
    match (collections.map_get(counts, "key-one")) {
        none { trap; }
        some(value) { require(value == 1); }
    }

    return 0;
}
