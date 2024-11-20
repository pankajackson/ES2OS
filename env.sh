#!/bin/bash

ES_HOST="https://es.la.local:9200"
KB_HOST="https://kb.la.local:5601"
ES_USER="elastic"
ES_PASS="elastic"
ES_SSL=true
# ES_CA_FILE="/home/jackson/empty-ca.pem"
ES_BATCH_SIZE=2000
DATAVIEW_API_INSECURE=true

OS_HOST="https://os.la.local:9200"
OS_USER="admin"
OS_PASS="admin"
OS_SSL=true
# OS_CA_FILE="/home/jackson/empty-ca.pem"
OS_SSL_CERT_VERIFY=false

CONCURRENCY=4
CONFIG_CLEANUP=false
DEBUG=false
EXCLUDE_PATTERNS=""
LS_BATCH_SIZE=125
# LS_JAVA_OPTS="-Xms1g -Xmx1g"
OUTPUT_DIR="./output_files"
INSTANCE_COUNT=2
INSTANCE_ID=1