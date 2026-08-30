import stdio;
import sys;

fn main() -> i64 {
    stdio.write("hello from L\n");

    var args = sys.args();
    for (arg in args) {
        stdio.write("arg: ");
        stdio.write(arg);
        stdio.write("\n");
    }

    return 0;
}
