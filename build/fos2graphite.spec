Summary: fos2graphite is a module of openiomon which is used to transfer statistics from the Brocade SAN swtches to a graphite system to be able to display this statistics in Grafana.
Name: fos2graphite
Version: 0.3.1
prefix: /opt
Release: 1
URL: https://github.com/openiomon/%{name}
License: GPL
Group: Applications/Internet
Source0: https://github.com/openiomon/%{name}/%{name}-%{version}.tar.gz
BuildArch: noarch
AutoReqProv: no
Requires: perl(Getopt::Long) perl(IO::Socket::INET) perl(IO::Socket::UNIX) perl(JSON) perl(LWP::UserAgent) perl(LWP::Protocol::https) perl(Log::Log4perl) perl(POSIX) perl(Time::HiRes) perl(Time::Local) perl(constant) perl(strict) perl(version) perl(warnings)


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
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/dashboards/graphite
mkdir -p ${RPM_BUILD_ROOT}/opt/fos2graphite/dashboards/prometheus
mkdir -p ${RPM_BUILD_ROOT}/etc/logrotate.d/
install -m 655 %{_builddir}/fos2graphite-%{version}/bin/* ${RPM_BUILD_ROOT}/opt/fos2graphite/bin/
install -m 655 %{_builddir}/fos2graphite-%{version}/conf/*.conf ${RPM_BUILD_ROOT}/opt/fos2graphite/conf/
install -m 655 %{_builddir}/fos2graphite-%{version}/conf/*.example ${RPM_BUILD_ROOT}/opt/fos2graphite/conf/
install -m 655 %{_builddir}/fos2graphite-%{version}/build/fos2graphite_logrotate ${RPM_BUILD_ROOT}/etc/logrotate.d/fos2graphite
cp -a %{_builddir}/fos2graphite-%{version}/dashboards/graphite/*.json ${RPM_BUILD_ROOT}/opt/fos2graphite/dashboards/graphite
cp -a %{_builddir}/fos2graphite-%{version}/dashboards/prometheus/*.json ${RPM_BUILD_ROOT}/opt/fos2graphite/dashboards/prometheus

%clean
rm -rf ${RPM_BUILD_ROOT}

%files
%config(noreplace) %attr(644,openiomon,openiomon) /opt/fos2graphite/conf/*.conf
%config(noreplace) %attr(644,root,root) /etc/logrotate.d/fos2graphite
%attr(755,openiomon,openiomon) /opt/fos2graphite/bin/*
%defattr(644,openiomon,openiomon,755)
/opt/fos2graphite/conf/fos2graphite.conf.example
/opt/fos2graphite/conf/storage-schemas.conf.example
/opt/fos2graphite/dashboards/graphite/*
/opt/fos2graphite/dashboards/prometheus/*
/opt/fos2graphite/log/

%post
ln -s -f /opt/fos2graphite/bin/fos2graphite.pl /bin/fos2graphite

%changelog
* Wed Jan 25 2023 Timo Drach <timo.drach@openiomon.org>
- corrected package versioning scheme
* Thu Jan 19 2023 Timo Drach <timo.drach@openiomon.org>
- remove perl lib from package
- added dependency to Perl IO::Socket::UNIX
* Tue Dec 15 2020 Timo Drach <timo.drach@openiomon.org>
- Initial Version for test build
