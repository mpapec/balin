#!/bin/bash

if ! [[ -x "$(command -v perl)" && -x "$(command -v node)" ]]; then
  # echo 'Please check README.txt for installation instructions.' >&2
  echo -e '\nPlease check https://github.com/mpapec/balin for installation instructions.\n' >&2
  exit 1
fi
exec perl -x "$0" "$@"

#!perl
#!/usr/bin/env perl
use strict;
use warnings;
use Data::Dumper;
use FindBin;

STDOUT->autoflush;
# onle one instance of watcher
use Fcntl ':flock';
flock(DATA, LOCK_EX|LOCK_NB) or die "$0 already running!\n";


umask(0077);
my $cfg_file = "$ENV{HOME}/.balin";
my $CFG = do $cfg_file;


if (!$CFG) {
    # node module checks
    eval { bsv()->("check", $_) } or die "Install module: npm install $_\n" for qw(bsv datapay);

    unlink $cfg_file;
    $CFG = setup();
    print "Writing config file to $cfg_file (change default tx FEE there)\n";
    open my $fh, ">", $cfg_file or die "$! $cfg_file";
    print $fh serialize($CFG);
    close $fh or die $!
}
print "Remember to fund onchain logs sometimes: $CFG->{address}\n";

my $q= ask("Start watching logs", "y", [qw(y n)]);
if ($q eq "y") {
    print "going into background, ps -ef|grep $0 to find me..\n";
    daemonize();
    watcher();
}

#die Dumper my $pair = $bsv->("generate");
exit;


sub tail_file {
    my ($file, %arg) = @_;
    my $fh;
    my $line;

    return sub {
        if (!$fh) {
            my $ok = open $fh, "<", $file;
            $ok &&= seek $fh, 0,2;
            if (!$ok) { $fh = undef; die "$! $file" }
        }
        seek($fh, 0, 1) if !defined $line;
        $line = <$fh>;
        return $line;
    };
}

