#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to set up the workstation with required applications
setup() {
    echo "Setting up the workstation..."

    # Import the GPG key for Elasticsearch
    wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -

    # Install transport package and add Elasticsearch source list
    sudo apt-get install -y apt-transport-https jq curl
    echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-7.x.list

    # Update package list and install specific version of Logstash
    sudo apt-get update
    echo "Installing Logstash version 7.13.4-1..."
    sudo apt-get install -y logstash=1:7.13.4-1

    # Install the OpenSearch output plugin for Logstash
    echo "Installing Logstash OpenSearch plugin..."
    sudo /usr/share/logstash/bin/logstash-plugin install logstash-output-opensearch

    # Verify plugin installation
    sudo /usr/share/logstash/bin/logstash-plugin list | grep opensearch && echo "OpenSearch plugin installed successfully."

    echo "Setup complete."
}

# Load environment variables and set defaults
setup_variables() {
    # Load environment variables from env.sh, if available
    if [ -f "./env.sh" ]; then
        source ./env.sh
    fi

    # Define default values for environment variables
    ES_ENDPOINT="${ES_HOST:-https://es.la.local:9200}"
    KB_ENDPOINT="${KB_HOST:-https://kb.la.local:5601}"
    ES_USERNAME="${ES_USER:-elastic}"
    ES_PASSWORD="${ES_PASS:-default_elastic_password}"
    ES_SSL="${ES_SSL:-true}"
    DATAVIEW_API_INSECURE="${DATAVIEW_API_INSECURE:-true}"

    OS_ENDPOINT="${OS_HOST:-https://os.la.local:9200}"
    OS_USERNAME="${OS_USER:-admin}"
    OS_PASSWORD="${OS_PASS:-default_admin_password}"
    OS_SSL="${OS_SSL:-true}"
    OS_SSL_CERT_VERIFY="${OS_SSL_CERT_VERIFY:-false}"

    # Define output directory and create it if it doesn't exist
    OUTPUT_DIR="./output_files"
    mkdir -p "$OUTPUT_DIR"

    DATAVIEW_FILE="$OUTPUT_DIR/dataviews.json"
    REPORT_FILE="$OUTPUT_DIR/dataviews_migration_report.csv"
    LOGSTASH_CONF_DIR="$OUTPUT_DIR/ls_confs"
    mkdir -p "$LOGSTASH_CONF_DIR"

    # Control config cleanup
    CONFIG_CLEANUP=false

    # Determine curl flags based on DATAVIEW_API_INSECURE setting
    CURL_FLAGS=""
    if [ "$DATAVIEW_API_INSECURE" = true ]; then
        CURL_FLAGS="--insecure"
    fi
}

# Sanitize name to remove special characters
sanitize_name() {
    echo "$1" | tr -cd '[:alnum:]'
}

# Fetch data views from API and save to file
fetch_dataviews() {
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
}

# Initialize report file with all data views marked as UnProcessed
generate_initial_report() {
    # Initialize the report file if it doesn't exist
    if [[ ! -f "$REPORT_FILE" ]]; then
        echo "id, Data View, Index Pattern, Status" >"$REPORT_FILE"
    fi

    # Add all data views to the report with "UnProcessed" status
    jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
        id=$(echo "$row" | jq -r '.id')
        name=$(echo "$row" | jq -r '.name')
        title=$(echo "$row" | jq -r '.title')

        if ! grep -q "^$id," "$REPORT_FILE"; then
            echo "$id, $name, $title, UnProcessed" >>"$REPORT_FILE"
        fi
    done
}

# Update or append status in the report file
update_report() {
    local id=$1
    local name=$2
    local index_pattern=$3
    local status=$4

    if grep -q "^$id," "$REPORT_FILE"; then
        sed -i "s/^$id,.*/$id, $name, $index_pattern, $status/" "$REPORT_FILE"
    else
        echo "$id, $name, $index_pattern, $status" >>"$REPORT_FILE"
    fi
}

