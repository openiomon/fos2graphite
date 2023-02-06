#!/usr/bin/perl
## =============================================================================
##
##  File Name        : fos2graphite-worker.pl
##
##  Project Name     : Brocade Grafana
##
##  Author           : Timo Drach
##
##  Platform         : Linux Perl
##
##  Initially written: 08.05.2019
##
##  Description      : Script for import of performance and error counter of Brocade SAN Switches
##                     via RestAPI.
##
## ==============================================================================================

use strict;
use warnings;
use v5.10;
use POSIX ":sys_wait_h";
use feature qw( switch );
no if $] >= 5.018, warnings => qw( experimental::smartmatch );

use POSIX qw(strftime);
use POSIX qw(ceil);
use Time::HiRes qw(nanosleep usleep gettimeofday tv_interval);
use Socket;
use IO::Socket::INET;
use IO::Socket::UNIX;
use LWP::UserAgent;
use constant false => 0;
use constant true  => 1;
use Log::Log4perl;
use Getopt::Long;
use Time::Local;
use JSON;

# Variables for Graphite-Communication
my $graphitehost = "127.0.0.1";
my $graphiteport = "2003";
my $usetag = 0;

my $socketcnt = 0;
my $sockettimer = [gettimeofday];
my $maxmetricsperminute = 500000;
my $socketdelay = 10000;
my $delaymetric = 100;
my $socket;

my $watchdog = 300;
# maxdelay is set to $watchdogtime in nanoseconds deviced by 1000 since we are sending the alive singnal every 100.000 inserts but the delay is done every 100 inserts. The factor 0.9 adds in some tollerance to avaid watchdog is killing service because delay for inserts is to high! This might happen if the 1st 100.000 inserts are done in less than 2 seconds...
my $maxdelay = ($watchdog*1000*1000*1000)/1000*0.9;


my $ua;
my %args; # variable to store command line options for use with getopts
my $log; # log4perl logger

my $polltime = 0;
my $lasttime = 0;
my $fabric = "";
my $conf = '/opt/fos2graphite/conf/fos2graphite.conf';
my $logfile = "/opt/fos2graphite/";
my $loglevel = "INFO";

my $killtoken = "";
my $killswitch = "";

my $mainpid = $$;

my %porttypes = (
    0 => "Unknown",
    7 => "E_PORT",
    10 => "G_PORT",
    11 => "U_PORT",
    15 => "F_PORT",
    16 => "L_PORT",
    17 => "FCoE_PORT",
    19 => "EX_PORT",
    20 => "D_PORT",
    21 => "SIM_PORT",
    22 => "AF_PORT",
    23 => "AE_PORT",
    25 => "VE_PORT",
    26 => "Ethernet_Flex_PORT",
    29 => "Flex_PORT",
    30 => "N_PORT",
    32768 => "LB_PORT"
);

my %distancemodes = (
    0 => "E_PORT",
    1 => "LO_PORT",
    2 => "L1_PORT",
    3 => "L2_PORT",
    4 => "LE_PORT",
    5 => "L05_PORT",
    6 => "LD_PORT",
    7 => "LS_PORT"
);

my %portsettings;
my %metrics;
my %fabricdetails;
my %pids;
my %switchfqdns;
my %nameserver;
my %aliases;

sub printUsage {
    print("Usage:\n");
    print("$0 [OPTIONS]\n");
    print("OPTIONS:\n");
    print("   -conf <file>                  conf file containig parameter for the import\n");
    print("   -fabric <fabricname>          Name of the Fabric that should be imported\n");
    print("   -h                            print this output\n");
    print("\n");
}

sub parseCmdArgs{
    my $help = "";
    GetOptions (    "conf=s"                => \$conf,              # String
                    "fabric=s"              => \$fabric,            # String
                    "h"                     => \$help)              # flag
    or die("Error in command line arguments\n");

    if ($conf eq "") {
        print "Please specify config file!\n";
        printUsage();
        exit(1);
    }
    if ($fabric eq "") {
        print "Please specify fabric!\n";
        printUsage();
        exit(1);
    }
    readconfig();
    if (!defined($fabricdetails{$fabric})) {
        print "Specified fabric is defined in config file ".$conf." ! Please check!\n";
        exit(1);
    }
}

