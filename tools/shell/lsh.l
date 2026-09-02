import bytes;
import proc;
import stdio;
import sys;
import syntax;

fn writeln(text: []u8) {
    stdio.write(text);
    stdio.write("\n");
}

fn usage() {
    writeln("usage: lsh-lab --self-test | --plan COMMAND | --run COMMAND");
}

fn plan(command_text: []u8) -> i64 {
    var result = syntax.parse(command_text);
    match (result) {
        syntax.ParseResult.error(message) {
            stdio.write("parse error: ");
            writeln(message);
            return 2;
        }
        syntax.ParseResult.ok(pipeline) {
            writeln(syntax.describe(pipeline));
            return 0;
        }
    }
}

fn run_direct(command_text: []u8) -> i64 {
    var result = syntax.parse(command_text);
    match (result) {
        syntax.ParseResult.error(message) {
            stdio.write("parse error: ");
            writeln(message);
            return 2;
        }
        syntax.ParseResult.ok(pipeline) {
            if (pipeline.background || len(pipeline.commands) != 1 || len(pipeline.commands[0].redirects) != 0) {
                writeln("execution lab currently supports one foreground command without redirection");
                return 2;
            }

            var child = proc.spawn(pipeline.commands[0].argv);
            while (true) {
                var chunk = proc.read(child, 65536);
                match (chunk) {
                    none {
                        break;
                    }
                    some(data) {
                        stdio.write(data);
                    }
                }
            }
            proc.close(child);
            return 0;
        }
    }
}

fn main() -> i64 {
    var args = sys.args();
    if (len(args) == 1 && bytes.equal(args[0], "--self-test")) {
        syntax.self_test();
        writeln("shell syntax self-test PASS");
        return 0;
    }
    if (len(args) == 2 && bytes.equal(args[0], "--plan")) {
        return plan(args[1]);
    }
    if (len(args) == 2 && bytes.equal(args[0], "--run")) {
        return run_direct(args[1]);
    }
    usage();
    return 2;
}
