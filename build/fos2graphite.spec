Summary: fos2graphite is a module of openiomon which is used to transfer statistics from the Brocade SAN swtches to a graphite system to be able to display this statistics in Grafana.
Name: fos2graphite
Version: 0.1
prefix: /opt
Release: 4
URL: http://www.openiomon.org
License: GPL
Group: Applications/Internet
BuildRoot: %{_tmppath}/%{name}-root
Source0: fos2graphite-%{version}.tar.gz
BuildArch: x86_64
AutoReqProv: no
Requires: perl(version) perl(Readonly) perl(Getopt::Long) perl(IO::Socket::INET) perl(JSON) perl(LWP::UserAgent) perl(LWP::Protocol::https) perl(Log::Log4perl) perl(POSIX) perl(Time::HiRes) perl(Time::Local) perl(constant) perl(strict) perl(warnings)



%description
Module for integration of Brocade SAN Switch performance and error statistics to Grafana. Data is queried using HTTPrest API from SAN switches and send via plain text protocol to graphite / carbon cache systems.

%pre
getent group openiomon >/dev/null || groupadd -r openiomon
getent passwd openiomon >/dev/null || \
    useradd -r -g openiomon -d /home/openiomon -s /sbin/nologin \
    -c "openiomon module daemon user" openiomon
exit 0

%prep

%setup

%build

%install
rm -rf ${RPM_BUILD_ROOT}
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/bin/
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/conf
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/log/
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/lib/
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/dashboards/
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/build/
mkdir -p ${RPM_BUILD_ROOT}/etc/logrotate.d/
install -m 655 %{_builddir}/fos2graphite-%{version}/bin/* ${RPM_BUILD_ROOT}/opt/fos2graphite/bin/
install -m 655 %{_builddir}/fos2graphite-%{version}/conf/*.conf ${RPM_BUILD_ROOT}/opt/fos2graphite/conf/
install -m 655 %{_builddir}/fos2graphite-%{version}/conf/*.example ${RPM_BUILD_ROOT}/opt/fos2graphite/conf/
install -m 655 %{_builddir}/fos2graphite-%{version}/build/fos2graphite_logrotate ${RPM_BUILD_ROOT}/etc/logrotate.d/fos2graphite
#install -m 655 %{_builddir}/fos2graphite-%{version}/lib/* ${RPM_BUILD_ROOT}/opt/fos2graphite/lib
cp -a %{_builddir}/fos2graphite-%{version}/lib/* ${RPM_BUILD_ROOT}/opt/fos2graphite/lib/
cp -a %{_builddir}/fos2graphite-%{version}/dashboards/*.json ${RPM_BUILD_ROOT}/opt/fos2graphite/dashboards/

%clean
rm -rf ${RPM_BUILD_ROOT}

%files
%config(noreplace) %attr(644,openiomon,openiomon) /opt/fos2graphite/conf/*.conf
%config(noreplace) %attr(644,root,root) /etc/logrotate.d/fos2graphite
%attr(755,openiomon,openiomon) /opt/fos2graphite/bin/*
%attr(755,openiomon,openiomon) /opt/fos2graphite/lib/perl5/
%defattr(644,openiomon,openiomon,755)
/opt/fos2graphite/conf/fos2graphite.conf.example
/opt/fos2graphite/conf/storage-schemas.conf.example
/opt/fos2graphite/dashboards/*
/opt/fos2graphite/log/



%post
ln -s -f /opt/fos2graphite/bin/fos2graphite.pl /bin/fos2graphite

%changelog
* Thu Jan 14 2021 Timo Drach <timo.drach@openiomon.org>
- Added dashboards, renamed config collection parameters
* Mon Dec 21 2020 Timo Drach <timo.drach@openiomon.org>
- Added fearures for Target / Initiator logging
* Tue Dec 15 2020 Timo Drach <timo.drach@openiomon.org>
- Initial Version for test build