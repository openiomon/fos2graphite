#!/usr/bin/env bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATASOURCENAME=$1
DIRECTORY=$2

if [ $# -ne 2 ] ; then
    echo "Please specify the new datasource name and the directory containing the JSON dashboard files..."; 
    exit 1
fi

IMPORT_DIR=$2"*.json";

for files in $IMPORT_DIR;do
  sed -e "s/.*\"datasource\".*/\"datasource\": \"$DATASOURCENAME\"\,/" $files | json_reformat > $files.new
  mv -f $files.new $files
  echo "Datasource was updated in file: $files"
done
