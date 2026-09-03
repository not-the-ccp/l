import bytes;
import linux.env as env;
import linux.fs as fs;

fn require(ok: bool) {
    if (!ok) {
        trap;
    }
}

fn require_ok(result: ?i64) {
    match (result) {
        none {}
        some(_) {
            trap;
        }
    }
}

fn require_error(result: ?i64) {
    match (result) {
        none {
            trap;
        }
        some(code) {
            require(code > 0);
        }
    }
}

fn get_cwd() -> []u8 {
    match (fs.cwd()) {
        some(path) {
            return path;
        }
        none {
            trap;
        }
    }
}

fn require_env(name: const []u8, expected: const []u8) {
    match (env.get(name)) {
        some(value) {
            require(bytes.equal(value, expected));
        }
        none {
            trap;
        }
    }
}

fn has_entry(expected: const []u8) -> bool {
    var entries = env.entries();
    for (entry in entries) {
        if (bytes.equal(entry, expected)) {
            return true;
        }
    }
    return false;
}

fn main() -> i64 {
    var original = get_cwd();

    require_ok(fs.chdir("/"));
    require(bytes.equal(get_cwd(), "/"));
    require_error(fs.chdir("/definitely/no/such/l-directory"));
    require(bytes.equal(get_cwd(), "/"));
    require_ok(fs.chdir(original));
    require(bytes.equal(get_cwd(), original));

    var name = "L_CONTEXT_PROBE_9D62A";
    require_ok(env.unset(name));
    match (env.get(name)) {
        none {}
        some(_) {
            trap;
        }
    }

    require_ok(env.set(name, "one", true));
    require_env(name, "one");
    require(has_entry("L_CONTEXT_PROBE_9D62A=one"));

    require_ok(env.set(name, "ignored", false));
    require_env(name, "one");
    require_ok(env.set(name, "two", true));
    require_env(name, "two");

    require_error(env.set("bad=name", "x", true));
    require_error(env.set("", "x", true));
    require_error(env.unset("bad=name"));

    require_ok(env.unset(name));
    match (env.get(name)) {
        none {}
        some(_) {
            trap;
        }
    }
    return 0;
}
