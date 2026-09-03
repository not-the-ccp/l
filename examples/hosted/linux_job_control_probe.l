import linux.fd as fd;
import linux.process as process;
import linux.process.child as children;
import linux.process.group as groups;
import linux.process.wait as wait;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn signal_ok(result: ?i64) {
    match (result) {
        none {}
        some(_) { trap; }
    }
}

fn child_or_trap(result: process.SpawnResult) -> process.Child {
    match (process.spawn_child(result)) {
        some(child) { return child; }
        none { trap; }
    }
}

fn require_only_stop(event: wait.Event, expected: i64) {
    match (wait.stop_signal(event)) {
        some(number) { require(number == expected); }
        none { trap; }
    }
    require(wait.exit_code(event) is none);
    require(wait.term_signal(event) is none);
    require(!wait.continued(event));
}

fn require_only_continue(event: wait.Event) {
    require(wait.stop_signal(event) is none);
    require(wait.exit_code(event) is none);
    require(wait.term_signal(event) is none);
    require(wait.continued(event));
}

fn require_only_term(event: wait.Event, expected: i64) {
    match (wait.term_signal(event)) {
        some(number) { require(number == expected); }
        none { trap; }
    }
    require(wait.stop_signal(event) is none);
    require(wait.exit_code(event) is none);
    require(!wait.continued(event));
}

fn main() -> i64 {
    var input = fd.stdin();
    var output = fd.stdout();
    var error = fd.stderr();

    var current = groups.current();
    require(groups.same(current, current));

    var argv = ["sleep", "30"];
    var child = child_or_trap(process.spawn_exact(
        "/usr/bin/sleep", argv, input, output, error, none
    ));
    require(children.same(child, child));
    var job = process.group(child);
    require(!groups.same(current, job));

    match (wait.poll_group(job)) {
        none {}
        some(_) { trap; }
    }

    var stop = process.sigstop();
    signal_ok(process.send_group(job, stop));
    var stopped = wait.group(job);
    require_only_stop(stopped, stop);
    var event_child = wait.event_child(stopped);
    require(children.same(event_child, child));
    require(groups.same(process.group(event_child), job));

    signal_ok(process.send_group(job, process.sigcont()));
    var continued = wait.group(job);
    require_only_continue(continued);
    require(children.same(wait.event_child(continued), child));

    var term = process.sigterm();
    signal_ok(process.send_group(job, term));
    var terminated = wait.group(job);
    require_only_term(terminated, term);
    require(children.same(wait.event_child(terminated), child));

    fd.close(input);
    fd.close(output);
    fd.close(error);
    return 0;
}
