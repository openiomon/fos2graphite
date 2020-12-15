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
##  Initially written: 08.05.2017
##
##  Description      : Script for import of performance and error counter of Brocade SAN Switches
##                     via RestAPI.
##
## ==============================================================================================

use strict;
use warnings;
use v5.10;
use POSIX ":sys_wait_h";

use lib '/opt/fos2graphite/lib/perl5/';

use POSIX qw(strftime);
use POSIX qw(ceil);
use Time::HiRes qw(nanosleep usleep gettimeofday tv_interval);
use IO::Socket::INET;
use LWP::UserAgent;
use constant false => 0;
use constant true  => 1;
use Log::Log4perl;
use Getopt::Long;
use Time::Local;
use JSON;
use Systemd::Daemon qw( -hard notify );

#Variables for Graphite-Communication

my $graphitehost = "127.0.0.1";
my $graphiteport = "2003";

my $socketcnt = 0;
my $sockettimer;
my $maxmetricsperminute = 500000;
my $socketdelay = 10000;
my $delaymetric = 100;
my $socket;

my $watchdog = 300;
# maxdelay is set to $watchdogtime in nanoseconds deviced by 1000 since we are sending the alive singnal every 100.000 inserts but the delay is done every 100 inserts. The factor 0.9 adds in some tollerance to avaid watchdog is killing service because delay for inserts is to high! This might happen if the 1st 100.000 inserts are done in less than 2 seconds...
my $maxdelay = ($watchdog*1000*1000*1000)/1000*0.9;


my $ua;
my %args;  # variable to store command line options for use with getopts
my $log; # log4perl logger

my $log_uport=false;
my $polltime = 0;
my $lasttime = 0;
my $fabric = "";
my $daemon = false;
my $conf = '/opt/fos2graphite/conf/fos2graphite.conf';
my $logfile = "/opt/fos2graphite/";
my $loglevel = "INFO";

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

sub printUsage {
        print("Usage:\n");
        print("$0 [OPTIONS]\n");
        print("OPTIONS:\n");
        print("   -conf <file>                  conf file containig parameter for the import\n");
        print("   -fabric <fabricname>          Name of the Fabric that should be imported\n");
        print("   -daemon                       Flag which will supress the output to console\n");
        print("   -h                            print this output\n");
        print("\n");
}

sub parseCmdArgs{
        my $help = "";
        GetOptions (    "conf=s"                => \$conf,              # String
                        "fabric=s"              => \$fabric,            # String
                        "daemon"                => \$daemon,            # flag
                        "h"                     => \$help)              # flag
        or die("Error in command line arguments\n");

    if($conf eq "") {
        print "Please specify config file!\n";
        printUsage();
        exit(1);
    }
    if($fabric eq "") {
        print "Please specify fabric!\n";
        printUsage();
        exit(1);
    }
    readconfig();
    if(!defined($fabricdetails{$fabric})) {
        print "Specified fabric is defined in config file ".$conf." ! Please check!\n";
        exit(1);
    }
}

