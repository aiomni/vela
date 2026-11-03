import Foundation
import Darwin

/// The root process applies the setting only after it has detached. The parent
/// returns its PID after the setting succeeds, so a failed fork cannot strand
/// a changed setting. This pattern is adapted from Bulchimbeon (MIT).
enum LidWatchdogCommand {
    static func refreshLease(in directory: URL) throws {
        var now = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &now) == 0 else {
            throw POSIXError(.EIO)
        }
        let seconds = Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
        try Data("\(seconds)\n".utf8).write(to: directory.appendingPathComponent("lease"), options: .atomic)
    }

    static func make(pid: Int32, directory: URL, pmset: String = "/usr/bin/pmset",
                     leaseSeconds: Int = 30) -> String {
        // The production arguments are fixed paths, a numeric PID, and an app-generated UUID path.
        let program = "pipe(my $r, my $w) or die; my $child = fork(); die unless defined $child; "
            + "if ($child) { close $w; my $reply = <$r>; print $reply if defined $reply; "
            + "exit(defined($reply) && $reply =~ /^[1-9][0-9]*\\n$/ ? 0 : 1) } "
            + "close $r; POSIX::setsid() or exit 1; "
            + "open(STDIN, q(<), q(/dev/null)); open(STDOUT, q(>), q(/dev/null)); "
            + "open(STDERR, q(>), q(/dev/null)); "
            + "sub fresh { open(my $f, q(<), $ARGV[1].q(/lease)) or return 0; "
            + "my $stamp = <$f>; close $f; chomp $stamp if defined $stamp; "
            + "return 0 unless defined($stamp) && $stamp =~ /^[0-9]+(?:[.][0-9]+)?$/; "
            + "my $age = clock_gettime(CLOCK_MONOTONIC) - $stamp; "
            + "return $age >= -5 && $age <= $ARGV[2] } "
            + "my $birth = qx(/bin/ps -p $ARGV[0] -o lstart=); "
            + "unless ($birth && -d $ARGV[1] && fresh()) { print $w qq(0\\n); close $w; exit 1 } "
            + "my $ok = system(q(\(pmset)), q(-a), q(disablesleep), q(1)) == 0; "
            + "print $w ($ok ? qq($$\\n) : qq(0\\n)); close $w; exit 1 unless $ok; "
            + "while (kill(0, $ARGV[0]) && -d $ARGV[1] && fresh() && "
            + "(qx(/bin/ps -p $ARGV[0] -o lstart=) eq $birth)) { sleep 2 } "
            + "until (system(q(\(pmset)), q(-a), q(disablesleep), q(0)) == 0) { sleep 5 } "
            + "unlink $ARGV[1].q(/lease); rmdir $ARGV[1]; exit 0"
        return "/usr/bin/perl -MPOSIX -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e '\(program)' \(pid) \(directory.path) \(leaseSeconds) </dev/null"
    }
}