sub readconfig {
    if (!-f $conf) {
        print "Cannot open specified config file! ".$conf." Please check!\n";
        exit(1);
    }
    open(my $fh,'<',$conf) or die "Can't open config file $!";
    my $section = "";
    while(<$fh>) {
        my $line = $_;
        chomp($line);
        $line =~ s/\s//g;
        if ($line =~ "^#" || $line eq "") {
            next;
        }
        if ($line=~'^\[') {
            $section = $line;
            $section =~s/\[//;
            $section =~s/\]//;
            next;
        }
        given($section) {
            when('logging') {
                if ($line =~ "^logdir") {
                    my @values = split("=",$line);
                    my $logdir = $values[1];
                    $logfile = $logdir.'fos2graphite_'.$fabric.'.log';
                }
                if ($line =~"^loglevel") {
                    my @values = split("=",$line);
                    $loglevel = $values[1];
                }
            }
            when('graphite') {
                if ($line =~ "^graphite_host^") {
                    my @values = split("=",$line);
                    $graphitehost = $values[1];
                }
                if ($line =~ "^graphite_port") {
                    my @values = split("=",$line);
                    $graphiteport = $values[1];
                }
                if ($line =~"^metric_format") {
                    $line =~ s/\s//g;
                    my @values = split("=",$line);
                    if ($values[1] =~ "graphite-tag") {
                        $usetag = 1;
                    }
                }
            }
            default {
                my @values = split("=",$line);
                if ($line =~ "^seedswitch") {
                    $fabricdetails{$section}{'seedswitch'} = $values[1];
                }
                if ($line =~ "^user") {
                    $fabricdetails{$section}{'user'} = $values[1];
                }
                if ($line =~ "^password") {
                    $fabricdetails{$section}{'password'} = $values[1];
                }
                if ($line =~ "^collect_uports") {
                    $fabricdetails{$section}{'collect_uports'} = $values[1];
                }
                if ($line =~ "^perf_refresh_interval") {
                    $fabricdetails{$section}{'perf_interval'} = $values[1];
                }
                if ($line =~ "^stats_refresh_interval") {
                    $fabricdetails{$section}{'stats_interval'} = $values[1];
                }
                if ($line =~ "^config_refresh_interval") {
                    $fabricdetails{$section}{'config_interval'} = $values[1];
                }
                if ($line =~ "^metric_file") {
                    $fabricdetails{$section}{'metric_file'} = $values[1];
                }
                if ($line =~"^ssl_verfiy_host") {
                    $fabricdetails{$section}{'ssl_verfiy_host'} = $values[1];
                }
                if ($line =~"^IT_collection") {
                    $fabricdetails{$section}{'IT_collection'} = uc($values[1]);
                }
                if ($line =~"refresh_offset") {
                    if ($values[1] > 30) {
                        $fabricdetails{$section}{'refresh_offset'} = 30;
                    } elsif ($values[1] < 0) {
                        $fabricdetails{$section}{'refresh_offset'} = 0;
                    } else {
                        $fabricdetails{$section}{'refresh_offset'} = $values[1];
                    }
                }
                if ($line=~"^vFID") {
                    $line =~ s/\s//;
                    $fabricdetails{$section}{'virtual_fabric'} = $values[1];
                }
                if ($line=~"^monitor_switchhardware") {
                    $line =~ s/\s//;
                    $fabricdetails{$section}{'monitor_switchhw'} = $values[1];
                }
            }
        }
    }
}

sub readMetrics {
    my $metricfile = "";
    if (!defined($fabricdetails{$fabric}{'metric_file'})) {
        print "A metric file was not specified for ".$fabric." in ".$conf." ! Please check config file and add metric file specification.\n";
        $log->error("A metric file was not specified for ".$fabric." in ".$conf." ! Please check config file and add metric file specification.");
        exit(1);
    }
    if (!-f $fabricdetails{$fabric}{'metric_file'}) {
        print "The metric file specified cannot be found. Please check config file or metric file specified: ".$fabricdetails{$fabric}{'metric_file'}."\n";
        $log->error("The metric file specified cannot be found. Please check config file or metric file specified: ".$fabricdetails{$fabric}{'metric_file'});
        exit(1);
    }
    open(my $fh,'<',$fabricdetails{$fabric}{'metric_file'}) or die "Can't open metric file $!";
    while(<$fh>) {
        my $line = $_;
        chomp $line;
        $line =~ s/\s//g;
        if ($line =~ "^#" || $line eq "") {
            next;
        }
        if ($line =~ ":") {
            my @values = split(':',$line);
            if (scalar(@values)<3) {
                $log->error("The metric file contains a metric without specifying alias and category! Please check: ".$line." !");
            } else {
                if ($values[1] ne "") {
                    $metrics{$values[0]}{'name'} = $values[1];
                } else {
                    $metrics{$values[0]}{'name'} = $values[0];
                }
                $metrics{$values[0]}{'category'} = $values[2];
            }
        }
    }
}

