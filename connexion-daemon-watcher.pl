#!/usr/bin/perl

use strict;
use warnings;

use File::Basename   qw( dirname );
use File::Path       qw( make_path );
use Getopt::Long     qw( GetOptions :config bundling );
use HTTP::Tiny       ();
use IO::Select       ();
use IO::Socket::INET ();
use JSON::PP         qw( encode_json decode_json );
use Pod::Usage       qw( pod2usage );
use Sys::Hostname    qw( hostname );
use Sys::Syslog      qw( :standard );

sub vsay;

my (
    $help,          $config_file,        $timeout,
    $verbose,       $restart,            $slack_url,
    $deep,          $alert_interval_min, $restart_min_interval_min,
    $restart_grace, $state_file,         $test_slack,
);

$timeout                  = 5;
$verbose                  = 0;
$alert_interval_min       = 30;
$restart_min_interval_min = 10;
$restart_grace            = 5;
$state_file               = '/var/lib/connexion-daemon-watcher/state.json';

GetOptions(
    'config|c=s'                   => \$config_file,
    'timeout|t=i'                  => \$timeout,
    'verbose|v+'                   => \$verbose,
    'restart|r'                    => \$restart,
    'slack|s=s'                    => \$slack_url,
    'deep|d'                       => \$deep,
    'alert-interval|ai|i=i'        => \$alert_interval_min,
    'restart-min-interval|rmi|m=i' => \$restart_min_interval_min,
    'restart-grace|rg|g=i'         => \$restart_grace,
    'state-file=s'                 => \$state_file,
    'test-slack'                   => \$test_slack,
    'help|?'                       => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

openlog( 'connexion-daemon-watcher', 'pid', 'daemon' );

if ($test_slack) {
    die "--test-slack requires --slack URL\n" unless $slack_url;
    my $hostname = hostname();
    my $payload  = {
        text => sprintf
":wave: Test message from connexion-daemon-watcher on `%s`\nIf you see this, Slack alerts are configured correctly.",
        $hostname,
    };
    vsay "test-slack: posting to webhook" if $verbose;
    my $ok = send_slack( $slack_url, $payload );
    if ($ok) {
        vsay "test-slack: webhook accepted the message" if $verbose;
        exit 0;
    }
    warn "test-slack: webhook post failed\n";
    exit 1;
}

($config_file) = glob('/etc/koha/sites/*/connexion.cnf') unless $config_file;
die "No connexion config file found\n" unless $config_file && -r $config_file;

my $params = parse_config($config_file);
my $port   = $params->{port} or die "No port defined in $config_file";
my $host   = q{127.0.0.1};

my $state = load_state($state_file);
my $now   = time;

if ( $verbose >= 2 ) {
    vsay "config: file=$config_file port=$port host=$host";
    vsay sprintf
'state: file=%s status=%s down_since=%s last_failure_alert_at=%s last_restart_at=%s',
      $state_file,
      $state->{status} // 'unknown',
      _age_str( $state->{down_since},            $now ),
      _age_str( $state->{last_failure_alert_at}, $now ),
      _age_str( $state->{last_restart_at},       $now );
}

my ( $ok, $error ) = is_connexion_up( $host, $port, $timeout, $deep );

if ($ok) {
    vsay "OK: connected to $host:$port" if $verbose;
    handle_recovery_if_needed( $state, $host, $port, 0 );
    save_state(
        $state_file,
        {
            status                => 'up',
            down_since            => undef,
            last_failure_alert_at => undef,
            last_restart_at       => $state->{last_restart_at},
        }
    );
    exit 0;
}

warn "FAIL: cannot connect to $host:$port: $error\n";

my $restart_attempt;
if ($restart) {
    $restart_attempt = maybe_restart( $state, $now );
    if ( $restart_attempt->{status} ne 'skipped' ) {
        $state->{last_restart_at} = $now;
        sleep($restart_grace) if $restart_grace > 0;
        my ( $ok2, $err2 ) = is_connexion_up( $host, $port, $timeout, $deep );
        $restart_attempt->{recheck} =
          { ok => ( $ok2 ? 1 : 0 ), error => $err2 };

        if ($ok2) {
            warn "OK: post-restart probe succeeded; service recovered\n";
            vsay "OK: connected to $host:$port (after restart)" if $verbose;

            if ( $slack_url && $state->{last_failure_alert_at} ) {
                send_slack(
                    $slack_url,
                    recovery_payload(
                        host        => $host,
                        port        => $port,
                        down_since  => $state->{down_since},
                        via_restart => 1,
                    )
                );
            }

            save_state(
                $state_file,
                {
                    status                => 'up',
                    down_since            => undef,
                    last_failure_alert_at => undef,
                    last_restart_at       => $state->{last_restart_at},
                }
            );
            exit 0;
        }
    }
}

if ( $slack_url
    && alert_throttle_passed( $state, $now, $alert_interval_min ) )
{
    if (
        send_slack(
            $slack_url,
            failure_payload(
                host            => $host,
                port            => $port,
                error           => $error,
                restart_attempt => $restart_attempt,
            )
        )
      )
    {
        $state->{last_failure_alert_at} = $now;
    }
}

$state->{status} = 'down';
$state->{down_since} //= $now;
save_state( $state_file, $state );
exit 1;

# Returns ( $ok, $error_message ).
# Default mode: TCP connect only.
# Deep mode: connect, send a single null byte, read response within $timeout.
# The daemon parses the null as an empty request, logs "Invalid request",
# and writes back "Bad request\0". Receiving any bytes proves the worker
# loop is alive — not just the listener — and catches the wedged-accept
# failure mode that a bare TCP probe misses.
sub is_connexion_up {
    my ( $host, $port, $timeout, $deep ) = @_;

    my $mode = $deep ? 'deep' : 'tcp-connect';
    vsay "probe: mode=$mode host=$host port=$port timeout=${timeout}s"
      if $verbose;

    my $t0   = time;
    my $sock = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    );
    if ( !$sock ) {
        my $err = $@ || 'unknown error';
        my $dt  = time - $t0;
        vsay "probe: connect failed in ${dt}s: $err" if $verbose;
        return ( 0, "connect: $err" );
    }
    vsay "probe: connected in " . ( time - $t0 ) . "s" if $verbose;

    if ( !$deep ) {
        close $sock;
        vsay "probe: tcp-connect mode — declaring up" if $verbose;
        return ( 1, undef );
    }

    vsay "probe: sending NULL byte" if $verbose;
    my $sent = syswrite( $sock, "\0" );
    if ( !defined $sent || $sent < 1 ) {
        my $err = "deep probe: write failed: $!";
        vsay "probe: $err" if $verbose;
        close $sock;
        return ( 0, $err );
    }

    vsay "probe: waiting up to ${timeout}s for response" if $verbose;
    my $t1     = time;
    my $select = IO::Select->new($sock);
    if ( !$select->can_read($timeout) ) {
        my $dt = time - $t1;
        vsay "probe: no readable data after ${dt}s" if $verbose;
        close $sock;
        return ( 0, "deep probe: no response within ${timeout}s" );
    }
    vsay "probe: server is readable after " . ( time - $t1 ) . "s"
      if $verbose;

    my $resp;
    my $bytes = sysread( $sock, $resp, 1024 );
    close $sock;

    if ( !defined $bytes ) {
        my $err = "deep probe: read error: $!";
        vsay "probe: $err" if $verbose;
        return ( 0, $err );
    }
    if ( $bytes == 0 ) {
        vsay "probe: server closed without sending bytes" if $verbose;
        return ( 0, "deep probe: server closed without response" );
    }

    if ($verbose) {
        ( my $snippet = $resp ) =~ s/\0/\\0/g;
        $snippet =~ s/[^\x20-\x7e\\]/?/g;
        vsay qq{probe: read $bytes byte(s): "$snippet"};
    }
    return ( 1, undef );
}

