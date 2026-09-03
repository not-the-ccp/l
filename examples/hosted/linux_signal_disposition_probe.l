import linux.process as process;
import linux.process.signal as signals;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn require_ok(result: ?i64) {
    match (result) {
        none {}
        some(_) { trap; }
    }
}

fn require_error(result: ?i64) {
    match (result) {
        none { trap; }
        some(number) { require(number != 0); }
    }
}

fn main() -> i64 {
    // Shells need to survive terminal-generated signals during foreground
    // handoff, while spawned children reset these dispositions before exec.
    require_ok(signals.ignore(process.sigint()));
    require_ok(signals.ignore(process.sigquit()));
    require_ok(signals.ignore(process.sigtstp()));

    require_ok(signals.default(process.sigint()));
    require_ok(signals.default(process.sigquit()));
    require_ok(signals.default(process.sigtstp()));

    // Keep error behavior aligned between Python's signal module and sigaction.
    require_error(signals.ignore(-1));
    return 0;
}