sub restLogin {
    my $switch = $_[0];
    my $user = $_[1];
    my $passwd = $_[2];
    $log->debug("Logging in to ".$switch." with user: ".$user);
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/login';
    $log->debug("URL for login: ".$url);
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->authorization_basic($user,$passwd);
    my $resp = $ua->request($req);
    if ($resp->is_success) {
        my $responseheader = $resp->header("Authorization");
        $killtoken = $responseheader;
        $killswitch = $fqdn;
        return($responseheader);
    } else {
        $log->error("Failed to POST data from ".$url." with HTTP POST error code: ".$resp->code);
        $log->error("Failed to POST data from ".$url." with HTTP POST error message: ".$resp->message);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
}

sub restLogout {
    my $switch = $_[0];
    my $token = $_[1];
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    $log->debug("Logging out from ".$switch." by removing token: ".$token);
    my $url = 'https://'.$fqdn.'/rest/logout';
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $resp = $ua->request($req);
    if ($resp->is_success) {
        $killtoken = "";
        $killswitch = "";
        return(0);
    } else {
        $log->error("Failed to POST data from ".$url." with HTTP POST error code: ".$resp->code);
        $log->error("Failed to POST data from ".$url." with HTTP POST error message: ".$resp->message);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
}

sub getFabricSwitches {
    my $fabric = $_[0];
    my $seedswitch = $_[1];
    my $token = $_[2];
    my $url = 'https://'.$seedswitch.'/rest/running/brocade-fabric/fabric-switch';
    if (defined($fabricdetails{$fabric}{virtual_fabric})) {
        $url .= '?vf-id='.$fabricdetails{$fabric}{virtual_fabric};
    }
    my $req = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'application/yang-data+json');
        $req->header('Content-Type' => 'application/yang-data+json');
        $req->header('Authorization' => $token);
    my $resp = $ua->request($req);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->debug("Trying to logout from ".$seedswitch);
        restLogout($seedswitch,$token);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    my $responsecontent = $resp->decoded_content;
    my %json = %{decode_json($responsecontent)};
    my @fabricswitches = $json{"Response"}{"fabric-switch"};
    foreach my $fabricswitch (@fabricswitches) {
        my @singleswitches = @{$fabricswitch};
        foreach my $singleswitch (@singleswitches){
            my %switchattr = %{$singleswitch};
            if (($switchattr{"switch-user-friendly-name"} =~ "^fcr") || ($switchattr{"firmware-version"} =~ "AMPOS") || ($switchattr{"ip-address"} eq "0.0.0.0")) {
                next;
            }
            my $dnsname = lc(gethostbyaddr(inet_aton($switchattr{"ip-address"}), AF_INET));
            $switchfqdns{$switchattr{"switch-user-friendly-name"}} = $dnsname;
            $log->info("Discovered switch ".$switchattr{"switch-user-friendly-name"}." (".$switchattr{"ip-address"}.") as member of fabric ".$fabric." and will use DNS-name: ".$dnsname);
            $log->info("Will use ".$dnsname." for Switch: ".$switchattr{"switch-user-friendly-name"});
            $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"IP"} = $switchattr{"ip-address"};
            $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"FQDN"} = $dnsname;
            $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"NAME"} = $switchattr{"name"};
            $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"CHASSISNAME"} = $switchattr{"chassis-user-friendly-name"};
            $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"DOMAINID"} = $switchattr{"domain-id"};
        }
    }
    return($responsecontent);
}

sub getFCPortCounters {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    my $mode = $_[3];
    $log->debug("Getting port counter for ".$fabric." ".$switch." with mode ".$mode."!");
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/running/brocade-interface/fibrechannel-statistics/';
    if (defined($fabricdetails{$fabric}{virtual_fabric})) {
        $url .= '?vf-id='.$fabricdetails{$fabric}{virtual_fabric};
    }
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".fibrechannel-statistics.duration ".$queryduration." ".$now;
    if ($usetag) {
        $statsstring = 'fos2graphite_duration;query=fibrechannel-statistics;switch='.$switch.' '.$queryduration.' '.$now;
    }
    toGraphite($statsstring);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->debug("Trying to logout from ".$switch);
        restLogout($switch,$token);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    my $responsecontent = $resp->decoded_content;
    my %json = %{decode_json($responsecontent)};
    my @portstatistics = $json{"Response"}{"fibrechannel-statistics"};
    foreach my $portarray (@portstatistics) {
        my @ports = @{$portarray};
        foreach my $port (@ports) {
            my %portattr = %{$port};
            my @portvalues = split('/',$portattr{"name"});
            my $slot = $portvalues[0];
            my $portnumber = $portvalues[1];
            my $porttype = $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"porttype"};
            foreach my $keyname (keys %portattr) {
                if (!defined($metrics{$keyname})) {
                    next;
                }
                my $metricname = $metrics{$keyname}{'name'};
                my $metricvalue = $portattr{$keyname};
                if ($mode eq "perf") {
                    if ($metrics{$keyname}{'category'} ne "perf") {
                        next;
                    }
                }
                if ($usetag) {
                    $metricname =~ s/-/_/g;
                }
                $log->trace($switch." => Name: ".$portattr{"name"}." : Key: ".$keyname." => ".$portattr{$keyname});
                my $metricstring = "";
                
                # skip collection if port is not used and collect_uports is not enabled
                if (($porttype eq "U_PORT")&&(!$fabricdetails{$fabric}{'collect_uports'})) {
                    next;
                }
                $metricstring = "brocade.fos.".$metrics{$keyname}{'category'}.".ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname." ".$metricvalue." ".$now;
                if ($usetag) {
                    $metricstring = 'fosports_'.$metricname.';fabric='.$fabric.';category='.$metrics{$keyname}{'category'}.';switch='.$switch.';porttype='.$porttype.';slot='.$slot.';port='.$portnumber.' '.$metricvalue.' '.$now;
                }
                toGraphite($metricstring);
                
                # skip collection of fosinittarget metrics, if IT_collection is not enabled
                if (!defined($fabricdetails{$fabric}{'IT_collection'}) || ($fabricdetails{$fabric}{'IT_collection'} ne "ALIAS") && ($fabricdetails{$fabric}{'IT_collection'} ne "WWPN")) {
                    next;
                }
                my @wwpns = @{$portsettings{$fabric}{$switch}{$slot}{$portnumber}{"neighbors"}};
                foreach my $wwpn (@wwpns) {
                    if (defined($nameserver{$wwpn}{'devicetype'})) {
                        my $devicetype = $nameserver{$wwpn}{'devicetype'};
                        if (($fabricdetails{$fabric}{'IT_collection'} eq "ALIAS") && (defined($aliases{$wwpn}))) {
                            $metricstring = "brocade.fos.".$metrics{$keyname}{'category'}.".devices.".$fabric.".".$devicetype.".".$aliases{$wwpn}.".".$metricname." ".$metricvalue." ".$now;
                            if ($usetag) {
                               $metricstring = 'fosinittarget_'.$metricname.';fabric='.$fabric.';category='.$metrics{$keyname}{'category'}.';devicetype='.$devicetype.';alias='.$aliases{$wwpn}.' '.$metricvalue.' '.$now;
                            }
                            toGraphite($metricstring);
                        } elsif ($fabricdetails{$fabric}{'IT_collection'} eq "WWPN") {
                            my $plainwwpn = $wwpn;
                            $plainwwpn =~ s/\://g;
                            $metricstring = "brocade.fos.".$metrics{$keyname}{'category'}.".devices.".$fabric.".".$devicetype.".".$wwpn.".".$metricname." ".$metricvalue." ".$now;
                            if ($usetag) {
                                $metricstring = 'fosinittarget_'.$metricname.';fabric='.$fabric.';category='.$metrics{$keyname}{'category'}.';devicetype='.$devicetype.';alias='.$wwpn.' '.$metricvalue.' '.$now;
                            }
                            toGraphite($metricstring);
                        }
                    }
                }
            }
        }
    }
    $log->debug("Finished getting port counter for ".$fabric." ".$switch."!");
}