sub maybe_restart {
    my ( $state, $now ) = @_;
    my $min_seconds = $restart_min_interval_min * 60;

    if ( !$state->{last_restart_at} ) {
        vsay "restart-guard: no prior restart — proceeding" if $verbose >= 2;
        return restart_daemon();
    }

    my $ago = $now - $state->{last_restart_at};
    if ( $ago < $min_seconds ) {
        my $msg = sprintf
          'Skipped: last restart %ds ago, min interval is %ds',
          $ago, $min_seconds;
        warn "$msg\n";
        return { status => 'skipped', message => $msg };
    }
    vsay sprintf 'restart-guard: last restart %ds ago >= %ds — proceeding',
      $ago, $min_seconds
      if $verbose >= 2;
    return restart_daemon();
}

sub restart_daemon {
    my $init_script = '/etc/init.d/connexion-daemon';

    warn "Restarting connexion daemon via $init_script (stop + start)\n";

    vsay "restart: $init_script stop" if $verbose;
    my $stop_msg = _describe_rc( system( $init_script, 'stop' ) );
    vsay "stop: $stop_msg";

    vsay "restart: $init_script start" if $verbose;
    my $start_rc  = system( $init_script, 'start' );
    my $start_msg = _describe_rc($start_rc);
    vsay "start: $start_msg";

    my $combined = "stop: $stop_msg, start: $start_msg";
    if ( $start_rc == 0 ) {
        return { status => 'success', message => $combined };
    }
    return { status => 'failure', message => $combined };
}