sub readconfig {
    if(!-f $conf) {
        print "Cannot open specified config file! ".$conf." Please check!\n";
        exit(1);
    }
    open(my $fh,'<',$conf) or die "Can't open config file $!";
    my $section = "";
    while(<$fh>) {
        my $line = $_;
        chomp($line);
        $line =~ s/\s//g;
        if($line =~ "^#" || $line eq "") {
            next;
        }
        if($line=~'^\[') {
            $section = $line;
            $section =~s/\[//;
            $section =~s/\]//;
        } else {
            given($section) {
                when('logging') {
                    if($line =~ "^logdir") {
                        my @values = split("=",$line);
                        my $logdir = $values[1];
                        $logfile = $logdir.'fos2graphite_'.$fabric.'.log';
                    }
                    if($line =~"^loglevel") {
                        my @values = split("=",$line);
                        $loglevel = $values[1];
                    }
                }
                when('graphite') {
                    if($line =~ "^graphite_host^") {
                        my @values = split("=",$line);
                        $graphitehost = $values[1];
                    }
                    if($line =~ "^graphite_port") {
                        my @values = split("=",$line);
                        $graphiteport = $values[1];
                    }
                }
                default {
                    print $section."\n";
                    my @values = split("=",$line);
                    if($line =~ "^seedswitch") {
                        $fabricdetails{$section}{'seedswitch'} = $values[1];
                    }
                    if($line =~ "^user") {
                        $fabricdetails{$section}{'user'} = $values[1];
                    }
                    if($line =~ "^password") {
                        $fabricdetails{$section}{'password'} = $values[1];
                    }
                    if($line =~ "^log_uports") {
                        $fabricdetails{$section}{'log_uports'} = $values[1];
                    }
                    if($line =~ "^counter_refresh_interval") {
                        $fabricdetails{$section}{'refresh_interval'} = $values[1];
                    }
                    if($line =~ "^config_refresh_interval^") {
                        $fabricdetails{$section}{'config_interval'} = $values[1];
                    }
                    if($line =~ "^metric_file") {
                        $fabricdetails{$section}{'metric_file'} = $values[1];
                    }
                    if($line =~"^ssl_verfiy_host") {
                        $fabricdetails{$section}{'ssl_verfiy_host'} = $values[1];
                    }
                }
            }           
        }
    }
}

sub readMetrics {
    my $metricfile = "";
    if(!defined($fabricdetails{$fabric}{'metric_file'})) {
        print "A metric file was not specified for ".$fabric." in ".$conf." ! Please check config file and add metric file specification.\n";
        $log->error("A metric file was not specified for ".$fabric." in ".$conf." ! Please check config file and add metric file specification.");
        exit(1);              
    } else {
        if(!-f $fabricdetails{$fabric}{'metric_file'}) {
            print "The metric file specified cannot be found. Please check config file or metric file specified: ".$fabricdetails{$fabric}{'metric_file'}."\n";
            $log->error("The metric file specified cannot be found. Please check config file or metric file specified: ".$fabricdetails{$fabric}{'metric_file'});
            exit(1);
        }
        open(my $fh,'<',$fabricdetails{$fabric}{'metric_file'}) or die "Can't open metric file $!";
        while(<$fh>) {
            my $line = $_;
            chomp $line;
            $line =~ s/\s//g;
            if($line !~ "#") {
                if($line =~ ":") {
                    my @values = split(':',$line);
                    $metrics{$values[0]} = $values[1];
                } else {
                    $metrics{$line} = $line; 
                }
            }
        }
    }
}

sub restLogin {
    my $switch = $_[0];
    my $user = $_[1];
    my $passwd = $_[2];
    $log->debug("Logging in to ".$switch." with user: ".$user);
    my $url = 'https://'.$switch.'/rest/login';
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->authorization_basic($user,$passwd);
    my $resp = $ua->request($req);
        if ($resp->is_success) {
        my $responseheader = $resp->header("Authorization");
                my $responsecontent = $resp->decoded_content;
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
    $log->debug("Logging out from ".$switch." by removing token: ".$token);
    my $url = 'https://'.$switch.'/rest/logout';
    my $req = HTTP::Request->new(POST => $url);
        $req->header('Accept' => 'application/yang-data+json');
        $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $resp = $ua->request($req);
        if ($resp->is_success) {
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
    my $req = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'application/yang-data+json');
        $req->header('Content-Type' => 'application/yang-data+json');
        $req->header('Authorization' => $token);
    my $resp = $ua->request($req);
    if ($resp->is_success) {
        my $responsecontent = $resp->decoded_content;
        #print $responsecontent."\n";
        my %json = %{decode_json($responsecontent)};
        my @fabricswitches = $json{"Response"}{"fabric-switch"};
        foreach my $fabricswitch (@fabricswitches) {
            my @singleswitches = @{$fabricswitch};
            foreach my $singleswitch (@singleswitches){
                my %switchattr = %{$singleswitch};
                print $switchattr{"switch-user-friendly-name"}."\n";
                $log->info("Discovered switch ".$switchattr{"switch-user-friendly-name"}." (".$switchattr{"ip-address"}.") as member of fabric ".$fabric);
                $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"IP"} = $switchattr{"ip-address"};
                $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"NAME"} = $switchattr{"name"};
                $fabricdetails{$fabric}{"switches"}{$switchattr{"switch-user-friendly-name"}}{"DOMAINID"} = $switchattr{"domain-id"};
            }
        }
        return($responsecontent);
    } else {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }

}