sub getPortSettings {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/running/brocade-interface/fibrechannel/';
    if (defined($fabricdetails{$fabric}{virtual_fabric})) {
        $url .= '?vf-id='.$fabricdetails{$fabric}{virtual_fabric};
    }
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".fibrechannel.duration ".$queryduration." ".$now;
    if ($usetag) {
        $statsstring = 'fos2graphite_duration;query=fibrechannel;switch='.$switch.' '.$queryduration.' '.$now;
    }
    toGraphite($statsstring);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->debug("Trying to logout from ".$switch);
        restLogout($switch,$token);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }

    my $responsecontent = $resp->decoded_content;
    my %json = %{decode_json($responsecontent)};
    my @portstatistics = $json{"Response"}{"fibrechannel"};
    foreach my $portarray (@portstatistics) {
        my @ports = @{$portarray};
        foreach my $port (@ports) {
            my %portattr = %{$port};
            my $portname = $portattr{"name"};
            my @portvalues = split('/',$portname);
            my $slot = $portvalues[0];
            my $portnumber = $portvalues[1];
            my $porttype = $porttypes{$portattr{"port-type"}};
            my $portspeed = $portattr{"speed"};
            if ($porttype eq "E_PORT") {
                    $porttype = $distancemodes{$portattr{"long-distance"}};
            }
            my @wwns=();
            if (defined($portattr{"neighbor"}{"wwn"})) {
                @wwns = @{$portattr{"neighbor"}{"wwn"}};
                if (($loglevel eq "DEBUG") || ($loglevel eq "TRACE")) {
                    foreach my $wwn (@wwns) {
                        $log->debug($switch.": ".$slot."/".$portnumber." has attached WWPN: ".$wwn);
                    }
                }
            }
            $log->debug("FCID for ".$portname." of ".$switch." is ".$portattr{"fcid-hex"});
            $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"porttype"}     = $porttype;
            $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"speed"}        = $portspeed;
            $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"fcid"}         = $portattr{"fcid-hex"};
            $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"neighbors"}    = \@wwns;
            if (($porttype ne "U_PORT")||($fabricdetails{$fabric}{'collect_uports'})) {
                my $metricstring = "";
                $metricstring = "brocade.fos.stats.ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".portspeed ".$portspeed." ".$now;
                if ($usetag) {
                    $metricstring = "fosports_portspeed;fabric=".$fabric.";category=stats;switch=".$switch.";porttype=".$porttype.";slot=".$slot.";port=".$portnumber." ".$portspeed." ".$now;
                }
                toGraphite($metricstring);
            }
        }
    }
}