sub watcher {
#
    my $logfile = "$CFG->{data_dir}/balin.log";
    open my $log, ">>", $logfile or die "$! $logfile";
    $log->autoflush;
    print $log scalar(gmtime), " watcher started\n";

    my $bsv = bsv(
        # pay => { key => "Kxz4xNjY9h4GmFFPFkFb4EbhYVMHHLkvaj8HRVcEHfygLxnVr86P", fee => 140 }
        pay => { key => $CFG->{WIF}, fee => $CFG->{fee} }
    );
    my $tail = tail_file($CFG->{node_log});

    while (1) {
        my $arr = eval { [ $tail->() ] };
        if (!$arr) {
            print $log scalar(gmtime), " ", $@;
            sleep 10; next;
        }
        my ($line) = @$arr;
        if (!defined $line) { sleep 1; next; }

        # print $line;
        # not interested in other content
        $line =~ /UpdateTip/i or next;
        
        my %h = grep defined, $line =~ /(\S+) = (?:["'] (.+?) ["'] | (\S+) ) /xg;
        my ($ts) = $line =~ /^( \d{4} - \d\d - \d\d . \S+ )/x; # or next;
        $h{ts} = $ts;
        # print Dumper \%h;
        # print $log Dumper \%h;

        my $tx = eval {
            $bsv->("insert", [ "/dev/null", join ",", @h{qw( ts best )} ]);
        };
        my $now = gmtime;
        if ($tx) {
            chomp($tx);
            print $log "$now wrote $h{best} to $tx tx\n";
        }
        else {
            print $log "$now could NOT write $h{best} due $@\n";
        }

    }
}

sub setup {
    my %ret;
    my $log_file = "$ENV{HOME}/.bitcoin/bitcoind.log";
    $ret{node_log} = $log_file if -f $log_file;

    while (1) {
        $ret{node_log} = ask("Path to node log", $ret{node_log});
        open my $fh, "<", $ret{node_log} and last;
        print "Can't read from '$ret{node_log}' file!\n"
    }
    while (1) {
        $ret{data_dir} = ask("Path to my working data folder", $FindBin::Bin);
        open my $fh, ">", "$ret{data_dir}/writable" and last;
        print "Can't write to '$ret{data_dir}'!\n"
    }
    $ret{fee} = 330;
    @ret{qw(address WIF)} = split ' ', bsv()->("generate");
    print "\n\nSend at least \$0.10 to >> $ret{address} << before start\n\n";

    #my $q= ask("bude", "n", [qw(y n)]); die $q;
    return \%ret;
}

sub ask {
    my ($question, $default, $pick) = @_;

    my %look;
    if ($pick) {
        @look{ @$pick } = 1 .. @$pick;
        local $" = "/";
        my $opt = "? [@$pick]";
        if (defined $default) { $opt =~ s/( \b$default\b )/\U$1/x; }
        $question .= $opt;
    }
    else {
        my $opt = defined $default ? "? [$default]" : "? []";
        $question .= $opt;
    }
    while (1) {
        print $question, " ";
        my $in = $pick ? lc(<STDIN>) : <STDIN>;
        chomp($in);
        $in = $default if !length($in);
        next if $pick and !$look{$in};
 
        return $in if defined $in;
    }
}

sub bsv {
    my %arg = @_;

    return sub {
        my ($method, $opt) = @_;

        if ($method eq "insert") {
            my %p = ref($opt) eq "ARRAY" ? (%arg, data => $opt) : (%arg, %$opt);
            return node( q<require("datapay").send(JSON.parse(process.argv[1]), function(err,val)  { console.log(err||val); process.exit(!!err*1)  })>, to_json(\%p) );
        }
        if ($method eq "generate") {
            return node( q<b=require("bsv"); p=b.PrivateKey.fromRandom(); console.log(b.Address.fromPrivateKey(p).toString(), p.toWIF())> );
        }
        if ($method eq "check") {
            return node(qq<require("$opt")>);
        }
        die "unknown method $method";
    };
}


sub serialize {
    my ($r) = @_;

    use Data::Dumper;
    local $Data::Dumper::Useqq =1;
    # local $Data::Dumper::Pair = ":";
    local $Data::Dumper::Terse =1;
    # local $Data::Dumper::Indent =0;

    return Dumper $r;
}

sub to_json {
    my ($r) = @_;

    use Data::Dumper;
    local $Data::Dumper::Useqq =1;
    local $Data::Dumper::Pair = ":";
    local $Data::Dumper::Terse =1;
    local $Data::Dumper::Indent =0;

    return Dumper $r;
}

sub node {
    my @arg = @_ or die "nothing to do";
    my $param = join " ", map { qq('$_') } @arg;
    my $flag = $arg[0] =~ /console[.]log/ ? "-e" : "-p";

    my $cmd = qq(node $flag $param);
    my $ret = qx(cd $FindBin::Bin && $cmd 2>&1);
    # chomp($ret);

    my $err;
    if ($? == -1) {
        $err = "failed to execute: $!\n";
    }
    elsif ($? & 127) {
        $err = sprintf "child died with signal %d, %s coredump\n",
            ($? & 127),  ($? & 128) ? 'with' : 'without';
    }
    elsif ($? >> 8) {
        $err = sprintf "Error code %d when executing $cmd\n", $? >> 8;
    }
    if ($err) { warn $err; die $ret; }

    return $ret;
}

sub daemonize {
    exit if fork // die $!;
    POSIX::setsid() or die $!;
    exit if fork // die $!;

    # umask 0; chdir '/';
    #POSIX::close($_)
    #  for 0 .. (POSIX::sysconf(&POSIX::_SC_OPEN_MAX) ||1024);
    open STDIN , '<', '/dev/null';
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
}
sub fasync(&) {
  my ($worker) = @_;

  use POSIX ":sys_wait_h";
  my $pid = fork() // die "can't fork!";

  if (!$pid) {
    $worker->();
    exit(0);
  }

  return sub {
    my ($flags, $parm) = @_;
    $flags //= WNOHANG;
    return $pid if $flags eq "pid";
    return kill($parm //"TERM", $pid) if $flags eq "kill";
    return waitpid($pid, $flags);
  }
}

__DATA__

# Centos
yum install -y sudo
curl -sL https://rpm.nodesource.com/setup_10.x | sudo bash -
sudo yum install -y perl-Data-Dumper nodejs
npm install bsv datapay


# Ubuntu
apt-get update && apt-get install -y sudo curl
curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
sudo apt-get install -y nodejs perl
npm install bsv datapay



#print qx(node -e 'console.log(JSON.stringify(
#JSON.parse(process.argv[1]), null, 2
#))' '$j' 2>&1);
#print qx(node -e '"console.log(JSON.stringify(JSON.parse(process.argv[1]), null, 1))"' '$j' );

