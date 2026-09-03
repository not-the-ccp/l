import bytes;
import prompt;

fn require(ok: bool) {
    if (!ok) { trap; }
}

fn main() -> i64 {
    var normal = prompt.build(some("/home/alice/src/l"), some("/home/alice"), 0, false);
    require(len(normal.segments) == 2);
    require(normal.segments[0].role == prompt.SegmentRole.cwd);
    require(normal.segments[1].role == prompt.SegmentRole.marker);
    require(bytes.equal(prompt.flatten(normal), "~/src/l › "));

    var failed = prompt.build(some("/home/alice/src/l"), some("/home/alice"), 7, false);
    require(len(failed.segments) == 3);
    require(failed.segments[1].role == prompt.SegmentRole.status);
    require(bytes.equal(prompt.flatten(failed), "~/src/l [7] › "));

    var home = prompt.build(some("/home/alice"), some("/home/alice"), 0, false);
    require(bytes.equal(prompt.flatten(home), "~ › "));

    // Prefixes that merely look like HOME are not abbreviated.
    var other_user = prompt.build(some("/home/alice2/project"), some("/home/alice"), 0, false);
    require(bytes.equal(prompt.flatten(other_user), "/home/alice2/project › "));

    var unknown = prompt.build(none, some("/home/alice"), 0, false);
    require(bytes.equal(prompt.flatten(unknown), "? › "));

    // Continuation prompts are deliberately quiet: the command itself already
    // provides the context and should remain visually dominant.
    var continuation = prompt.build(some("/ignored"), some("/ignored"), 99, true);
    require(len(continuation.segments) == 1);
    require(bytes.equal(prompt.flatten(continuation), "… "));
    return 0;
}
