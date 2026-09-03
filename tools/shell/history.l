import bytes;

pub struct Entry {
    pub command: []u8,
    pub cwd: []u8,
    pub status: i64,
    pub duration_ms: u64,
    pub sequence: u64,
}

pub struct History {
    pub entries: []Entry,
    // Navigation keeps the line that was being edited so Down/next can return
    // to it instead of destroying work when history browsing begins.
    pub draft: []u8,
    pub cursor: ?u64,
    pub next_sequence: u64,
}

pub fn create() -> ref History {
    return new History {
        entries: [],
        draft: [],
        cursor: none,
        next_sequence: 1,
    };
}

fn clone_entry(entry: Entry) -> Entry {
    return Entry {
        command: bytes.clone(entry.command),
        cwd: bytes.clone(entry.cwd),
        status: entry.status,
        duration_ms: entry.duration_ms,
        sequence: entry.sequence,
    };
}

pub fn record(history: ref History, command: const []u8, cwd: const []u8, status: i64, duration_ms: u64) {
    if (len(bytes.trim_ascii(command)) == 0) {
        return;
    }

    // Consecutive accidental repeats in the same context add little value to a
    // human history. The same command in another cwd remains distinct because
    // cwd is useful context for both recall and future ranking.
    if (len(history.entries) != 0) {
        var last = history.entries[len(history.entries) - 1];
        if (bytes.equal(last.command, command) && bytes.equal(last.cwd, cwd)) {
            last.status = status;
            last.duration_ms = duration_ms;
            history.entries[len(history.entries) - 1] = last;
            history.cursor = none;
            history.draft = [];
            return;
        }
    }

    push(history.entries, Entry {
        command: bytes.clone(command),
        cwd: bytes.clone(cwd),
        status: status,
        duration_ms: duration_ms,
        sequence: history.next_sequence,
    });
    history.next_sequence += 1;
    history.cursor = none;
    history.draft = [];
}

pub fn count(history: ref History) -> u64 {
    return len(history.entries);
}

pub fn cancel_navigation(history: ref History) {
    history.cursor = none;
    history.draft = [];
}

pub fn previous(history: ref History, current: const []u8) -> ?[]u8 {
    if (len(history.entries) == 0) {
        return none;
    }

    match (history.cursor) {
        none {
            history.draft = bytes.clone(current);
            var index = len(history.entries) - 1;
            history.cursor = some(index);
            return some(bytes.clone(history.entries[index].command));
        }
        some(index) {
            var next_index = index;
            if (next_index > 0) {
                next_index -= 1;
            }
            history.cursor = some(next_index);
            return some(bytes.clone(history.entries[next_index].command));
        }
    }
}

pub fn next(history: ref History) -> ?[]u8 {
    match (history.cursor) {
        none {
            return none;
        }
        some(index) {
            if (index + 1 < len(history.entries)) {
                var next_index = index + 1;
                history.cursor = some(next_index);
                return some(bytes.clone(history.entries[next_index].command));
            }
            var draft = bytes.clone(history.draft);
            history.cursor = none;
            history.draft = [];
            return some(draft);
        }
    }
}

fn contains(haystack: const []u8, needle: const []u8) -> bool {
    match (bytes.find(haystack, needle, 0)) {
        some(_) { return true; }
        none { return false; }
    }
}

// Search is contextual from day one: prefer the newest textual match from the
// current cwd, then fall back to the newest match anywhere. This is small and
// deterministic, but preserves the metadata needed for richer ranking later.
pub fn search(history: ref History, query: const []u8, cwd: const []u8) -> ?Entry {
    var fallback: ?u64 = none;
    var i = len(history.entries);
    while (i > 0) {
        i -= 1;
        var entry = history.entries[i];
        if (!contains(entry.command, query)) {
            continue;
        }
        if (bytes.equal(entry.cwd, cwd)) {
            return some(clone_entry(entry));
        }
        match (fallback) {
            none { fallback = some(i); }
            some(_) {}
        }
    }

    match (fallback) {
        some(index) {
            return some(clone_entry(history.entries[index]));
        }
        none {
            return none;
        }
    }
}
