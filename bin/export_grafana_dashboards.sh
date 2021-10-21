#!/usr/bin/env bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KEY=$(<~/.grafanakey)
HOST=$1
PATTERN=$2

if [ ! -d $SCRIPT_DIR/dashboards ] ; then
    mkdir -p $SCRIPT_DIR/dashboards
fi

if [ $# -ne 2 ] ; then
    echo "Please specify the host URL (e.g. http://grafana.company.com:3000/) and dashboard search pattern (e.g get_grafana_db.sh HDS)"
    exit 1
fi


for dash in $(curl -k -H "Authorization: Bearer ${KEY}" ${HOST}/api/search?query=$PATTERN | sed s/\"uri\":\"/\"uri\":\"\\n/g | grep db | sed s/\"//g | awk -F "," '{print $1}'); do
  curl -k -H "Authorization: Bearer $KEY" $HOST/api/dashboards/$dash | sed 's/"id":[0-9]\+,/"id":null,/' | sed 's/\(.*\)}/\1,"overwrite": true}/' | json_reformat > dashboards/$(echo ${dash} |cut -d\" -f 4 |cut -d\/ -f2).json
  echo ""
done
