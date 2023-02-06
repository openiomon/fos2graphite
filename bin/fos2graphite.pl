#!/usr/bin/perl
### =============================================================================
###
###  File Name        : fos2graphite.pl
###
###  Project Name     : Brocade Grafana
###
###  Author           : Timo Drach
###
###  Platform         : Linux Perl
###
###  Initially written: 08.05.2019
###
###  Description      : Script for import of performance and error counter of Brocade SAN Switches
###                     via RestAPI.
###
### ==============================================================================================

use strict;
use warnings;
use v5.10;
use feature qw( switch );
no if $] >= 5.018, warnings => qw( experimental::smartmatch );

use constant false => 0;
use constant true  => 1;
use Log::Log4perl;
use Getopt::Long;

my $serviceuser = 'openiomon';
my $servicegroup = 'openiomon';
my $watchdog = 300;
my $libdir = "/opt/fos2graphite/lib/";
my $workdir = "/opt/fos2graphite/";
my $stdoutopt = 'journal';
my $stderropt = 'journal';

my $conf = '/opt/fos2graphite/conf/fos2graphite.conf';

my $register = "";
my $deregister = "";
my $enable = "";
my $disable = "";
my $start = "";
my $stop = "";
my $status = "";
my $restart = "";

my $logfile = '/opt/fos2graphite/log/fos2graphite.log';
my $loglevel = 'INFO';
my $log;

my %fabricdetails;

sub console {
    my $message = shift;
    print $message,"\n";
    $log->info($message);
}

sub printUsage {
    print("Usage:\n");
    print("$0 [OPTIONS]\n");
    print("OPTIONS:\n");
    print("   -conf <file>                  conf file containig parameter for the services\n");
    print("   -register <fabric|ALL>        Resister a systemd service for datacolection of the specified fabric\n");
    print("   -deregister <fabric|ALL>      Deresister a systemd service for datacolection of the specified fabric\n");
    print("   -enable <fabric|ALL>          Enable a systemd service for datacolection of the specified fabric\n");
    print("   -disable <fabric|ALL>         Disable a systemd service for datacolection of the specified fabric\n");
    print("   -start <fabric|ALL>           Start the service for datacolection of the specified fabric\n");
    print("   -stop <fabric|ALL>            Stop the service for datacolection of the specified fabric\n");
    print("   -restart <fabric|ALL>         Restart the service for datacolection of the specified fabric\n");
    print("   -status <fabric|ALL>          Display the status of the service for datacolection of the specified fabric\n");
    print("   -h                            print this output\n");
    print("\n");
}

sub parseCmdArgs {
    my $help = "";
    GetOptions (    "conf=s"            => \$conf,              # String
                    "register=s"        => \$register,          # String
                    "deregister=s"      => \$deregister,        # String
                    "enable=s"          => \$enable,            # String
                    "disable=s"         => \$disable,           # String
                    "start=s"           => \$start,             # String
                    "stop=s"            => \$stop,              # String
                    "restart=s"         => \$restart,           # String
                    "status=s"          => \$status,            # String
                    "h"                 => \$help)              # flag
    or die("Error in command line arguments\n");

    if ($help) {
        printUsage();
        exit(0);
    }

    if (!-f $conf) {
        print "Configuration file: ".$conf." cannot be found! Please specify configuration file!\n\n";
        printUsage();
        exit(1);
    } else {
        readconfig();
    }

    if (($register eq "") && ($deregister eq "") && ($enable eq "") && ($disable eq "") && ($start eq "") && ($stop eq "") && ($restart eq "") && ($status eq "") ) {
        printUsage();
        exit(1);
    }

    if (($register ne "") && ($deregister ne "")) {
        print "Cannot register and deregister service at the same time!\n";
        exit(1);
    }

    if (($enable ne "") && ($disable ne "")) {
        print "Cannot enable and disable service at the same time!\n";
        exit(1);
    }

    if (($start ne "") && ($stop ne "")) {
        print "Cannot start and stop service at the same time!\n";
        exit(1);
    }

    if (($start ne "") && ($restart ne "")) {
        print "Cannot start and restart service at the same time!\n";
        exit(1);
    }

    if (($stop ne "") && ($restart ne "")) {
        print "Cannot stop and restart service at the same time!\n";
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
                    $logfile = $logdir.'fos2graphite.log';
                }
                if ($line =~"^loglevel") {
                    my @values = split("=",$line);
                    $loglevel = $values[1];
                }
            }
            when('graphite') {
                # Information is not needed in service wrapper!
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
                if ($line =~ "^log_uports") {
                    $fabricdetails{$section}{'log_uports'} = $values[1];
                }
                if ($line =~ "^counter_refresh_interval") {
                    $fabricdetails{$section}{'refresh_interval'} = $values[1];
                }
                if ($line =~ "^config_refresh_interval^") {
                    $fabricdetails{$section}{'config_interval'} = $values[1];
                }
                if ($line =~ "^metric_file") {
                    $fabricdetails{$section}{'metric_file'} = $values[1];
                }
            }
        }
    }
}

sub reloadsystemctl {
    console("Reloading systemctl daemon...");
    my $rc = system('systemctl daemon-reload');
    if ($rc != 0) {
        console("Reload of systemctl daemon with command systemctl daemon-reload was not successful! Please ivenstigate!");
    } else {
        console("Reload was done successful!");
    }
}

