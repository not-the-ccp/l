import bytes;
import executor;
import linux.process as process;
import linux.process.child as children;
import linux.process.wait as wait;
import linux.tty as tty;

pub enum MemberState {
    running,
    stopped(i64),
    exited(i64),
    signaled(i64),
}

pub struct Member {
    pub child: process.Child,
    pub state: MemberState,
}

pub enum JobState {
    running,
    stopped,
    done,
}

pub struct Job {
    pub id: u64,
    // The table owns a clone of the command, but consumers only receive a
    // read-only view. Job labels are metadata, not an editable command buffer.
    pub command: const []u8,
    pub group: process.Group,
    pub members: []Member,
    pub state: JobState,
    pub tty_mode: ?tty.Mode,
}

pub struct Table {
    pub jobs: []ref Job,
    pub next_id: u64,
}

pub enum WaitResult {
    done(i64),
    stopped(i64),
}

pub fn create() -> ref Table {
    return new Table { jobs: [], next_id: 1 };
}

fn refresh(job: ref Job) {
    var all_done = true;
    var all_quiescent = true;
    for (member in job.members) {
        match (member.state) {
            MemberState.running {
                all_done = false;
                all_quiescent = false;
            }
            MemberState.stopped(_) {
                all_done = false;
            }
            MemberState.exited(_) {}
            MemberState.signaled(_) {}
        }
    }

    if (all_done) {
        job.state = JobState.done;
    } else if (all_quiescent) {
        job.state = JobState.stopped;
    } else {
        job.state = JobState.running;
    }
}

fn event_state(event: wait.Event) -> MemberState {
    match (wait.exit_code(event)) {
        some(code) { return MemberState.exited(code); }
        none {}
    }
    match (wait.term_signal(event)) {
        some(number) { return MemberState.signaled(number); }
        none {}
    }
    match (wait.stop_signal(event)) {
        some(number) { return MemberState.stopped(number); }
        none {}
    }
    if (wait.continued(event)) {
        return MemberState.running;
    }
    trap;
}

fn apply_event(job: ref Job, event: wait.Event) {
    var child = wait.event_child(event);
    for (var i: u64 = 0; i < len(job.members); i += 1) {
        if (children.same(job.members[i].child, child)) {
            job.members[i].state = event_state(event);
            refresh(job);
            return;
        }
    }
    // Every process in the job pgrp is created by executor.launch, so an event
    // for an unknown child indicates a host/executor ownership bug.
    trap;
}

pub fn from_live(live: executor.LiveJob, command: const []u8) -> ?ref Job {
    match (live.group) {
        none { return none; }
        some(group) {
            var members: []Member = [];
            for (child in live.children) {
                push(members, Member { child: child, state: MemberState.running });
            }
            return some(new Job {
                id: 0,
                command: bytes.clone(command),
                group: group,
                members: members,
                state: JobState.running,
                tty_mode: none,
            });
        }
    }
}

fn stopped_signal(job: ref Job) -> i64 {
    // Prefer the final pipeline member when it stopped; otherwise any stopped
    // member supplies the conventional 128+signal foreground status.
    if (len(job.members) != 0) {
        match (job.members[len(job.members) - 1].state) {
            MemberState.stopped(number) { return number; }
            MemberState.running {}
            MemberState.exited(_) {}
            MemberState.signaled(_) {}
        }
    }
    for (member in job.members) {
        match (member.state) {
            MemberState.stopped(number) { return number; }
            MemberState.running {}
            MemberState.exited(_) {}
            MemberState.signaled(_) {}
        }
    }
    return process.sigtstp();
}

fn final_status(job: ref Job) -> i64 {
    if (len(job.members) == 0) { return 0; }
    var state = job.members[len(job.members) - 1].state;
    match (state) {
        MemberState.exited(code) { return code; }
        MemberState.signaled(number) { return 128 + number; }
        MemberState.stopped(number) { return 128 + number; }
        MemberState.running { trap; }
    }
}

// Wait until a foreground job is no longer runnable: every member has either
// terminated or stopped. A single stopped process in a pipeline is not enough
// to give the terminal back while siblings may still be executing.
pub fn wait_foreground(job: ref Job) -> WaitResult {
    refresh(job);
    while (job.state == JobState.running) {
        apply_event(job, wait.group(job.group));
    }
    if (job.state == JobState.done) {
        return WaitResult.done(final_status(job));
    }
    return WaitResult.stopped(stopped_signal(job));
}

pub fn poll(job: ref Job) {
    if (job.state == JobState.done) { return; }
    while (true) {
        match (wait.poll_group(job.group)) {
            none { return; }
            some(event) {
                apply_event(job, event);
                if (job.state == JobState.done) { return; }
            }
        }
    }
}

fn mark_stopped_running(job: ref Job) {
    for (var i: u64 = 0; i < len(job.members); i += 1) {
        match (job.members[i].state) {
            MemberState.stopped(_) {
                job.members[i].state = MemberState.running;
            }
            MemberState.running {}
            MemberState.exited(_) {}
            MemberState.signaled(_) {}
        }
    }
    refresh(job);
}

pub fn continue_job(job: ref Job) -> ?i64 {
    var result = process.send_group(job.group, process.sigcont());
    match (result) {
        some(number) { return some(number); }
        none {
            // SIGCONT applies to the whole process group. Update the model
            // immediately; later kernel CLD_CONTINUED events are idempotent.
            mark_stopped_running(job);
            return none;
        }
    }
}

pub fn save_tty_mode(job: ref Job, mode: tty.Mode) {
    job.tty_mode = some(mode);
}

pub fn store(table: ref Table, job: ref Job) -> u64 {
    if (job.id != 0) { return job.id; }
    job.id = table.next_id;
    table.next_id += 1;
    push(table.jobs, job);
    return job.id;
}

pub fn poll_all(table: ref Table) {
    for (job in table.jobs) {
        poll(job);
    }
}

pub fn find(table: ref Table, id: u64) -> ?ref Job {
    for (job in table.jobs) {
        if (job.id == id) { return some(job); }
    }
    return none;
}

pub fn latest_active(table: ref Table) -> ?ref Job {
    var i = len(table.jobs);
    while (i > 0) {
        i -= 1;
        var job = table.jobs[i];
        if (job.state != JobState.done) { return some(job); }
    }
    return none;
}

pub fn prune_done(table: ref Table) {
    var kept: []ref Job = [];
    for (job in table.jobs) {
        if (job.state != JobState.done) { push(kept, job); }
    }
    table.jobs = kept;
}

pub fn status(job: ref Job) -> JobState {
    return job.state;
}

pub fn exit_status(job: ref Job) -> i64 {
    return final_status(job);
}