sub getSystemResources {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    my $mode = $_[3];

    if (defined($fabricdetails{$fabric}{'monitor_switchhw'})) {
        if ($fabricdetails{$fabric}{'monitor_switchhw'} == 0) {
           $log->info("Skipping System Resource logging for ".$fabric."/".$switch." due to config");
           return;
        }
    }

    $log->debug("Getting system counter for ".$fabric." ".$switch." with mode ".$mode."!");
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/running/brocade-maps/system-resources/';
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".system-resources.duration ".$queryduration." ".$now;
    if ($usetag) {
        $statsstring = 'fos2graphite_duration;query=system-resources;switch='.$switch.' '.$queryduration.' '.$now;
    }
    toGraphite($statsstring);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->debug("Trying to logout from ".$switch);
        restLogout($switch,$token);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    my $responsecontent = $resp->decoded_content;
    my %json = %{decode_json($responsecontent)};
    my @systemperfcounters = $json{"Response"}{"system-resources"};
    foreach my $counters (@systemperfcounters) {
        my %counterhash = %{$counters};
        foreach my $counter (keys %counterhash) {
            $log->trace($fabric.": ".$switch." - ".$counter." = ".$counterhash{$counter});
            if (defined($metrics{$counter})) {
                my $metricname = $metrics{$counter}{'name'};
                if ($mode eq "perf") {
                    if ($metrics{$counter}{'category'} ne "perf") {
                        next;
                    }
                }
                my $metricstring = "brocade.fos.".$metrics{$counter}{'category'}.".switches.".$fabric.".".$switch.".".$metricname." ".$counterhash{$counter}." ".$now;
                if ($usetag) {
                    $metricname =~ s/-/_/g;
                    $metricstring = 'fosswitch_'.$metricname.';category='.$metrics{$counter}{'category'}.';fabric='.$fabric.';switch='.$switch.' '.$counterhash{$counter}.' '.$now;
                }
                toGraphite($metricstring);
            }
        }
    }
    $log->debug("Finished getting system counter for ".$fabric." ".$switch."!");
}