sub _describe_rc {
    my ($rc) = @_;
    if ( $rc == -1 ) {
        return "exec failed: $!";
    }
    elsif ( $rc & 127 ) {
        return sprintf 'killed by signal %d', ( $rc & 127 );
    }
    elsif ( $rc == 0 ) {
        return 'succeeded';
    }
    else {
        return sprintf 'failed (exit %d)', ( $rc >> 8 );
    }
}

sub handle_recovery_if_needed {
    my ( $state, $host, $port, $via_restart ) = @_;
    return unless $slack_url;
    return unless ( $state->{status} // 'up' ) eq 'down';
    return unless $state->{last_failure_alert_at};

    send_slack(
        $slack_url,
        recovery_payload(
            host        => $host,
            port        => $port,
            down_since  => $state->{down_since},
            via_restart => $via_restart,
        )
    );
}

sub alert_throttle_passed {
    my ( $state, $now, $interval_min ) = @_;
    if ( !$state->{last_failure_alert_at} ) {
        vsay "throttle: no prior failure alert — passed" if $verbose >= 2;
        return 1;
    }
    my $age   = $now - $state->{last_failure_alert_at};
    my $needs = $interval_min * 60;
    my $ok    = $age >= $needs ? 1 : 0;
    vsay sprintf 'throttle: last alert %ds ago, interval %ds — %s',
      $age, $needs, $ok ? 'passed' : 'blocked'
      if $verbose >= 2;
    return $ok;
}

sub _age_str {
    my ( $epoch, $now ) = @_;
    return 'never' unless $epoch;
    return ( $now - $epoch ) . 's ago';
}

sub vsay {
    my $msg = join '', @_;
    print STDERR "$msg\n";
    syslog( 'info', '%s', $msg );
    return;
}

sub failure_payload {
    my (%args)   = @_;
    my $hostname = hostname();
    my $text     = sprintf
":rotating_light: *Connexion daemon down* on `%s`\nCannot connect to `%s:%d`: %s",
      $hostname, $args{host}, $args{port}, $args{error};

    if ( my $r = $args{restart_attempt} ) {
        if ( $r->{status} eq 'skipped' ) {
            $text .= "\n:no_entry_sign: Restart skipped: $r->{message}";
        }
        elsif ( $r->{status} eq 'success' ) {
            $text .= "\n:white_check_mark: Restart: $r->{message}";
        }
        else {
            $text .= "\n:x: Restart failed: $r->{message}";
        }
        if ( my $rc = $r->{recheck} ) {
            if ( $rc->{ok} ) {
                $text .=
"\n:arrows_counterclockwise: Post-restart probe: OK — service recovered";
            }
            else {
                $text .=
                  "\n:warning: Post-restart probe: still down ($rc->{error})";
            }
        }
    }
    return { text => $text };
}

sub recovery_payload {
    my (%args)   = @_;
    my $hostname = hostname();
    my $duration = '';
    if ( $args{down_since} ) {
        $duration = ' after ' . format_duration( time - $args{down_since} );
    }
    my $verb = $args{via_restart} ? 'recovered after restart' : 'recovered';
    return {
        text => sprintf
":white_check_mark: *Connexion daemon %s* on `%s`\n`%s:%d` is reachable again%s",
        $verb, $hostname, $args{host}, $args{port}, $duration,
    };
}

sub format_duration {
    my ($s) = @_;
    return "${s}s" if $s < 60;
    my $m = int( $s / 60 );
    return "${m}m" if $m < 60;
    my $h = int( $m / 60 );
    $m = $m % 60;
    return "${h}h${m}m";
}

sub send_slack {
    my ( $url, $payload ) = @_;
    if ( $verbose >= 2 ) {
        my ($url_host) = $url =~ m{://([^/]+)};
        vsay "slack: POST to " . ( $url_host // 'unknown' );
        vsay "slack: payload=" . encode_json($payload);
    }
    my $response = HTTP::Tiny->new( timeout => 10 )->post(
        $url,
        {
            headers => { 'Content-Type' => 'application/json' },
            content => encode_json($payload),
        }
    );
    if ( !$response->{success} ) {
        warn sprintf "Slack post failed: %s %s\n",
          $response->{status} // '???',
          $response->{reason} // '';
        return 0;
    }
    vsay sprintf 'slack: response %s %s',
      $response->{status} // '???', $response->{reason} // ''
      if $verbose >= 2;
    vsay "Slack alert sent" if $verbose;
    return 1;
}

sub load_state {
    my ($path) = @_;
    return {} unless -f $path;
    open my $fh, '<', $path or do {
        warn "Cannot read state file $path: $!\n";
        return {};
    };
    local $/;
    my $content = <$fh>;
    close $fh;
    return {} unless length $content;
    my $state = eval { decode_json($content) };
    if ($@) {
        warn "Cannot parse state file $path: $@\n";
        return {};
    }
    return $state;
}

sub save_state {
    my ( $path, $state ) = @_;
    my $dir = dirname($path);
    if ( !-d $dir ) {
        eval { make_path($dir) };
        if ( !-d $dir ) {
            warn "Cannot create state dir $dir: $@\n";
            return;
        }
    }
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or do {
        warn "Cannot write state tmp $tmp: $!\n";
        return;
    };
    print {$fh} encode_json($state);
    close $fh;
    rename $tmp, $path or do {
        warn "Cannot rename $tmp -> $path: $!\n";
        unlink $tmp;
        return;
    };
    vsay "state: saved $path: " . encode_json($state) if $verbose >= 2;
}

# Code duplicated from parse_config in the daemon script
sub parse_config {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    my %param;
    while (<$fh>) {
        chomp;
        s/\s*#.*//;
        s/^\s+//;
        s/\s+$//;
        next unless length;
        my ( $k, $v ) = /^(\S+?):\s*(.*)$/ or next;
        $param{$k} = $v;
    }
    close $fh;
    return \%param;
}

__END__

=head1 NAME

connexion-daemon-watcher.pl - Verify the Koha Connexion import daemon is healthy

=head1 SYNOPSIS

connexion-daemon-watcher.pl [options]

 Options:
   --config, -c PATH         Path to a specific connexion.cnf
                             (default: /etc/koha/sites/*/connexion.cnf)
   --timeout, -t SECS        Per-phase timeout in seconds (default: 5)
   --verbose, -v             Narrate the probe and OK line on success.
                             Repeatable: -vv also dumps state, throttle and
                             restart-guard math, save acks, Slack response.
                             Verbose lines go to STDERR and syslog
                             (facility daemon, ident connexion-daemon-watcher).
   --deep                    Use protocol-level liveness probe (send NULL,
                             expect a response). Catches wedged worker loop
                             that a bare TCP connect would not.
   --restart, -r             On failure, restart the daemon by running
                             /etc/init.d/connexion-daemon stop, then start
                             (the init script has no restart subcommand).
   --restart-min-interval N  Min minutes between restarts (default: 10)
   --restart-grace SECS      Sleep after restart before re-probing
                             (default: 5)
   --slack URL               POST JSON alerts to a Slack incoming-webhook URL
   --test-slack              POST a one-off test message to the Slack webhook
                             and exit. Requires --slack. Skips the probe.
   --alert-interval N        Min minutes between failure alerts for the same
                             ongoing incident (default: 30)
   --state-file PATH         State file for tracking incidents and restart
                             history (default:
                             /var/lib/connexion-daemon-watcher/state.json)
   --help, -?                This message

=head1 DESCRIPTION

Reads the Connexion import daemon config file, probes the configured
host:port, and exits non-zero if the daemon is unhealthy so cron mails the
output. Assumes a single Koha instance per server.

=head2 Probe modes

By default, the script does a plain TCP connect. With C<--deep>, it also
sends a single null byte and waits for a response. The daemon parses the
null as an empty request and replies C<Bad request\0>; receiving any bytes
proves the read/write worker loop is alive, not just the TCP listener.

=head2 Restart and restart guard

With C<--restart>, a failed probe triggers C</etc/init.d/connexion-daemon
restart>. The restart guard prevents thrashing: if the previous restart was
less than C<--restart-min-interval> minutes ago, the restart is skipped and
the failure escalates to Slack instead.

After a restart, the script waits C<--restart-grace> seconds and re-probes.
The result is reported in the Slack alert (or used to suppress alerting if
the service has recovered).

=head2 Slack alerting

With C<--slack URL>, the script posts to a Slack incoming webhook on:

=over 4

=item * Failure (throttled by C<--alert-interval>)

=item * Recovery, when a previously-alerted incident clears

=back

State is persisted to C<--state-file> across runs. Recovery alerts are
never throttled but are only sent if a failure alert was previously sent
for the current incident — silent recoveries from un-alerted blips do not
spam the channel.

=head1 EXIT STATUS

0 if the daemon is reachable (including after a successful restart-recover
cycle); 1 otherwise.

=cut
