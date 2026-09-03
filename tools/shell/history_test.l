import bytes;
import history;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn require_some(value: ?[]u8, expected: const []u8) {
    match (value) {
        some(actual) { require(bytes.equal(actual, expected)); }
        none { trap; }
    }
}

fn main() -> i64 {
    var h = history.create();
    history.record(h, "   ", "/a", 0, 1);
    require(history.count(h) == 0);

    history.record(h, "git status", "/a", 0, 10);
    history.record(h, "make test", "/b", 1, 200);
    history.record(h, "git status --short", "/a", 0, 4);
    require(history.count(h) == 3);

    // Consecutive duplicates in the same cwd update metadata instead of making
    // Up-arrow history noisy.
    history.record(h, "git status --short", "/a", 7, 9);
    require(history.count(h) == 3);
    match (history.search(h, "status --short", "/a")) {
        some(entry) {
            require(entry.status == 7);
            require(entry.duration_ms == 9);
        }
        none { trap; }
    }

    require_some(history.previous(h, "half typed"), "git status --short");
    require_some(history.previous(h, "ignored while browsing"), "make test");
    require_some(history.previous(h, "ignored"), "git status");
    require_some(history.previous(h, "ignored"), "git status");
    require_some(history.next(h), "make test");
    require_some(history.next(h), "git status --short");
    require_some(history.next(h), "half typed");
    match (history.next(h)) {
        none {}
        some(_) { trap; }
    }

    // Search prefers the newest matching command in the current cwd.
    match (history.search(h, "git", "/a")) {
        some(entry) {
            require(bytes.equal(entry.command, "git status --short"));
            require(bytes.equal(entry.cwd, "/a"));
            // Returned entries own clones of their byte arrays.
            push(entry.command, '!');
        }
        none { trap; }
    }
    match (history.search(h, "git", "/a")) {
        some(entry) { require(bytes.equal(entry.command, "git status --short")); }
        none { trap; }
    }

    // If the current cwd has no textual match, search falls back globally.
    match (history.search(h, "make", "/a")) {
        some(entry) {
            require(bytes.equal(entry.command, "make test"));
            require(bytes.equal(entry.cwd, "/b"));
        }
        none { trap; }
    }
    match (history.search(h, "definitely absent", "/a")) {
        none {}
        some(_) { trap; }
    }

    history.cancel_navigation(h);
    require_some(history.previous(h, "new draft"), "git status --short");
    require_some(history.next(h), "new draft");
    return 0;
}
