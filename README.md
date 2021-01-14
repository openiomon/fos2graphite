# Table of Contents

* [Features](#features)
* [Installation](#installation)
* [Configuration](#configuration)
* [Changelog](#changelog)
* [Disclaimer](#disclaimer)

# fos2graphite

A tool to retrieve Broadcom (former Brocade) SAN Switch Performance counters from the SAN switches / directors using REST API and write them to a Carbon/Graphite backend.
* Written in Perl.
* tested on RHEL / CentOS 7
* works with FOS 8.2.x
* RPM package available

## Features
* Add one or more fabrics by specifying the seed switch to the configuration file
* configurable polling interval
* configurable metrics
* Workers run as systemd service

## Installation
Install on RHEL via RPM package: `yum install fos2graphite-0.x-x.rpm`

Perl dependencies that are not available in RHEL / CentOS 7 repositories:
* Log::Log4perl (RPM perl-Log-Log4perl available in [EPEL repository](https://fedoraproject.org/wiki/EPEL))
* Systemd::Daemon (included in the release package, [view in CPAN](https://metacpan.org/pod/Systemd::Daemon))

For other Linux distributions you can just clone the repository. Default installation folder is `/opt/fos2graphite`. The service operates with a user called "openiomon"

## Configuration
1. Edit the `/opt/bna2graphite/conf/fos2graphite.conf`, settings you have to edit for a start:

* Specify the connection to your carbon/graphite backend  
`[graphite]`  
`host = 127.0.0.1`  
`port = 2003`  

* Specifiy each fabric that should be polled  
`[<Fabricname>]`  
IP or DNS name of seed switch to be used to discover fabric  
`seedswitch = 192.168.1.2`  
User and password used for all switches of fabric  
`user = restuser`  
`password = restpasswd`  
Enable (1) or disable (0) logging of counter from offline ports  
`collect_uports = 0`  
Interval in seconds used for querying counter  
`counter_refresh_interval = 60`  
Interval in seconds used for querying changes in fabric and discovery of end devices  
`config_refresh_interval = 900`  
Metric configuration file containing metrics to be imported  
`metric_file = /opt/fos2graphite/conf/metrics.conf`  
Option to enable (1) or disable (0) SSL certificate verification  
`ssl_verfiy_host = 1`  
Option to enable collection of statistics for Initiators and Targets!  
none - no collection  
alias - collection based on zoning alias names of WWPNs  
wwpn - collection based on WWPNs  
`IT_collection = alias`  

2. Create a service
`/opt/fos2graphite/bin/fos2graphite.pl -register <fabricname>`

3. Enable the service
`/opt/fos2graphite/bin/fos2graphite.pl -enable <fabricname>`

4. Start the service
`/opt/fos2graphite/bin/fos2graphite.pl -start <fabricname>`

## Changelog

### 0.1.4
* First public release

# Disclaimer
This source and the whole package comes without warranty. It may or may not harm your computer. Please use with care. Any damage cannot be related back to the author.

