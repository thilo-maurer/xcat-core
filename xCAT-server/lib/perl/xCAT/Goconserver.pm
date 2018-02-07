#!/usr/bin/perl
## IBM(c) 2107 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::Goconserver;

BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use warnings "all";

use HTTP::Request;
use HTTP::Headers;
use LWP;
use JSON;
use File::Path;
use IO::Socket::SSL qw( SSL_VERIFY_PEER );

my $go_api_port = 12429;
my $go_cons_port = 12430;

use constant CONSOLE_LOG_DIR => "/var/log/consoles";
unless (-d CONSOLE_LOG_DIR) {
    mkpath(CONSOLE_LOG_DIR, 0, 0755);
}

sub http_request {
    my ($method, $url, $data) = @_;
    my @user          = getpwuid($>);
    my $homedir       = $user[7];
    my $rsp;
    my $brower = LWP::UserAgent->new( ssl_opts => {
            SSL_key_file    => xCAT::Utils->getHomeDir() . "/.xcat/client-cred.pem",
            SSL_cert_file   => xCAT::Utils->getHomeDir() . "/.xcat/client-cred.pem",
            SSL_ca_file     => xCAT::Utils->getHomeDir() . "/.xcat/ca.pem",
            SSL_use_cert    => 1,
            verify_hostname => 0,
            SSL_verify_mode => SSL_VERIFY_PEER,  }, );
    my $header = HTTP::Headers->new('Content-Type' => 'application/json');
    #    $data = encode_json $data if defined($data);
    $data = JSON->new->encode($data) if defined($data);
    my $request = HTTP::Request->new( $method, $url, $header, $data );
    my $response = $brower->request($request);
    if (!$response->is_success()) {
        xCAT::MsgUtils->message("S", "Failed to send request to $url, rc=".$response->status_line());
        return undef;
    }
    my $content = $response->content();
    if ($content) {
        return decode_json $content;
    }
    return "";
}

sub delete_nodes {
    my ($api_url, $node_map, $delmode, $callback) = @_;
    my $url = "$api_url/bulk/nodes";
    my @a = ();
    my ($data, $rsp, $ret);
    $data->{nodes} = \@a;
    foreach my $node (keys %{$node_map}) {
        my $temp;
        $temp->{name} = $node;
        push @a, $temp;
    }
    $ret = 0;
    my $response = http_request("DELETE", $url, $data);
    if (!defined($response)) {
        $rsp->{data}->[0] = "Failed to send delete request.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    } elsif ($delmode) {
        while (my ($k, $v) = each %{$response}) {
            if ($v ne "Deleted") {
                $rsp->{data}->[0] = "$k: Failed to delete entry in goconserver: $v";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                $ret = 1;
            } else {
                $rsp->{data}->[0] = "$k: $v";
                xCAT::MsgUtils->message("I", $rsp, $callback);
            }
        }
    }
    return $ret;
}

sub create_nodes {
    my ($api_url, $node_map, $callback) = @_;
    my $url = "$api_url/bulk/nodes";
    my ($data, $rsp, @a, $ret);
    $data->{nodes} = \@a;
    while (my ($k, $v) = each %{$node_map}) {
        push @a, $v;
    }
    $ret = 0;
    my $response = http_request("POST", $url, $data);
    if (!defined($response)) {
        $rsp->{data}->[0] = "Failed to send create request.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    } elsif ($response) {
        while (my ($k, $v) = each %{$response}) {
            if ($v ne "Created") {
                $rsp->{data}->[0] = "$k: Failed to create console entry in goconserver: $v";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                $ret = 1;
            } else {
                $rsp->{data}->[0] = "$k: $v";
                xCAT::MsgUtils->message("I", $rsp, $::callback);
            }
        }
    }
    return $ret;
}

#-------------------------------------------------------------------------------