sub registerservice {
    my $fabric = $_[0];
    if ($fabric eq 'ALL') {
        foreach my $fabric (sort keys %fabricdetails) {
            registerservice($fabric);
        }
    } else {
        if (!defined $fabricdetails{$fabric}) {
            console("Fabric ".$fabric." cannot be found of configuration file ".$conf." ! Please check configuration file and add fabric information!");
            exit(1);
        }
        console("Registering service for ".$fabric);
        my $servicefile = '/etc/systemd/system/fos2graphite-'.$fabric.'.service';
        if (-f $servicefile) {
            console("There is already a service with the name fos2graphite-".$fabric." registerd. You can either start, stop or restart the service. For updates to servicefile please deregister an register again.");
        } else {

            my $sfh;
            open $sfh, '>', $servicefile or die "Can't open file: $!";

            print $sfh "[Unit]\n";
            print $sfh "Description=FOS2GRAPHITE Service for ".$fabric."\n";
            print $sfh "Documentation=http://www.openiomon.org\n";
            print $sfh "Wants=network-online.target\n";
            print $sfh "After=network-online.target\n";
            print $sfh "After=go-carbon.service\n\n";
            print $sfh "[Service]\n";
            print $sfh "User=".$serviceuser."\n";
            print $sfh "Group=".$servicegroup."\n";
            print $sfh "Type=notify\n";
            print $sfh "Restart=always\n";
            print $sfh "RestartSec=30\n";
            print $sfh "WatchdogSec=".$watchdog."\n";
            print $sfh "WorkingDirectory=".$workdir."\n";
            print $sfh "RuntimeDirectoryMode=0750\n";
            print $sfh "StandardOutput=".$stdoutopt."\n";
            print $sfh "StandardError=".$stderropt."\n";
            print $sfh "ExecStart=".$workdir."bin/fos2graphite-worker.pl\t\t\t\\\n";
            print $sfh "\t\t-conf ".$workdir."conf/fos2graphite.conf\t\\\n";
            print $sfh "\t\t-fabric ".$fabric."\t\t\t\t\n";
            print $sfh "[Install]\n";
            print $sfh "WantedBy=multi-user.target\n";
            close($sfh);
            console("Servicefile: ".$servicefile." has been created!");
        }
    }
}

sub deregisterservice {
    my $fabric = $_[0];
    if ($fabric eq 'ALL') {
        foreach my $fabric (sort keys %fabricdetails) {
            deregisterservice($fabric);
        }
    } else {
        console("Trying to deregister service for fabric ".$fabric."...");
        if (!-f '/etc/systemd/system/fos2graphite-'.$fabric.'.service'){
            console("There is no service registered for fabric ".$fabric."! Nothing to do...");
            return(0);
        }
        service($fabric,'stop');
        service($fabric,'disable');
        unlink '/etc/systemd/system/fos2graphite-'.$fabric.'.service';
        $log->debug("Executed unlink for file /dev/systemd/system/fos2graphite-".$fabric.".service");
        console("Service for fabric ".$fabric." has been deregistered!");
    }
}

sub servicestatus {
    my $fabric = $_[0];
    $log->debug("Query service status for ".$fabric);
    if ($fabric eq 'ALL') {
        foreach my $fabric (sort keys %fabricdetails) {
            servicestatus($fabric);
        }
    } else {
        if (!-f '/etc/systemd/system/fos2graphite-'.$fabric.'.service') {
            console("There is not service registered for ".$fabric."! Please register service using fos2graphite -register ".$fabric);
            return(0);
        } else {
            my $servicecmd = 'systemctl status fos2graphite-'.$fabric;
            my @result = `$servicecmd`;
            $log->debug("Execute: ".$servicecmd." with result: ");
            foreach my $line (@result) {
                chomp $line;
                if ($line =~ ".service - FOS2GRAPHITE Service") {
                    $line = substr($line,4);
                }
                print $line."\n";
                $log->debug($line);
            }
            print "\n";
        } 
    }
}

sub service {
    my $fabric = $_[0];
    my $action = $_[1];
    if ($fabric eq 'ALL') {
        foreach my $fabric (sort keys %fabricdetails) {
            service($fabric,$action);
        }
    } else {
        console("Trying to ".$action." service for fabric ".$fabric."...");
        if (!-f '/etc/systemd/system/fos2graphite-'.$fabric.'.service'){
            console("\tService cannot be found for fabric ".$fabric.". Please register service or correct defined fabrics or verify configuration file!");
            return(0);
        }
        my $cmd = 'systemctl '.$action.' fos2graphite-'.$fabric.' > /dev/null 2>&1';
        $log->debug("Running system command: ".$cmd);
        my $rc = system($cmd);
        if ($rc==0) {
            console("Service ".$action."ed for fabric ".$fabric."!");
        } else {
            console("Failed to ".$action." service for fabric ".$fabric."! Please investigate!");
        }
    }
}

# MAIN
parseCmdArgs();

my $log4perlConf  = qq(
log4perl.logger.main.report            = $loglevel,  FileAppndr1
log4perl.appender.FileAppndr1          = Log::Log4perl::Appender::File
log4perl.appender.FileAppndr1.filename = $logfile
log4perl.appender.FileAppndr1.owner    = $serviceuser
log4perl.appender.FileAppndr1.group    = $servicegroup
log4perl.appender.FileAppndr1.umask    = 0022
log4perl.appender.FileAppndr1.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.FileAppndr1.layout.ConversionPattern = %d [%p] (%F:%L) %M > %m %n
);
Log::Log4perl->init(\$log4perlConf);
$log = Log::Log4perl->get_logger('main.report');

if ($register ne "") {
    registerservice($register);
    reloadsystemctl();
}

if ($deregister ne "") {
    deregisterservice($deregister);
    reloadsystemctl();
}

if ($status ne "") {
    servicestatus($status);
}

if ($start ne "") {
    service($start,'start');
}

if ($stop ne "") {
    service($stop,'stop');
}

if ($restart ne "") {
    service($restart,'restart');
}

if ($enable ne "") {
    service($enable,'enable');
}

if ($disable ne "") {
    service($disable,'disable');
}