sub getMediaCounters {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    my $mode = $_[3];
    $log->debug("Getting media counter for ".$fabric." ".$switch." with mode ".$mode."!");
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/running/brocade-media/media-rdp/';
    if (defined($fabricdetails{$fabric}{virtual_fabric})) {
        $url .= '?vf-id='.$fabricdetails{$fabric}{virtual_fabric};
    }
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".brocade-media.duration ".$queryduration." ".$now;
    if ($usetag) {
        $statsstring = 'fos2graphite_duration;query=brocade-media;switch='.$switch.' '.$queryduration.' '.$now;
    }
    toGraphite($statsstring);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->debug("Trying to logout from ".$switch);
        restLogout($switch,$token);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    my $responsecontent = $resp->decoded_content;
    my %json =  %{decode_json($responsecontent)};
    my @mediastatistics = $json{"Response"}{"media-rdp"};
    foreach my $mediaarray (@mediastatistics) {
        my @medias = @{$mediaarray};
        foreach my $media (@medias) {
            my %mediaattr = %{$media};
            my @medianameparts = split('/', $mediaattr{'name'});
            my $slot = $medianameparts[1];
            my $portnumber = $medianameparts[2];
            my $porttype = $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"porttype"};
            foreach my $metric (keys %mediaattr) {
                if (!defined($metrics{$metric})) {
                    next;
                }
                my $metricvalue = $mediaattr{$metric};
                my $metricstring = "";
                my $metricname = $metrics{$metric}{'name'};
                if ($usetag) {
                    $metricname =~ s/-/_/g;
                }
                if ($mode eq "perf") {
                    if ($metrics{$metric}{'category'} ne "perf") {
                        next;
                    }
                }
                # skip collection if port is not used and collect_uports is not enabled
                if (($porttype eq "U_PORT")&&(!$fabricdetails{$fabric}{'collect_uports'})) {
                    next;
                }
                # calculate dbm values for tx-power & rx-power metrics and emit as seperate metric
                if ($metric =~ "x-power") {
                    my $dbm = 0;
                    if ($metricvalue>0) {
                        $dbm = sprintf("%.2f",(10*(log($metricvalue/1000)/log(10))));
                    }
                    $metricstring = "brocade.fos.".$metrics{$metric}{'category'}.".ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname."-dbm ".$dbm." ".$now;
                    if ($usetag) {
                        $metricstring = 'fosports_'.$metricname.'_dbm;fabric='.$fabric.';category='.$metrics{$metric}{'category'}.';switch='.$switch.';porttype='.$porttype.';slot='.$slot.';port='.$portnumber.' '.$dbm.' '.$now;
                    }
                    toGraphite($metricstring);
                    
                    # skip collection of fosinittarget metrics, if IT_collection is not enabled
                    if (defined($fabricdetails{$fabric}{'IT_collection'}) && (($fabricdetails{$fabric}{'IT_collection'} eq "ALIAS") || ($fabricdetails{$fabric}{'IT_collection'} eq "WWPN"))) {
                        my @wwpns = @{$portsettings{$fabric}{$switch}{$slot}{$portnumber}{"neighbors"}};
                        foreach my $wwpn (@wwpns) {
                            if (defined($nameserver{$wwpn}{'devicetype'})) {
                                my $devicetype = $nameserver{$wwpn}{'devicetype'};
                                if (($fabricdetails{$fabric}{'IT_collection'} eq "ALIAS") && (defined($aliases{$wwpn}))) {
                                    $metricstring = "brocade.fos.".$metrics{$metric}{'category'}.".devices.".$fabric.".".$devicetype.".".$aliases{$wwpn}.".".$metricname."-dbm ".$dbm." ".$now;
                                    if ($usetag) {
                                        $metricstring = 'fosinittarget_'.$metricname.'_dbm;fabric='.$fabric.';category='.$metrics{$metric}{'category'}.';devicetype='.$devicetype.';alias='.$aliases{$wwpn}.' '.$dbm.' '.$now;
                                    }
                                    toGraphite($metricstring);
                                } elsif ($fabricdetails{$fabric}{'IT_collection'} eq "WWPN") {
                                    my $plainwwpn = $wwpn;
                                    $plainwwpn =~ s/\://g;
                                    $metricstring = "brocade.fos.".$metrics{$metric}{'category'}.".devices.".$fabric.".".$devicetype.".".$wwpn.".".$metricname."-dbm ".$dbm." ".$now;
                                    if ($usetag) {
                                        $metricstring = 'fosinittarget_'.$metricname.'_dbm;fabric='.$fabric.';category='.$metrics{$metric}{'category'}.';devicetype='.$devicetype.';alias='.$wwpn.' '.$dbm.' '.$now;
                                    }
                                    toGraphite($metricstring);
                                }
                            }
                        }
                    }
                }
                $metricstring = "brocade.fos.".$metrics{$metric}{'category'}.".ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname." ".$metricvalue." ".$now;
                if ($usetag) {
                    $metricstring = 'fosports_'.$metricname.';fabric='.$fabric.';category='.$metrics{$metric}{'category'}.';switch='.$switch.';porttype='.$porttype.';slot='.$slot.';port='.$portnumber.' '.$metricvalue.' '.$now;
                }
                toGraphite($metricstring);
                
                # skip collection of fosinittarget metrics, if IT_collection is not enabled
                if (!defined($fabricdetails{$fabric}{'IT_collection'}) || ($fabricdetails{$fabric}{'IT_collection'} ne "ALIAS") && ($fabricdetails{$fabric}{'IT_collection'} ne "WWPN")) {
                    next;
                }
                my @wwpns = @{$portsettings{$fabric}{$switch}{$slot}{$portnumber}{"neighbors"}};
                foreach my $wwpn (@wwpns) {
                    if (defined($nameserver{$wwpn}{'devicetype'})) {
                        my $devicetype = $nameserver{$wwpn}{'devicetype'};
                        if (($fabricdetails{$fabric}{'IT_collection'} eq "ALIAS") && (defined($aliases{$wwpn}))) {
                            $metricstring = "brocade.fos.".$metrics{$metric}{'category'}.".devices.".$fabric.".".$devicetype.".".$aliases{$wwpn}.".".$metricname." ".$metricvalue." ".$now;
                            if ($usetag) {
                               $metricstring = 'fosinittarget_'.$metricname.';fabric='.$fabric.';category='.$metrics{$metric}{'category'}.';devicetype='.$devicetype.';alias='.$aliases{$wwpn}.' '.$metricvalue.' '.$now;
                            }
                            toGraphite($metricstring);
                        } elsif ($fabricdetails{$fabric}{'IT_collection'} eq "WWPN") {
                            my $plainwwpn = $wwpn;
                            $plainwwpn =~ s/\://g;
                            $metricstring = "brocade.fos.".$metrics{$metric}{'category'}.".devices.".$fabric.".".$devicetype.".".$wwpn.".".$metricname." ".$metricvalue." ".$now;
                            if ($usetag) {
                                $metricstring = 'fosinittarget_'.$metricname.';fabric='.$fabric.';category='.$metrics{$metric}{'category'}.';devicetype='.$devicetype.';alias='.$wwpn.' '.$metricvalue.' '.$now;
                            }
                            toGraphite($metricstring);
                        }
                    }
                }
            }
        }
    }
    $log->debug("Finished getting media counter for ".$fabric." ".$switch."!");
}

