#!/usr/bin/perl
# jarvis-lock.pl — the lease behind `jarvis lock` and `jarvis resources`. bin/jarvis
# resolves the class and calls this; nothing else should.
#
#   jarvis-lock.pl run <class> <host|checkout> <capacity> <root> <wait sec> <reuse 0|1> <command…>
#   jarvis-lock.pl resources [--json]
#
# A class has <capacity> slots, one file each, in $JARVIS_LOCK_DIR (~/.jarvis/locks):
# <key>.slot<N>, where key = <class> (host scope: the whole machine) or
# <class>@<12 hex of sha1(physical checkout root)> (checkout scope; <key>.where names
# the root). Holding a slot is holding a kernel flock on its file, nothing else. The
# kernel drops a flock when the last descriptor on it closes, SIGKILL included, so a
# lease can't go stale: there is nothing to reclaim and no PID to verify.
#
# The command inherits the slot's descriptor, and so does everything it starts, so the
# lease lasts as long as any process of the run. If this wrapper is SIGKILLed, the
# command and its children keep the lease until the last of them exits. That is on
# purpose: they are still using the resource. Kill the process group to free it.
#
# Waiters queue FIFO. Each holds a flock on its own ticket, <key>.q/<epoch-ns>.<pid>,
# for as long as it waits, and tries the slots only when fewer than <capacity> live
# tickets are ahead of it. A ticket that can be locked belongs to a waiter that died;
# whoever finds it unlinks it, so the queue cleans itself.
#
# The holder record written into a slot (pid, start, command, terminal, session) is
# for messages and `jarvis resources` only. Whether a slot is held is always the flock;
# a record on a slot that can be locked is stale and shown free.
#
# --reuse: a pass (exit 0) is stored as <key>.results/<sha1 of class, tree, cwd, argv,
# $JARVIS_REUSE_ENV values>, the tree being `git write-tree` of a throwaway index (the
# real index plus `git add -A`, so untracked files count and ignored ones don't). A
# pass younger than $JARVIS_REUSE_MAX_AGE on the same key is reported, not re-run.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock F_GETFD F_SETFD FD_CLOEXEC);
use POSIX ();
use Time::HiRes ();
use Digest::SHA qw(sha1_hex);
use Cwd qw(abs_path);
use File::Spec;
use File::Copy qw(copy);
use File::Path qw(make_path);

my $DIR = $ENV{JARVIS_LOCK_DIR} || "$ENV{HOME}/.jarvis/locks";
my $POLL = $ENV{JARVIS_LOCK_POLL} // 1;
$POLL = 1 unless $POLL =~ /^\d*\.?\d+$/ && $POLL > 0;
my $MAX_AGE = $ENV{JARVIS_REUSE_MAX_AGE} // 7200;
$MAX_AGE = 7200 unless $MAX_AGE =~ /^\d+$/;
my $NOTE = 60;    # seconds between "waiting" lines

sub fail { print STDERR "jarvis lock: $_[0]\n"; exit 2 }

sub ago {
  my $s = int(shift);
  $s = 0 if $s < 0;
  return "${s}s" if $s < 60;
  return sprintf('%dm%02ds', $s / 60, $s % 60) if $s < 3600;
  return sprintf('%dh%02dm', $s / 3600, ($s % 3600) / 60);
}

sub shown { # argv as a shell would read it back
  join ' ', map { m{^[A-Za-z0-9_./:=@%+,-]+$} ? $_ : do { (my $q = $_) =~ s/'/'\\''/g; "'$q'" } } @_;
}

sub read_rec {
  my %r;
  open(my $fh, '<', $_[0]) or return \%r;
  while (<$fh>) { chomp; $r{$1} = $2 if /^(\w+): ?(.*)$/ }
  close $fh;
  \%r;
}