sub getFCPortCounters {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    $log->debug("Getting port counter for ".$fabric." ".$switch."!");
    my $url = 'https://'.$switch.'/rest/running/brocade-interface/fibrechannel-statistics/';
    my $req = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'application/yang-data+json');
        $req->header('Content-Type' => 'application/yang-data+json');
        $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".fibrechannel-statistics.duration ".$queryduration." ".$now;
    toGraphite($statsstring);
    if ($resp->is_success) {
        my $responsecontent = $resp->decoded_content;
        #print $responsecontent."\n";
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
                if($porttype eq "E_PORT") {
                    $porttype = $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"longdistance"};
                }   
                foreach my $keyname (keys %portattr) {
                    #if ( grep( /^$keyname$/, @metrics ) ) {
                    if (defined($metrics{$keyname})) {
                        my $metricname = $metrics{$keyname};
                        $log->trace($switch." => Name: ".$portattr{"name"}." : Key: ".$keyname." => ".$portattr{$keyname});
                        my $metricstring = "";
                        if($porttype eq "U_PORT") {
                            if($fabricdetails{$fabric}{'log_uports'}) {
                                $metricstring =  "brocade.fos.stats.ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname." ".$portattr{$keyname}." ".$now;
                                toGraphite($metricstring);
                            }
                        } else {
                            $metricstring = "brocade.fos.stats.ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname." ".$portattr{$keyname}." ".$now;
                            toGraphite($metricstring);
                        }
                    }
                }
            }
        }
    } else {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    $log->debug("Finished getting port counter for ".$fabric." ".$switch."!");
}

sub getPortSettings {
        my $fabric = $_[0];
        my $switch = $_[1];
        my $token = $_[2];
        my $url = 'https://'.$switch.'/rest/running/brocade-interface/fibrechannel/';
        my $req = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'application/yang-data+json');
        $req->header('Content-Type' => 'application/yang-data+json');
        $req->header('Authorization' => $token);
        my $querystart = int (gettimeofday * 1000);
        my $resp = $ua->request($req);
        my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
        my $now = time;
        my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".fibrechannel.duration ".$queryduration." ".$now;
        toGraphite($statsstring);
        if ($resp->is_success) {
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
                                my $porttype = $portattr{"port-type"};
                                my $longdistance = $portattr{"long-distance"};  
                                #if($porttypes{$porttype} ne "E_PORT") {
                                #   print $switch." => ".$portname." => ".$porttype."(".$porttypes{$porttype},")\n";
                                #} else {
                                #   print $switch." => ".$portname." => ".$porttype."(".$porttypes{$porttype},") => ".$longdistance."(".$distancemodes{$longdistance}.")\n";
                                #}
                                $log->debug("FCID for ".$portname." of ".$switch." is ".$portattr{"fcid-hex"});
                                $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"porttype"}=$porttypes{$porttype};
                                $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"longdistance"}=$distancemodes{$longdistance};
                                $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"fcid"} = $portattr{"fcid-hex"};
                        }
                }
        } else {
                $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
                $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
                $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
                exit(($resp->code)-100);
        }
}


