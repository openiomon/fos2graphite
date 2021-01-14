#!/usr/bin/env bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KEY=$(<~/.grafanakey)
HOST=$1
PATTERN=$2

if [ $# -ne 2 ] ; then
    echo "Please specify the grafana host (e.g. https://grafana.company.com:3000) directory with JSON files to import!";
    exit 1
fi

IMPORT_DIR=$2"*.json";

for files in $IMPORT_DIR;do
  curl -k -X POST -d @${files} -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" $HOST/api/dashboards/db
  echo ""
done
