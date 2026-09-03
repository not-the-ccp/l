import bytes;
import executor;
import job_control;
import linux.process as process;
import syntax;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn ready(input: const []u8) -> syntax.Pipeline {
    match (syntax.parse(input)) {
        syntax.ParseResult.ready(pipeline) { return pipeline; }
        syntax.ParseResult.incomplete(_) { trap; }
        syntax.ParseResult.error(_) { trap; }
    }
}

fn live_or_trap(pipeline: syntax.Pipeline) -> executor.LiveJob {
    match (executor.launch(pipeline)) {
        executor.LaunchResult.ok(live) { return live; }
        executor.LaunchResult.launch_failed(_) { trap; }
        executor.LaunchResult.invalid(_) { trap; }
    }
}

fn job_or_trap(live: executor.LiveJob, command: const []u8) -> ref job_control.Job {
    match (job_control.from_live(live, command)) {
        some(job) { return job; }
        none { trap; }
    }
}

fn signal_ok(result: ?i64) {
    match (result) {
        none {}
        some(_) { trap; }
    }
}

fn main() -> i64 {
    var command = "/usr/bin/sleep 30 | /usr/bin/sleep 30";
    var job = job_or_trap(live_or_trap(ready(command)), command);
    require(len(job.members) == 2);
    require(bytes.equal(job.command, command));
    require(job_control.status(job) == job_control.JobState.running);

    var stop = process.sigstop();
    signal_ok(process.send_group(job.group, stop));
    match (job_control.wait_foreground(job)) {
        job_control.WaitResult.stopped(number) { require(number == stop); }
        job_control.WaitResult.done(_) { trap; }
    }
    require(job_control.status(job) == job_control.JobState.stopped);

    signal_ok(job_control.continue_job(job));
    require(job_control.status(job) == job_control.JobState.running);

    var term = process.sigterm();
    signal_ok(process.send_group(job.group, term));
    match (job_control.wait_foreground(job)) {
        job_control.WaitResult.done(status) { require(status == 128 + term); }
        job_control.WaitResult.stopped(_) { trap; }
    }
    require(job_control.status(job) == job_control.JobState.done);
    require(job_control.exit_status(job) == 128 + term);

    var table = job_control.create();
    require(job_control.store(table, job) == 1);
    require(job.id == 1);
    job_control.poll_all(table);
    job_control.prune_done(table);
    require(len(table.jobs) == 0);
    return 0;
}