sub getSystemResources {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    $log->debug("Getting system counter for ".$fabric." ".$switch."!");
    my $url = 'https://'.$switch.'/rest/running/brocade-maps/system-resources/';
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".system-resources.duration ".$queryduration." ".$now;
    toGraphite($statsstring);
    if ($resp->is_success) {
        my $responsecontent = $resp->decoded_content;
        my %json = %{decode_json($responsecontent)};
        my @systemperfcounters = $json{"Response"}{"system-resources"};
        foreach my $counters (@systemperfcounters) {
            my %counterhash = %{$counters};
            foreach my $counter (keys %counterhash) {
                $log->trace($fabric.": ".$switch." - ".$counter." = ".$counterhash{$counter});
                #if(grep( /^$counter$/, @metrics)) {
                if(defined($metrics{$counter})) {
                    my $metricname = $metrics{$counter};
                    my $metricstring = "brocade.fos.stats.switches.".$fabric.".".$switch.".".$metricname." ".$counterhash{$counter}." ".$now;
                    toGraphite($metricstring);
                }
            }   
        }
    } else {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    $log->debug("Finished getting system counter for ".$fabric." ".$switch."!");
}

sub getMediaCounters {
    my $fabric = $_[0];
    my $switch = $_[1];
    my $token = $_[2];
    $log->debug("Getting media counter for ".$fabric." ".$switch."!");
    my $url = 'https://'.$switch.'/rest/running/brocade-media/media-rdp/';
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'application/yang-data+json');
    $req->header('Content-Type' => 'application/yang-data+json');
    $req->header('Authorization' => $token);
    my $querystart = int (gettimeofday * 1000);
    my $resp = $ua->request($req);
    my $queryduration = ((int (gettimeofday * 1000)) - $querystart);
    my $now = time;
    my $statsstring = "brocade.fos2graphite.stats.query.".$switch.".brocade-media.duration ".$queryduration." ".$now;
    toGraphite($statsstring);
    if ($resp->is_success) {
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
                if($porttype eq "E_PORT") {
                    $porttype = $portsettings{$fabric}{$switch}{$slot}{$portnumber}{"longdistance"};
                }
                foreach my $metric (keys %mediaattr) {
                    #if ( grep( /^$metric$/, @metrics ) ) {
                    if ( defined($metrics{$metric})) {
                        my $metricvalue = $mediaattr{$metric};
                        my $metricstring = "";
                        my $metricname = $metrics{$metric};
                        if((!($porttype eq "U_PORT")) || $fabricdetails{$fabric}{'log_uports'}) {
                            if($metric =~ "x-power") {
                                my $dbm = 0;
                                if($metricvalue>0) {
                                    $dbm = sprintf("%.2f",(10*(log($metricvalue/1000)/log(10))));
                                }
                                $metricstring = "brocade.fos.stats.ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname."-dbm ".$dbm." ".$now;
                                toGraphite($metricstring);
                            } 
                            $metricstring = "brocade.fos.stats.ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$portnumber.".".$metricname." ".$mediaattr{$metric}." ".$now;
                            toGraphite($metricstring);
                        }
                    }
                }
            }
        }
    } else {
        $log->error("Failed to GET data from ".$url." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$url." with HTTP GET error message: ".$resp->message);
        $log->error("Exit fos2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
    $log->debug("Finished getting media counter for ".$fabric." ".$switch."!");
}

sub reportmetrics {
    my $fabric = $_[0];
    my $switch = $_[1];
    $polltime = time();
    $polltime = $polltime - ($polltime % 60);
    while(true) {
        my $curtime = time();
        if(($curtime - $polltime)>=$fabricdetails{$fabric}{'refresh_interval'}) {
            my $printtime = strftime('%m/%d/%Y %H:%M:%S',localtime($curtime));
            $log->debug("Collecting new set of data for ".$fabric." - ".$switch." at ".$printtime);
            initsocket();
            $log->info("Loging in to ".$fabric." / ".$switch);
            my $token = restLogin($switch,$fabricdetails{$fabric}{"user"},$fabricdetails{$fabric}{"password"});
            $log->info("Getting performance- and errorcounters for ".$fabric." / ".$switch);
            getSystemResources($fabric,$switch,$token);
            getPortSettings($fabric,$switch,$token);
            getFCPortCounters($fabric,$switch,$token);
            getMediaCounters($fabric,$switch,$token);
            $log->info("Logout from ".$fabric." / ".$switch);
            restLogout($switch,$token);
            $polltime = $polltime + $fabricdetails{$fabric}{'refresh_interval'};
            closesocket();
        }
        sleep(1);
    }
}


sub startreporter {
    my $fabric = $_[0];
    servicestatus('Running reporters...');
    foreach my $switch (keys $fabricdetails{$fabric}{"switches"}) {
        my $pid = fork();
        if(!$pid) {
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
                if(!$pid) {
                    reportmetrics($fabric,$switch);
                } else {
                    $pids{$switch}=$pid;
                }
            }
       }
       if($livecounter > 60) {
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
    #print $message."\n";
    $socket->send($message."\n");
    if(($socketdelay>0)&&!($socketcnt % $delaymetric)) {
        nanosleep($socketdelay);
    }
    if($socketcnt>=100000) {
        my $elapsed = tv_interval ( $sockettimer, [gettimeofday]);
        my $metricsperminute = 60/$elapsed*100000;
        if($socketdelay>0) {
            $socketdelay = int($socketdelay*($metricsperminute/$maxmetricsperminute));
            if($daemon) {
                if($socketdelay > $maxdelay) {
                    $socketdelay = $maxdelay;
                }
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
    die "cannot connect to the server $!\n" unless $socket;
    setsockopt($socket, SOL_SOCKET, SO_KEEPALIVE, 1);
    $log->debug("Opening connection ".$socket->sockhost().":".$socket->sockport()." => ".$socket->peerhost().":".$socket->peerport());
}

sub closesocket {
    $log->debug("Closing Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
    $socket->shutdown(2);
}

# Sub to initialize Systemd Service

sub initservice {
    notify( READY => 1 );
    $log->trace("Service is initialized...");
}

# Sub to update status of Systemd Service when running as Daemon

sub servicestatus {
    my $message = $_[0];
    notify( STATUS => $message );
    $log->trace("Status message: ".$message." is send to service...");
}

# Sub to signal a stop of the script to the service when running as Daemon

sub stopservice {
    notify ( STOPPING => 1 )
}

# Sub to send heartbeat wo watchdog of Systemd service when running as Daemon.

sub alive {
    notify ( WATCHDOG => 1 );
    if($loglevel eq "TRACE") {
        $log->trace("Heartbeat is send to watchdog of service...");
    }
}



parseCmdArgs();

my $log4perlConf  = qq(
log4perl.logger.main.report            = $loglevel,  FileAppndr1
log4perl.appender.FileAppndr1          = Log::Log4perl::Appender::File
log4perl.appender.FileAppndr1.filename = $logfile
#log4perl.appender.FileAppndr1.owner    = openiomon
#log4perl.appender.FileAppndr1.group    = openiomon
log4perl.appender.FileAppndr1.umask    = 0000
log4perl.appender.FileAppndr1.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.FileAppndr1.layout.ConversionPattern = %d [%p] (%F:%L) %M > %m %n
);
Log::Log4perl->init(\$log4perlConf);
$log = Log::Log4perl->get_logger('main.report');

initservice();

readMetrics();

servicestatus("Discovering fabric...");
if(fabricdetails{$fabric}{"ssl_verfiy_host"} == 0) {
    $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });
else {
    $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 1 });
}

my $token = restLogin($fabricdetails{$fabric}{"seedswitch"},$fabricdetails{$fabric}{"user"},$fabricdetails{$fabric}{"password"});

getFabricSwitches($fabric,$fabricdetails{$fabric}{"seedswitch"},$token);
restLogout($fabricdetails{$fabric}{"seedswitch"},$token);

startreporter($fabric);
checkreporter($fabric);

print "Logged out...\n";

