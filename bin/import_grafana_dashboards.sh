#!/usr/bin/env bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KEY=$(<~/.grafanakey)
HOST=$1
DIRECTORY=$2
DATASOURCENAME=$3


# the provided dashboard JSON file format is only usable for GUI import
# These strings will be added to the curl POST request to do the API import
IMPORT_PRE_STRING='{ "dashboard": '
IMPORT_POST_STRING=', "overwrite": true }'

##
# Function definitions
##

# Function for Help output
print_help() {
    echo ""
    echo "Grafana Dashboard import script"
    echo ""
    echo "Usage"
    echo ""
    echo "1. Create a Grafana API Key and save it to ~/.grafanakey"
    echo ""
    echo "2. run script: ./import_grafana_db.sh GRAFANA-BASE-URL directory-to-import datasource-name"
    echo ""
    echo "Example: ./import_grafana_db.sh https://grafana.company.com:3000 /opt/fos2graphite/dashboards MyGraphiteDatasource"
    echo ""
    echo ""
    exit 1
} #End print_help

# Function to import dashboards into Grafana
import_dash() {
    IMPORT_DIR="${DIRECTORY}*.json";

    for files in $IMPORT_DIR;do
        #FILECONTENT=$(sed -e "s/.*\"datasource\":.*/\"datasource\": \"${DATASOURCENAME}\"\,/" ${files})
        FILECONTENT=$(sed -e "s/.*\"datasource\": \"\${.*/\"datasource\": \"${DATASOURCENAME}\"\,/" ${files})

        if [ $? -ne 0 ] ; then
            echo "modify datasource name via sed failed"
            echo ${FILECONTENT}
            echo ""
        fi

        POSTCONTENT=${IMPORT_PRE_STRING}${FILECONTENT}${IMPORT_POST_STRING}
        # DEBUG
        #echo $POSTCONTENT

        echo "importing ${files}"
        curl -k -X POST -d "${POSTCONTENT}" -H "Content-Type: application/json" -H "Authorization: Bearer ${KEY}" ${HOST}/api/dashboards/db
        echo ""
        echo ""
    done
} #Emd import_dash

##
# Main
##

if [ $# -ne 3 ] ; then
    print_help
fi

if [ -z $KEY ]; then
    echo "Grafana API Key is not in file ~/.grafanakey"
    echo ""
    exit 1
fi

import_dash