sub getNameserver {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    $log->info("Getting name server config from ".$switch." from fabric: ".$fabric);
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/running/brocade-name-server/fibrechannel-name-server';
    if (defined($fabricdetails{$fabric}{virtual_fabric})) {
        $url .= '?vf-id='.$fabricdetails{$fabric}{virtual_fabric};
    }
    $log->debug("Requesting URL: ".$url);
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".brocade-nameserver.duration ".$queryduration." ".$now;
    if ($usetag) {
        $statsstring = 'fos2graphite_duration;query=brocade-nameserver;switch='.$switch.' '.$queryduration.' '.$now;
    }
    toGraphite($statsstring);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->warn("This might be related to a switch with no name server entries... So trying to continue...");
        return;
    }
    my $responsecontent = $resp->decoded_content;
    # replacing invalid single backslashes with double backslash in JSON response
    # using - (dash) as regex delimiter to make it more readable
    $responsecontent =~ s-(?<!\\)\\(?![\\"bfnrt])-\\\\-g;
    my %json = %{decode_json($responsecontent)};
    my @nsshow = $json{"Response"}{'fibrechannel-name-server'};
    %nameserver = ();
    foreach my $nsarrayref (@nsshow) {
        my @nsarray = @{$nsarrayref};
        for my $nshashref (@nsarray) {
            my %nshash = %{$nshashref};
            my $pid = $nshash{'port-id'};
            my $portname = $nshash{'port-name'};
            my $nodename =  $nshash{'node-name'};
            my $devicetype = $nshash{'name-server-device-type'};
            $devicetype =~ s/\s/_/g;
            $devicetype =~ s/\//_/g;
            $log->debug($portname." has nodename: ".$nodename." at PID: ".$pid." with type: ".$devicetype);
            $nameserver{$portname}{'devicetype'} = $devicetype;
            $nameserver{$portname}{'pid'} = $pid;
        }
    }
}

sub getAliases {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    $log->info("Getting aliases from ".$switch." for fabric: ".$fabric);
    my $fqdn = $switch;
    if (defined($switchfqdns{$switch})) {
        $fqdn = $switchfqdns{$switch};
    }
    my $url = 'https://'.$fqdn.'/rest/running/brocade-zone/defined-configuration/alias';
    if (defined($fabricdetails{$fabric}{virtual_fabric})) {
        $url .= '?vf-id='.$fabricdetails{$fabric}{virtual_fabric};
    }
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".brocade-zone.duration ".$queryduration." ".$now;
    if ($usetag) {
        $statsstring = 'fos2graphite_duration;query=brocade-zone;switch='.$switch.' '.$queryduration.' '.$now;
    }
    toGraphite($statsstring);
    if (!$resp->is_success) {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->warn("This might be related to a switch with aliases or zoning active... So trying to continue...");
        return;
    }
    %aliases = ();
    my $responsecontent = $resp->decoded_content;
    my %json = %{decode_json($responsecontent)};
    my @allaliases = $json{"Response"}{"alias"};
    foreach my $aliarrayref (@allaliases) {
        my @aliarray = @{$aliarrayref};
        foreach my $aliashashref (@aliarray) {
            my %alihash = %{$aliashashref};
            my $aliname = $alihash{'alias-name'};
            my @wwnarray = @{$alihash{'member-entry'}{'alias-entry-name'}};
            foreach my $wwn (@wwnarray) {
                if (defined($aliases{$wwn})) {
                    $log->warn("WWN found with more than 1 alias! (".$wwn." / ".$aliname.")");
                } else {
                    $log->debug($wwn." has alias: ".$aliname);
                    $aliases{$wwn} = $aliname;
                }
            }
        }
    }
}

sub reportmetrics {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $conftime = 0;
    my $statstime = 0;
    $polltime = time();
    $polltime = $polltime - ($polltime % 60);
    if (defined($fabricdetails{$fabric}{'refresh_offset'})) {
        $polltime = $polltime - ($polltime % 60)+$fabricdetails{$fabric}{'refresh_offset'};
    }
    while(true) {

        my $curtime = time();
        if (($curtime - $polltime)>=$fabricdetails{$fabric}{'perf_interval'}) {
            my $printtime = strftime('%m/%d/%Y %H:%M:%S',localtime($curtime));
            $log->info("Collecting new set of data for ".$fabric." - ".$switch." at ".$printtime);
            initsocket();
            $log->info("Logging in to ".$fabric." / ".$switch);
            my $token = restLogin($switch,$fabricdetails{$fabric}{"user"},$fabricdetails{$fabric}{"password"});
            if (($curtime - $conftime)>=$fabricdetails{$fabric}{'config_interval'}) {
                $log->info("Collecting new set of data for ".$fabric." - ".$switch." at ".$printtime);
                $log->info("Getting nameserver and alias configuration");
                getNameserver($fabric,$switch,$token);
                if ($fabricdetails{$fabric}{'IT_collection'} eq "ALIAS") {
                    getAliases($fabric,$switch,$token);
                }
                $conftime = $curtime;
            }
            getPortSettings($fabric,$switch,$token);
            if (($curtime - $statstime)>=$fabricdetails{$fabric}{'stats_interval'}) {
                $log->info("Getting performance- and error-counters for ".$fabric." / ".$switch);
                getSystemResources($fabric,$switch,$token,'ALL');
                getFCPortCounters($fabric,$switch,$token,'ALL');
                getMediaCounters($fabric,$switch,$token,'ALL');
                $statstime = $curtime;
            } else {
                $log->info("Getting only performance-counters for ".$fabric." / ".$switch);
                getSystemResources($fabric,$switch,$token,'perf');
                getFCPortCounters($fabric,$switch,$token,'perf');
                getMediaCounters($fabric,$switch,$token,'perf');
            }
            $log->info("Logout from ".$fabric." / ".$switch);
            restLogout($switch,$token);
            $polltime = $polltime + $fabricdetails{$fabric}{'perf_interval'};
            closesocket();
        }
        sleep(1);
    }
}

sub startreporter {
    my $fabric = $_[0];
    servicestatus('Running reporters...');
    foreach my $switch (keys %{$fabricdetails{$fabric}{"switches"}}) {
        my $pid = fork();
        if (!$pid) {
            reportmetrics($fabric,$switch);
        } else {
            $pids{$switch}=$pid;
        }
    }
}

sub checkreporter {
    my $fabric = $_[0];
    my $livecounter = 0;
    while(true) {
        foreach my $switch (sort keys %pids) {
            my $res = waitpid($pids{$switch}, WNOHANG);
            if ($res) {
                my $rc = $?>>8;
                $log->error("Looks like PID: ".$pids{$switch}." for switch ".$switch." is not running! It ended with returncode ".$rc);
                $log->error("Restarting for Switch ".$switch);
                sleep(10);
                my $pid = fork();
                if (!$pid) {
                    reportmetrics($fabric,$switch);
                } else {
                    $pids{$switch}=$pid;
                }
            }
       }
       if ($livecounter > 60) {
           alive();
           $livecounter = 0;
       }
       $livecounter += 1;
       sleep(1);
   }
}

sub toGraphite() {
    $socketcnt+=1;
    my $message = $_[0];
    $socket->send($message."\n");
    if (($socketdelay>0)&&!($socketcnt % $delaymetric)) {
        nanosleep($socketdelay);
    }
    if ($socketcnt>=100000) {
        my $elapsed = tv_interval ( $sockettimer, [gettimeofday]);
        my $metricsperminute = 60/$elapsed*100000;
        if ($socketdelay>0) {
            $socketdelay = int($socketdelay*($metricsperminute/$maxmetricsperminute));
            # in case of running as service avoid that oversized delay will trigger the watchdog
            if ($socketdelay > $maxdelay) {
                $socketdelay = $maxdelay;
            }
        } else {
            $socketdelay = int(1000*($metricsperminute/$maxmetricsperminute));
        }
        $log->info("Elapsed time for last 100.000 Metrics: ".sprintf("%.2f",$elapsed)."s => metrics per minute: ".sprintf("%.2f",$metricsperminute)." new delay: ".$socketdelay);
        $sockettimer = [gettimeofday];
        $socketcnt = 0;
    }
}

sub initsocket {
    $socket = new IO::Socket::INET (
        PeerHost => $graphitehost,
        PeerPort => $graphiteport,
        Proto => 'tcp',
    );
    $log->logdie("cannot connect to the server $!") unless $socket;
    setsockopt($socket, SOL_SOCKET, SO_KEEPALIVE, 1);
    $log->debug("Opening connection ".$socket->sockhost().":".$socket->sockport()." => ".$socket->peerhost().":".$socket->peerport());
}

sub closesocket {
    $log->debug("Closing Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
    $socket->shutdown(2);
}

# Sub to initialize Systemd Service
sub initservice {
    if (defined $ENV{'NOTIFY_SOCKET'}) {
        if ($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "READY=1\n";
            $log->info("Service is initialized...");
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}

# Sub to update status of Systemd Service when running as Daemon
sub servicestatus {
    my $message = $_[0];
    if (defined $ENV{'NOTIFY_SOCKET'}) {
        if ($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "STATUS=$message\n";
            $log->trace("Servicemessage has been send: ".$message);
            close($sock);
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}

# Sub to signal a stop of the script to the service when running as Daemon
sub stopservice {
    if (defined $ENV{'NOTIFY_SOCKET'}) {
        if ($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "STOPPING=1\n";
            $log->info("Service is shutting down...");
            close($sock);
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}

# Sub to send heartbeat to watchdog of Systemd service when running as Daemon.
sub alive {
    if (defined $ENV{'NOTIFY_SOCKET'}) {
        if ($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "WATCHDOG=1\n";
            $log->trace("Watchdog message has been send to systemd...");
            close($sock);
        }

    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}

# Sub to end REST API sessions when service is shut down
sub serviceshutdown {
    $log->info("Received shutdown / kill signal for process $$ from systemd!" );
    if (($killswitch ne "") && ($killtoken ne "")) {
        $log->debug("Trying to close session to $killswitch...");
        restLogout($killswitch,$killtoken);
    }
    exit();
}

# MAIN
parseCmdArgs();

my $log4perlConf  = qq(
log4perl.logger.main.report            = $loglevel,  FileAppndr1
log4perl.appender.FileAppndr1          = Log::Log4perl::Appender::File
log4perl.appender.FileAppndr1.filename = $logfile
log4perl.appender.FileAppndr1.umask    = 0022
log4perl.appender.FileAppndr1.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.FileAppndr1.layout.ConversionPattern = %d [%p] (PID: %P %F:%L) %M > %m %n
);
Log::Log4perl->init(\$log4perlConf);
$log = Log::Log4perl->get_logger('main.report');

$SIG{TERM} = \&serviceshutdown;
$SIG{KILL} = \&serviceshutdown;

initservice();

readMetrics();

servicestatus("Discovering fabric...");
if ($fabricdetails{$fabric}{"ssl_verfiy_host"} == 0) {
    $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0, SSL_verify_mode=>0x00 });
} else {
    $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 1 });
}

my $token = restLogin($fabricdetails{$fabric}{"seedswitch"},$fabricdetails{$fabric}{"user"},$fabricdetails{$fabric}{"password"});

getFabricSwitches($fabric,$fabricdetails{$fabric}{"seedswitch"},$token);
restLogout($fabricdetails{$fabric}{"seedswitch"},$token);

startreporter($fabric);
checkreporter($fabric);