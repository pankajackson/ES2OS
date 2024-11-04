#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Load environment variables from env.sh, if available
if [ -f "./env.sh" ]; then
    source ./env.sh
fi

# Define default values from environment variable
ES_ENDPOINT="${ES_HOST:-https://es.evega.co.in}"
KB_ENDPOINT="${KB_HOST:-https://kb.jackson.com}"
ES_USERNAME="${ES_USER:-elastic}"
ES_PASSWORD="${ES_PASS:-default_elastic_password}"
DATAVIEW_API_INSECURE="${DATAVIEW_API_INSECURE:-true}"

OS_ENDPOINT="${OS_HOST:-https://localhost:9200}"
OS_USERNAME="${OS_USER:-admin}"
OS_PASSWORD="${OS_PASS:-default_admin_password}"

# Define OUTPUT_DIR and create the directory if it doesn't exist
OUTPUT_DIR="./output_files"
mkdir -p "$OUTPUT_DIR"

DATAVIEW_FILE="$OUTPUT_DIR/dataviews.json"
REPORT_FILE="$OUTPUT_DIR/dataviews_migration_report.csv"
LOGSTASH_CONF_DIR="$OUTPUT_DIR/ls_confs"
mkdir -p "$LOGSTASH_CONF_DIR"

# Boolean variable to control config cleanup
CONFIG_CLEANUP=false # Change to false if you want to skip cleanup

# Determine curl flags based on DATAVIEW_API_INSECURE setting
CURL_FLAGS=""
if [ "$DATAVIEW_API_INSECURE" = true ]; then
    CURL_FLAGS="--insecure"
fi

# Fetch data view list from API and save to file
echo "Fetching data views from $KB_ENDPOINT..."
curl -s $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" "$KB_ENDPOINT/api/data_views" -o "$DATAVIEW_FILE"

# Check if data view file was created and is not empty
if [[ ! -s "$DATAVIEW_FILE" ]]; then
    echo "No data views found or failed to fetch data views. Exiting."
    exit 1
fi

# Output the content for debugging
echo "Response from API:"
cat "$DATAVIEW_FILE"

# Initialize the report file if it doesn't exist
if [[ ! -f "$REPORT_FILE" ]]; then
    echo "Data View, Status" >"$REPORT_FILE"
fi

# Add all data views to the report with "UnProcessed" status
jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
    NAME=$(echo "$row" | jq -r '.name')
    # Initialize the report with "UnProcessed" status if not already present
    if ! grep -q "^$NAME," "$REPORT_FILE"; then
        echo "$NAME, UnProcessed" >>"$REPORT_FILE"
    fi
done

# Function to update or append status in the report file
update_report() {
    local name=$1
    local status=$2
    if grep -q "^$name," "$REPORT_FILE"; then
        # Update existing entry
        sed -i "s/^$name,.*/$name, $status/" "$REPORT_FILE"
    else
        # Append new entry
        echo "$name, $status" >>"$REPORT_FILE"
    fi
}

# Iterate over each data view, extracting title and name for processing
jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
    TITLE=$(echo "$row" | jq -r '.title')
    NAME=$(echo "$row" | jq -r '.name')

    # Check the report file for the current data view's status
    STATUS=$(grep -E "^$NAME," "$REPORT_FILE" | cut -d ',' -f2 | tr -d ' ')

    # If status is "Done" or "Skipped", skip processing
    if [[ "$STATUS" == "Done" || "$STATUS" == "Skipped" ]]; then
        echo "Data view $NAME is already processed. Skipping..."
        continue
    fi

    # Verify if the index exists in Elasticsearch
    if [[ "$IGNORE_SYSTEM_INDEXES" = true && "$TITLE" == .* ]]; then
        echo "Ignoring system index: $TITLE"
        update_report "$NAME" "Skipped"
        continue
    fi

    echo "Processing data view: $NAME (Title: $TITLE)"

    # Check if the index exists
    if ! curl -s $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" -o /dev/null -w "%{http_code}" "$ES_ENDPOINT/_cat/indices/$TITLE" | grep -q "200"; then
        echo "Index $TITLE does not exist. Skipping this data view."
        update_report "$NAME" "Skipped"
        continue
    fi

    # Sanitize TITLE to remove special characters for the filename
    # SANITIZED_TITLE=$(echo "$TITLE" | tr -cd '[:alnum:]_.-') # Allow alphanumeric, underscore, dot, and hyphen
    SANITIZED_TITLE=$(echo "$TITLE" | tr -cd '[:alnum:]') # Allow alphanumeric
    # Create a temporary Logstash configuration for the current data view
    CONFIG_FILE="$LOGSTASH_CONF_DIR/logstash_$SANITIZED_TITLE.conf"
    cat <<EOF >"$CONFIG_FILE"
input {
    elasticsearch {
        hosts => ["$ES_ENDPOINT"]
        user => "$ES_USERNAME"
        password => "$ES_PASSWORD"
        index => "$TITLE,-.*"
        query => '{ "query": { "query_string": { "query": "*" } } }'
        scroll => "5m"
        size => 500
        docinfo => true
        docinfo_target => "[@metadata][doc]"
    }
}

output {
    opensearch {
        hosts => ["$OS_ENDPOINT"]
        auth_type => {
            type => 'basic'
            user => "$OS_USERNAME"
            password => "$OS_PASSWORD"
        }
        ssl => true
        ssl_certificate_verification => false
        index => "%{[@metadata][doc][_index]}"
        document_id => "%{[@metadata][doc][_id]}"
    }
}
EOF

    echo "Logstash configuration for data view $NAME created as $CONFIG_FILE"

    # Update report file status to "InProgress"
    update_report "$NAME" "InProgress"

    # Test the Logstash configuration
    echo "Testing Logstash configuration for $NAME..."
    if sudo /usr/share/logstash/bin/logstash -f "$CONFIG_FILE" --config.test_and_exit; then
        echo "Logstash configuration for $NAME is valid."

        # Run Logstash with the generated configuration
        echo "Running Logstash for data view $NAME..."
        if sudo /usr/share/logstash/bin/logstash -f "$CONFIG_FILE"; then
            echo "Data view $NAME processed successfully."
            update_report "$NAME" "Done"
        else
            echo "Failed to process data view $NAME."
            update_report "$NAME" "Failed"
        fi
    else
        echo "Logstash configuration for $NAME is invalid."
        update_report "$NAME" "Failed"
    fi

    # Optionally remove the temporary config file after processing based on CONFIG_CLEANUP
    if [ "$CONFIG_CLEANUP" = true ]; then
        rm "$CONFIG_FILE"
    fi
done

echo "All data views processed."
