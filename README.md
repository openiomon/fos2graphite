# Table of Contents

* [Features](#features)
* [Installation](#installation)
* [Configuration](#configuration)
* [Dashboard import](#dashboard-import)
* [Changelog](#changelog)
* [Disclaimer](#disclaimer)

# fos2graphite

A tool to retrieve Broadcom (former Brocade) SAN Switch Performance counters from the SAN switches / directors using REST API and write them to a Carbon/Graphite backend.
* Written in Perl.
* tested on RHEL / CentOS 7 & 8
* works with FOS 8.2.x & 9.1.x
* RPM package available

## Features
* Add one or more fabrics by specifying the seed switch to the configuration file
* configurable polling interval
* configurable metrics
* Workers run as systemd service
* supports credential provider integration

## Installation
Install on RHEL via RPM package: `yum install fos2graphite-0.x-x.rpm`

Perl dependencies that are not available in RHEL / CentOS repositories:
* Log::Log4perl (RPM perl-Log-Log4perl available in [EPEL repository](https://fedoraproject.org/wiki/EPEL))

For other Linux distributions you can just clone the repository. Default installation folder is `/opt/fos2graphite`. The service operates with a user called "openiomon"

**SElinux Note**
If you use SElinux in enforcing mode, you need to set the context for the log directory manually. Otherwise logrotate will fail. Use the following commands:
```
semanage fcontext -a -t var_log_t "/opt/fos2graphite/log(/.*)?"
restorecon -Rv /opt/fos2graphite/log/
```

## Configuration
1. Edit the `/opt/bna2graphite/conf/fos2graphite.conf`, settings you have to edit for a start:

* Specify the connection to your carbon/graphite backend  
`[graphite]`   
`host = 127.0.0.1`  
`port = 2003`  
Option to selet the metric format  
graphite-dot - Classic graphite/carbon format, Example: "brocade.fos.switch.NAME.metric"  
graphite-tag - Tag style format, tested with [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics), Example: "my_series;tag1=value1;tag2=value2"  
`metric_format = graphite-dot`   

* Specifiy each fabric that should be polled  
`[<Fabricname>]`  
IP or DNS name of seed switch to be used to discover fabric  
`seedswitch = 192.168.1.2`  
User and password used for all switches of fabric  
`user = restuser`  
`password = restpasswd`  
Enable (1) or disable (0) logging of counter from offline ports  
`collect_uports = 0`  
Interval used for querying counters marked as performance counters in mertics.conf  
`perf_refresh_interval = 1m`  
Interval used for querying counters marked as stats counters in mertics.conf  
`stats_refresh_interval = 5m`  
Interval used for querying changes in fabric and discovery of end devices  
`config_refresh_interval = 15m`  
Metric configuration file containing metrics to be imported  
`metric_file = /opt/fos2graphite/conf/metrics.conf`  
Option to enable (1) or disable (0) SSL certificate verification  
`ssl_verfiy_host = 1`  
Option to enable collection of statistics for Initiators and Targets!  
none - no collection  
alias - collection based on zoning alias names of WWPNs  
wwpn - collection based on WWPNs  
`IT_collection = alias`  

Option to specify offset in seconds (between 0 and 30) to the full minute to start polling of the fabric
Can be used to avoid collision with other tools polling switches every full minute
Can also be used to reduce load to carbon by usings different settings for each fabric  
`refresh_offset = 0`

fos2graphite has an option to monitor virtual fabrics. In this case a full section need to be defined for each individual virtual fabric!
The virtual fabric is specified by defining the vFID of the virtual switch switch off the vFabric on the defined seed switch.  
`vFID = 10`

Since a single pyhsical switch can contain multiple virtual / logical switches it is possible to define if switch hardware infos (CPU, Flash, Mem) should be monitored through the virtual switch to avoid collecting information for one hardware multiple times through als virtual switches. To enable (1) or disable (0).  
`monitor_switchhardware = 0`

Credential Provider can be used instead of password. Allows usage of Privileged Access Management solutions like CyberArk.
The script will be called with switch DNS name as first and username as second parameter.  
Example: `./your_credential_script.sh brocade1.local restuser`  
Credential Provider Script location   
`credential_provider_script = /usr/local/bin/your_credential_script.sh`  
Timeout for the credential provider script call  
`credential_provider_retrievetimeout = 20s`  
Password will be cached for the amount of time specified  
`credential_provider_cachetimeout = 24h`  

2. Create a service
`/opt/fos2graphite/bin/fos2graphite.pl -register <fabricname>`   

3. Enable the service
`/opt/fos2graphite/bin/fos2graphite.pl -enable <fabricname>`   

4. Start the service
`/opt/fos2graphite/bin/fos2graphite.pl -start <fabricname>`   

## Dashboard import
The provided dashboard json files can be imported one by one via the Grafana GUI [Dashboards -> Manage -> Import](https://grafana.com/docs/grafana/latest/dashboards/export-import/)

Alternatively, there is a simple shell script to import all dashboards at once.
1. Create an [Grafana API Key](https://grafana.com/docs/grafana/latest/http_api/auth/) and save it in `~/.grafanakey`

2. Execute the script `/opt/fos2graphite/bin/import_grafana_dashboards.sh` with the following options
   1. Base URL to your Grafana instance
   2. the directory of the json files
   3. the data source name
   
   Example:  
   `/opt/fos2graphite/bin/import_grafana_dashboards.sh https://grafana.company.com:3000 /opt/fos2graphite/dashboards/graphite MyGraphiteDatasource`  

## Changelog
### 0.4.0
* add credential provider support
* add support for FOS 9.1
* add REST API logout when hitting "die" conditions
* improved virtual fabric support to allow mix of vf-enabled and vf-disabled switches in a fabric
* fix illegal characters for graphite line protocol
* update dashboards to Grafana 10

### 0.3.1
* fix virtual fabric support, was broken in 0.3.0
 
### 0.3.0
* add REST API logout when systemd service is stopped gracefully
* add port speed collection to allow calculation of port usage
* add port usage percent counter to ISL dashboard
* fix media counters missing for initiator-target collection
* change file permissions for log files, set to 644 instead of 666
* change graphite metric names / prometheus label names for query duration meta information (due to internal code changes)
* change query duration values to microseconds
* add/change fos2graphite statistics dashboards to use new metric names

### 0.2.1
* fix bugs for datasource renaming in import script
* fix initialization of sockettimer in RHEL8
* change systemd service configuration to log output in journal

### 0.2.0
* Added support for RHEL 8
* removed dependency to Perl module Systemd::Daemon
* log worker die message during graphite socket init

### 0.1.9
* workaround for invalid JSON response in FOS9 name-server query

### 0.1.8
* skip Alias query when "IT_collection" Parameter is set to "WWPN"

### 0.1.7
* Added PromQL dashboards (tested with VictoriaMetrics)
* reworked dashboard import function

### 0.1.6
* Added support for vFabric using vFID Parameters
* Added support for graphite-tag format to be used with Virtoria Metrics backend

### 0.1.4
* First public release

# Disclaimer
This source and the whole package comes without warranty. It may or may not harm your computer. Please use with care. Any damage cannot be related back to the author.