=head3  is_xcat_conf_ready
        Check if the goconserver configuration file was generated by xcat

    Returns:
        1 - ready
        0 - not ready
    Globals:
        none
    Example:
         my $ready=(xCAT::Goconserver::is_xcat_conf_ready()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub is_xcat_conf_ready {
    my $file;
    open $file, '<', "/etc/goconserver/server.conf";
    my $line = <$file>;
    close $file;
    if ($line =~ /#generated by xcat/) {
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  is_goconserver_running
        Check if the goconserver service is running

    Returns:
        1 - running
        0 - not running
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::is_goconserver_running()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub is_goconserver_running {
    my $cmd = "ps axf | grep -v grep | grep \/usr\/bin\/goconserver";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        return 0;
    }
    return 1;
}

#-------------------------------------------------------------------------------

=head3  is_conserver_running
        Check if the conserver service is running

    Returns:
        1 - running
        0 - not running
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::is_conserver_running()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub is_conserver_running {
    # On ubuntu system 'service conserver status' can not get the correct status of conserver,
    # use 'pidof conserver' like what we did in rcons.
    my $cmd = "pidof conserver";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC == 0) {
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  build_conf
        generate configuration file for goconserver

    Returns:
        none
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::build_conf()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub build_conf {
    my $config = "#generated by xcat ".xCAT::Utils->Version()."\n".
                 "global:\n".
                 "  host: 0.0.0.0\n".
                 "  ssl_key_file: /etc/xcat/cert/server-cred.pem\n".
                 "  ssl_cert_file: /etc/xcat/cert/server-cred.pem\n".
                 "  ssl_ca_cert_file: /etc/xcat/cert/ca.pem\n".
                 "  logfile: /var/log/goconserver/server.log             # the log for goconserver\n".
                 "api:\n".
                 "  port: $go_api_port                                   # the port for rest api\n".
                 "console:\n".
                 "  datadir: /var/lib/goconserver/                       # the data file to save the hosts\n".
                 "  port: $go_cons_port                                  # the port for console\n".
                 "  log_timestamp: true                                  # log the timestamp at the beginning of line\n".
                 "  reconnect_interval: 10                               # retry interval in second if console could not be connected\n".
                 "  logger:                                              # multiple logger targets could be specified\n".
                 "    file:                                              # file logger, valid fields: name,logdir. Accept array in yaml format\n".
                 "       - name: default                                 # the identity name customized by user\n".
                 "         logdir: ".CONSOLE_LOG_DIR."                   # default log directory of xcat\n".
                 "    #  - name: goconserver                             \n".
                 "    #    logdir: /var/log/goconserver/nodes            \n".
                 "  # tcp:                                               # valied fields: name, host, port, timeout, ssl_key_file, ssl_cert_file, ssl_ca_cert_file, ssl_insecure\n".
                 "     # - name: logstash                                \n".
                 "     #   host: 127.0.0.1                               \n".
                 "     #   port: 9653                                    \n".
                 "     #   timeout:  3                                   # default 3 second\n".
                 "     # - name: filebeat                                \n".
                 "     #   host: <hostname or ip>                        \n".
                 "     #   port: <port>                                  \n".
                 "  # udp:                                               # valid fiedls: name, host, port, timeout\n".
                 "     # - name: rsyslog                                 \n".
                 "     #   host:                                         \n".
                 "     #   port:                                         \n".
                 "     #   timeout:                                      # default 3 second\n";

    my $file;
    my $ret = open ($file, '>', '/etc/goconserver/server.conf');
    if ($ret == 0) {
        xCAT::MsgUtils->message("S", "Could not open file /etc/goconserver/server.conf");
        return 1;
    }
    print $file $config;
    close $file;
    return 0;
}

#-------------------------------------------------------------------------------

=head3  start_service
        start goconserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $running=(xCAT::Goconserver::start_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub start_service {
    my $cmd = "service goconserver start";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not start goconserver service.");
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  stop_service
        stop goconserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $ret=(xCAT::Goconserver::stop_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub stop_service {
    my $cmd = "service goconserver stop";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not stop goconserver service.");
        return 1;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  stop_conserver_service
        stop conserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $ret=(xCAT::Goconserver::stop_conserver_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub stop_conserver_service {
    my $cmd = "service conserver stop";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not stop conserver service.");
        return 1;
    }
    return 0;
}
#-------------------------------------------------------------------------------

=head3  restart_service
        restart goconserver service

    Returns:
        none
    Globals:
        none
    Example:
         my $ret=(xCAT::Goconserver::restart_service()
    Comments:
        none

=cut

#-------------------------------------------------------------------------------
sub restart_service {
    my $cmd = "service goconserver restart";
    xCAT::Utils->runcmd($cmd, -1);
    if ($::RUNCMD_RC != 0) {
        xCAT::MsgUtils->message("S", "Could not restart goconserver service.");
        return 1;
    }
    return 0;
}


sub get_api_port {
    return $go_api_port;
}
1;