# Verify if the data view should be processed or skipped
verify_dataview() {
    local id=$1
    local name=$2
    local title=$3

    # Check the report file for the current data view's status
    local status=$(grep -E "^$id," "$REPORT_FILE" | cut -d ',' -f4 | tr -d ' ')

    # If status is "Done" or "Skipped", skip processing
    if [[ "$status" == "Done" || "$status" == "Skipped" ]]; then
        echo "Data view $name is already processed. Skipping..."
        return 1
    fi

    # Skip system indexes if configured to do so
    if [[ "$IGNORE_SYSTEM_INDEXES" = true && "$title" == .* ]]; then
        echo "Ignoring system index: $title"
        update_report "$id" "$name" "$title" "Skipped"
        return 1
    fi

    # Check if the index exists
    if ! curl -s $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" -o /dev/null -w "%{http_code}" "$ES_ENDPOINT/_cat/indices/$title" | grep -q "200"; then
        echo "Index $title does not exist. Skipping this data view."
        update_report "$id" "$name" "$title" "Skipped"
        return 1
    fi

    return 0
}

# Process individual data view with Logstash
process_dataview() {
    local id=$1
    local name=$2
    local title=$3

    echo "Processing data view: $name (Index Pattern: $title)"

    # Sanitize title for the config filename
    local sanitized_title=$(sanitize_name "$title")
    local config_file="$LOGSTASH_CONF_DIR/logstash_$sanitized_title.conf"

    # Generate Logstash configuration for the current data view
    cat <<EOF >"$config_file"
input {
    elasticsearch {
        hosts => ["${ES_ENDPOINT#https://}"]
        user => "\${ES_USERNAME}"
        ssl => $ES_SSL
        password => "\${ES_PASSWORD}"
        index => "$title,-.*"
        query => '{ "query": { "query_string": { "query": "*" } } }'
        scroll => "5m"
        size => 2000
        docinfo => true
        docinfo_target => "[@metadata][doc]"
    }
}

output {
    opensearch {
        hosts => ["$OS_ENDPOINT"]
        auth_type => {
            type => 'basic'
            user => "\${OS_USERNAME}"
            password => "\${OS_PASSWORD}"
        }
        ssl => $OS_SSL
        ssl_certificate_verification => $OS_SSL_CERT_VERIFY
        index => "%{[@metadata][doc][_index]}"
        document_id => "%{[@metadata][doc][_id]}"
    }
}
EOF

    echo "Logstash configuration for data view $name created as $config_file"

    # Update report file status to "InProgress"
    update_report "$id" "$name" "$title" "InProgress"

    # Set environment variables for Logstash
    export ES_USERNAME="$ES_USERNAME"
    export ES_PASSWORD="$ES_PASSWORD"
    export OS_USERNAME="$OS_USERNAME"
    export OS_PASSWORD="$OS_PASSWORD"

    # Test the Logstash configuration
    echo "Testing Logstash configuration for $name..."
    if sudo -E /usr/share/logstash/bin/logstash -f "$config_file" --config.test_and_exit; then
        echo "Logstash configuration for $name is valid."

        # Run Logstash
        echo "Running Logstash for data view $name..."
        if sudo -E /usr/share/logstash/bin/logstash -f "$config_file"; then
            echo "Data view $name processed successfully."
            update_report "$id" "$name" "$title" "Done"
        else
            echo "Failed to process data view $name."
            update_report "$id" "$name" "$title" "Failed"
        fi
    else
        echo "Logstash configuration for $name is invalid."
        update_report "$id" "$name" "$title" "Failed"
    fi

    # Remove config if CONFIG_CLEANUP is true
    if [ "$CONFIG_CLEANUP" = true ]; then
        rm "$config_file"
    fi
}

# Main function to run the steps in sequence
main() {
    if [ "$1" == "setup" ]; then
        setup
        exit 0
    fi

    setup_variables
    fetch_dataviews
    generate_initial_report

    # Process each data view
    jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
        id=$(echo "$row" | jq -r '.id')
        title=$(echo "$row" | jq -r '.title')
        name=$(echo "$row" | jq -r '.name')

        if verify_dataview "$id" "$name" "$title"; then
            process_dataview "$id" "$name" "$title"
        fi
    done

    echo "All data views processed."
}

# Run the main function
main "$@"