sub rec_text {
  my $r = shift;
  join '', map { my $v = $r->{$_} // ''; $v =~ s/\n/ /g; "$_: $v\n" } qw(pid start cmd cwd root term session wrapper);
}

sub write_file { # atomically, so a reader never sees half of it
  my ($path, $text) = @_;
  my $tmp = "$path.tmp.$$";
  open(my $fh, '>', $tmp) or return;
  print $fh $text;
  close $fh;
  rename $tmp, $path or unlink $tmp;
}

sub short_term { my $t = shift // ''; length $t ? substr($t, 0, 8) : '' }

sub holder { # "pid 123 (term 1a2b3c4d, 2m10s: npm run test:docker)"
  my $r = shift;
  return unless $r->{pid};
  my @p;
  push @p, 'term ' . short_term($r->{term}) if length($r->{term} // '');
  my $age = ($r->{start} // '') =~ /^\d+$/ ? ago(time - $r->{start}) : '?';
  push @p, "$age: " . ($r->{cmd} // '?');
  "pid $r->{pid} (" . join(', ', @p) . ')';
}

sub key_of { # (key, checkout root or undef)
  my ($class, $scope, $root) = @_;
  return ($class, undef) if $scope eq 'host';
  my $r = abs_path($root) // $root;
  ("$class\@" . substr(sha1_hex($r), 0, 12), $r);
}

sub tickets { # this key's queue, oldest first
  my $q = shift;
  opendir(my $d, $q) or return ();
  my @t = sort grep { /^\d{19}\.\d+$/ } readdir $d;
  closedir $d;
  @t;
}

sub live_tickets { # $prune: unlink the tickets of waiters that died
  my ($q, $mine, $prune) = @_;
  my @live;
  for my $t (tickets($q)) {
    next if defined $mine && $t eq $mine;
    sysopen(my $fh, "$q/$t", O_RDONLY) or next;
    if (flock($fh, LOCK_EX | LOCK_NB)) {
      unlink "$q/$t" if $prune;
      close $fh;
      next;
    }
    close $fh;
    push @live, $t;
  }
  @live;
}

sub holders {
  my ($key, $cap) = @_;
  grep { defined } map { holder(read_rec("$DIR/$key.slot$_")) } 0 .. $cap - 1;
}

sub run_here { # exec the command in the caller's directory, as given
  my ($caller, @argv) = @_;
  chdir $caller or fail "can't enter $caller: $!";
  $ENV{PWD} = $caller;
  delete $ENV{JARVIS_CALLER_PWD};
  { exec { $argv[0] } @argv }
  print STDERR "jarvis lock: can't run $argv[0]: $!\n";
  POSIX::_exit(127);
}

# ---------------------------------------------------------------- --reuse

sub git_out {
  my $pid = open(my $p, '-|');
  return unless defined $pid;
  if (!$pid) {
    open STDIN, '<', File::Spec->devnull;
    open STDERR, '>', File::Spec->devnull;
    { exec 'git', @_ }
    POSIX::_exit(127);
  }
  local $/;
  my $out = <$p>;
  close $p;
  return if $?;
  $out //= '';
  $out =~ s/\n+\z//;
  $out;
}

sub tree_of { # the working tree as git would commit it with everything added; the real index untouched
  my $root = shift;
  my $idx = git_out('-C', $root, 'rev-parse', '--git-path', 'index') // return;
  $idx = File::Spec->rel2abs($idx, $root);
  my $tmp = "$DIR/.index.$$";
  unlink $tmp;
  copy($idx, $tmp) or return if -f $idx;
  local $ENV{GIT_INDEX_FILE} = $tmp;
  my $tree;
  $tree = git_out('-C', $root, 'write-tree') if defined git_out('-C', $root, 'add', '-A');
  unlink $tmp, "$tmp.lock";
  $tree;
}

sub result_key {
  my ($class, $root, $caller, @argv) = @_;
  my $tree = tree_of($root) // return;
  my $rel = File::Spec->abs2rel(abs_path($caller) // $caller, abs_path($root) // $root);
  my @env = map { defined $ENV{$_} ? "$_=$ENV{$_}" : $_ } split ' ', ($ENV{JARVIS_REUSE_ENV} // '');
  sha1_hex(join "\0", 'jarvis-reuse-1', $class, $tree, $rel, scalar(@argv), @argv, @env);
}

sub passed { # report a recent pass of exactly this run; true if there is one
  my ($class, $key, $h) = @_;
  my $f = "$DIR/$key.results/$h";
  my @st = stat $f or return 0;
  my $age = time - $st[9];
  return 0 if $age >= $MAX_AGE;
  my $r = read_rec($f);
  my @who;
  push @who, 'term ' . short_term($r->{term}) if length($r->{term} // '');
  push @who, 'session ' . short_term($r->{session}) if length($r->{session} // '');
  push @who, "pid $r->{pid}" if !@who && $r->{pid};
  print STDERR "jarvis lock $class: passed at " . POSIX::strftime('%H:%M', localtime $st[9]) . ' (' . ago($age) . ' ago'
    . (@who ? ', ' . join(', ', @who) : '') . ") on this exact tree, command and directory — not re-running."
    . " To run it anyway, run it without --reuse.\n";
  1;
}

sub record_pass {
  my ($key, $h, $rec) = @_;
  my $d = "$DIR/$key.results";
  mkdir $d, 0700;
  if (opendir(my $dh, $d)) { # passes too old to reuse are only clutter
    for (grep { !/^\./ } readdir $dh) { my @st = stat "$d/$_"; unlink "$d/$_" if @st && time - $st[9] >= $MAX_AGE }
    closedir $dh;
  }
  write_file("$d/$h", rec_text($rec));
}

# ---------------------------------------------------------------- run

sub cmd_run {
  my ($class, $scope, $cap, $root, $wait, $reuse, @argv) = @_;
  fail 'usage: jarvis-lock.pl run <class> <host|checkout> <capacity> <root> <wait> <reuse> <command…>'
    unless defined $reuse && @argv && $cap =~ /^[1-9]\d*$/ && $wait =~ /^\d+$/;
  my $caller = $ENV{JARVIS_CALLER_PWD} || $root;
  my ($key, $where) = key_of($class, $scope, $root);

  # A command already holding this key (a suite that calls a script that locks it
  # again) runs straight away: waiting on its own lease would never end.
  run_here($caller, @argv) if grep { $_ eq $key } split /:/, ($ENV{JARVIS_LOCKS_HELD} // '');

  -d $DIR or make_path($DIR, { mode => 0700 }) or -d $DIR or fail "can't create $DIR: $!";
  if (defined $where) {
    my $wf = "$DIR/$key.where";
    my $cur = '';
    if (open(my $fh, '<', $wf)) { local $/; $cur = <$fh> // ''; close $fh }
    write_file($wf, "$where\n") if $cur ne "$where\n";
  }

  my $h;
  if ($reuse) {
    $h = result_key($class, $root, $caller, @argv);
    print STDERR "jarvis lock $class: --reuse needs a git checkout; running it\n" unless defined $h;
    exit 0 if defined $h && passed($class, $key, $h);
  }

  # Take a ticket: locked under a temporary name first, so no one can see it unlocked
  # and take it for a dead waiter's.
  my $q = "$DIR/$key.q";
  mkdir $q, 0700;
  my ($s, $us) = Time::HiRes::gettimeofday();
  my $mine = sprintf('%010d%06d000.%d', $s, $us, $$);
  my $tmp = "$q/.new.$$";
  sysopen(my $tk, $tmp, O_RDWR | O_CREAT | O_TRUNC, 0600) or fail "can't queue in $q: $!";
  flock($tk, LOCK_EX) or fail "can't lock $tmp: $!";
  rename $tmp, "$q/$mine" or fail "can't queue in $q: $!";

  my $deadline = Time::HiRes::time() + $wait;
  my ($told, $slot);
  while (1) {
    my @ahead = grep { $_ lt $mine } live_tickets($q, $mine, 1);
    if (@ahead < $cap) {
      for my $i (0 .. $cap - 1) {
        sysopen(my $fh, "$DIR/$key.slot$i", O_RDWR | O_CREAT, 0600) or fail "can't open $DIR/$key.slot$i: $!";
        if (flock($fh, LOCK_EX | LOCK_NB)) { $slot = $fh; last }
        close $fh;
      }
    }
    last if $slot;
    my @h = holders($key, $cap);
    my $why = (@h ? 'held by ' . join(', ', @h) : 'held') . '; ' . scalar(@ahead) . ' ahead';
    if (Time::HiRes::time() >= $deadline) {
      unlink "$q/$mine";
      print STDERR "jarvis lock $class: gave up after ${wait}s — $why. Wait longer with --wait <sec> or JARVIS_LOCK_WAIT\n";
      exit 75;
    }
    if (!defined $told || time - $told >= $NOTE) {
      print STDERR "jarvis lock $class: waiting — $why\n";
      $told = time;
    }
    Time::HiRes::sleep($POLL);
  }
  unlink "$q/$mine";
  close $tk;

  if (defined $h) { # someone may have passed this exact run while we waited
    $h = result_key($class, $root, $caller, @argv);
    exit 0 if defined $h && passed($class, $key, $h);
  }

  my %rec = (start => time, cmd => shown(@argv), cwd => $caller, root => $where // '',
    term => $ENV{SUPERSET_TERMINAL_ID} || $ENV{TMUX_PANE} || $ENV{ULTRON_SESSION_ID} || '',
    session => $ENV{CLAUDE_CODE_SESSION_ID} // '', wrapper => $$);
  my $pid = fork;
  fail "can't fork: $!" unless defined $pid;
  if (!$pid) {
    my $fl = fcntl($slot, F_GETFD, 0) // 0;
    fcntl($slot, F_SETFD, $fl & ~FD_CLOEXEC); # the command and its children hold the lease
    $ENV{JARVIS_LOCKS_HELD} = join ':', grep { length } ($ENV{JARVIS_LOCKS_HELD} // ''), $key;
    run_here($caller, @argv);
  }
  $rec{pid} = $pid;
  truncate $slot, 0;
  sysseek $slot, 0, 0;
  syswrite $slot, rec_text(\%rec);

  # Forward stop signals to the command. A ^C in the terminal already reached it (same
  # foreground process group), so that one isn't sent twice.
  my $fg = -t STDIN && eval { POSIX::tcgetpgrp(0) == getpgrp() };
  for my $sig (qw(TERM HUP INT)) {
    $SIG{$sig} = sub { kill $sig, $pid unless $sig eq 'INT' && $fg };
  }
  my $r;
  do { $r = waitpid($pid, 0) } until $r == $pid || $r == -1;
  my $st = $?;
  my $code = $r != $pid ? 1 : ($st & 127) ? 128 + ($st & 127) : $st >> 8;
  record_pass($key, $h, \%rec) if defined $h && $code == 0;
  truncate $slot, 0;
  exit $code;
}

# ---------------------------------------------------------------- resources

sub cmd_resources {
  my $json = grep { $_ eq '--json' } @_;
  my (%keys, @entries);
  if (opendir(my $d, $DIR)) { @entries = readdir $d; closedir $d }
  for (@entries) { $keys{$1} = 1 if /^([a-z0-9_]+(?:\@[0-9a-f]{12})?)\.(?:slot\d+|q|results|where)$/ }
  my @out;
  for my $key (sort keys %keys) {
    (my $class = $key) =~ s/\@.*//;
    my $where = 'machine';
    if ($key =~ /\@/) {
      if (open(my $fh, '<', "$DIR/$key.where")) { $where = <$fh> // '?'; chomp $where; close $fh }
      $where = '?' if $where eq 'machine';
    }
    my @slots;
    for my $n (sort { $a <=> $b } map { /^\Q$key\E\.slot(\d+)$/ ? $1 : () } @entries) {
      my $f = "$DIR/$key.slot$n";
      sysopen(my $fh, $f, O_RDONLY) or next;
      my $held = flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1;
      close $fh;
      my $r = read_rec($f);
      my %s = (slot => $n + 0, held => $held ? JSON_true() : JSON_false());
      if ($held && $r->{pid}) {
        %s = (%s, pid => $r->{pid} + 0, term => $r->{term} // '', session => $r->{session} // '', cmd => $r->{cmd} // '',
          cwd => $r->{cwd} // '', age_sec => ($r->{start} // '') =~ /^\d+$/ ? time - $r->{start} : undef);
      }
      $s{stale} = JSON_true() if !$held && $r->{pid};
      push @slots, \%s;
    }
    my @q = live_tickets("$DIR/$key.q", undef, 0);
    my $oldest = @q ? time - substr($q[0], 0, 10) : undef;
    my $passes = 0;
    if (opendir(my $d, "$DIR/$key.results")) {
      for (grep { !/^\./ } readdir $d) { my @st = stat "$DIR/$key.results/$_"; $passes++ if @st && time - $st[9] < $MAX_AGE }
      closedir $d;
    }
    push @out, { key => $key, class => $class, where => $where, slots => \@slots,
      queue => { waiting => scalar(@q), oldest_sec => $oldest }, passes => $passes };
  }

  if ($json) {
    require JSON::PP;
    print JSON::PP->new->canonical->pretty->encode(\@out);
    return;
  }
  if (!@out) { print "no leases taken yet (lock dir: $DIR)\n"; return }
  for my $k (@out) {
    print "$k->{class} · $k->{where}\n";
    for my $s (@{ $k->{slots} }) {
      if (!$s->{held}) { print "  slot $s->{slot}  free" . ($s->{stale} ? '  (stale record of a run that ended)' : '') . "\n"; next }
      if (!$s->{pid}) { print "  slot $s->{slot}  held  (no record: left by a run that ended)\n"; next }
      my $cmd = $s->{cmd};
      $cmd = '...' . substr($cmd, -57) if length $cmd > 60; # the end says most: script, project, flags
      print "  slot $s->{slot}  held  pid $s->{pid}" . (length $s->{term} ? ' · term ' . short_term($s->{term}) : '')
        . ' · ' . (defined $s->{age_sec} ? ago($s->{age_sec}) : '?') . " · $cmd\n";
    }
    my $qn = $k->{queue}{waiting};
    print '  queue ' . ($qn ? "$qn waiting, oldest " . ago($k->{queue}{oldest_sec}) : 'empty')
      . ' · ' . $k->{passes} . ' stored pass' . ($k->{passes} == 1 ? '' : 'es') . "\n";
  }
}

sub JSON_true { require JSON::PP; JSON::PP::true() }
sub JSON_false { require JSON::PP; JSON::PP::false() }

# ---------------------------------------------------------------- main

my $op = shift @ARGV // '';
if ($op eq 'run') { cmd_run(@ARGV) }
elsif ($op eq 'resources') { cmd_resources(@ARGV) }
else { fail 'usage: jarvis-lock.pl run <class> <scope> <capacity> <root> <wait> <reuse> <command…> | resources [--json]' }
