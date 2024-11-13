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
    local env_file_path="${1:-./env.sh}"

    # Load environment variables from the specified env.sh path, if available
    if [ -f "$env_file_path" ]; then
        echo "Loading environment variables from $env_file_path..."
        source "$env_file_path"
    else
        echo "Warning: Environment file $env_file_path not found. Using default values."
    fi

    # Define default values for environment variables
    ES_ENDPOINT="${ES_HOST:-https://es.la.local:9200}"
    KB_ENDPOINT="${KB_HOST:-https://kb.la.local:5601}"
    ES_USERNAME="${ES_USER:-elastic}"
    ES_PASSWORD="${ES_PASS:-default_elastic_password}"
    ES_SSL="${ES_SSL:-true}"
    ES_CA_FILE="${ES_CA_FILE:-}"
    DATAVIEW_API_INSECURE="${DATAVIEW_API_INSECURE:-true}"

    OS_ENDPOINT="${OS_HOST:-https://os.la.local:9200}"
    OS_USERNAME="${OS_USER:-admin}"
    OS_PASSWORD="${OS_PASS:-default_admin_password}"
    OS_SSL="${OS_SSL:-true}"
    OS_SSL_CERT_VERIFY="${OS_SSL_CERT_VERIFY:-false}"

    # Define output directory and create it if it doesn't exist
    OUTPUT_DIR="${OUTPUT_DIR:-./output_files}"
    mkdir -p "$OUTPUT_DIR"

    DATAVIEW_DIR="$OUTPUT_DIR/dataviews"
    mkdir -p "$DATAVIEW_DIR"
    DATAVIEW_FILE="$DATAVIEW_DIR/dataviews.json"
    REPORT_FILE="$DATAVIEW_DIR/dataviews_migration_report.csv"

    INDICES_DIR="$DATAVIEW_DIR/indices"
    mkdir -p "$INDICES_DIR"
    INDICES_REPORT_FILE="$INDICES_DIR/indices_migration_report.csv"

    LOGSTASH_CONF_DIR="$OUTPUT_DIR/logstash"
    mkdir -p "$LOGSTASH_CONF_DIR"

    DASHBOARD_DIR="$OUTPUT_DIR/dashboards"
    mkdir -p "$DASHBOARD_DIR"

    # Control config cleanup
    CONFIG_CLEANUP="${CONFIG_CLEANUP:-false}"

    # Set DEBUG to false by default
    DEBUG="${DEBUG:-false}"

    # Set batch for data migration, 2000 is default
    BATCH_SIZE="${BATCH_SIZE:-2000}"

    # Determine curl flags based on DATAVIEW_API_INSECURE setting
    CURL_FLAGS=""
    if [ "$DATAVIEW_API_INSECURE" = true ]; then
        CURL_FLAGS="--insecure"
    fi
}

# Sanitize name to remove special characters
sanitize_name() {
    replacer_char='_'
    input=$(echo "$1" | sed 's/^ *//;s/ *$//')
    sanitized=$(echo "$input" | tr -c '[:alnum:]_-' "$replacer_char")
    echo "$sanitized"
}

# Fetch data views from API and save to file
get_dashboards() {
    echo "Fetching data views from $KB_ENDPOINT..."

    DASHBOARD_FILE="$DASHBOARD_DIR/dashboards.json"
    curl -s $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" "$KB_ENDPOINT/api/saved_objects/_find?type=dashboard&per_page=10000" -o "$DASHBOARD_FILE"

    # Check if data view file was created and is not empty
    if [[ ! -s "$DASHBOARD_FILE" ]]; then
        echo "No dashboard found or failed to fetch dashboards. Exiting."
        exit 1
    fi

    # Output the content for debugging
    echo "Response from API:"
    cat "$DASHBOARD_FILE"
    echo ""
    echo "Total Dashboards found:" "$(jq -c '.total' "$DASHBOARD_FILE")"
    jq -c '.saved_objects[]' "$DASHBOARD_FILE" | while read -r row; do
        id=$(echo "$row" | jq -r '.id')
        title=$(echo "$row" | jq -r '.attributes.title')
        sanitized_dashboard_file_name=$(sanitize_name "$title-$id")
        dashboard_file=$DASHBOARD_DIR/$sanitized_dashboard_file_name.ndjson
        echo "Exporting dashboard: $id $title: $dashboard_file"

        # Export each dashboard to a separate ndjson file
        curl -s $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" "$KB_ENDPOINT/api/saved_objects/_export" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d '{
            "objects": [{"type": "dashboard", "id": "'"$id"'"}],
            "includeReferencesDeep": true
        }' >"$dashboard_file"
    done

    echo "Dashboard export completed. Files are in the $DASHBOARD_DIR directory."

}

logstash_cleanup() {
    local uuid=$1
    local index=$2

    # Sanitize index for the config filename
    local sanitized_index=$(sanitize_name "$index")
    local config_file="$LOGSTASH_CONF_DIR/${sanitized_index}.conf"

    # Remove config if CONFIG_CLEANUP is true
    if [ "$CONFIG_CLEANUP" = true ]; then
        rm "$config_file"
    fi
}

generate_logstash_config() {
    local uuid=$1
    local index=$2

    # Sanitize index for the config filename
    local sanitized_index=$(sanitize_name "$index")
    local config_file="$LOGSTASH_CONF_DIR/${sanitized_index}.conf"

    # Generate Logstash configuration for the current data view
    cat <<EOF >"$config_file"
input {
    elasticsearch {
        hosts => ["${ES_ENDPOINT#https://}"]
        user => "\${ES_USERNAME}"
        ssl => $ES_SSL
        password => "\${ES_PASSWORD}"
        index => "$index,-.*"
        query => '{ "query": { "query_string": { "query": "*" } } }'
        scroll => "5m"
        size => $BATCH_SIZE
        docinfo => true
        docinfo_target => "[@metadata][doc]"
EOF

    # Add ca_file only if ES_CA_FILE is set
    if [ -n "$ES_CA_FILE" ]; then
        echo "        ca_file => \"$ES_CA_FILE\"" >>"$config_file"
    fi

    # Close the input and start output section
    cat <<EOF >>"$config_file"
    }
}
output {
EOF

    # Add stdout output if DEBUG is true
    if [ "$DEBUG" = true ]; then
        echo "    stdout { codec => json }" >>"$config_file"
    fi

    # Continue with the standard output section
    cat <<EOF >>"$config_file"
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

    echo "Logstash configuration for Index $index created as $config_file"

}

run_logstash() {
    local uuid=$1
    local index=$2

    # Sanitize index for the config filename
    local sanitized_index=$(sanitize_name "$index")
    local config_file="$LOGSTASH_CONF_DIR/${sanitized_index}.conf"

    # Update report file status to "InProgress"
    update_indices_report "$uuid" "InProgress"

    # Set environment variables for Logstash
    export ES_USERNAME="$ES_USERNAME"
    export ES_PASSWORD="$ES_PASSWORD"
    export OS_USERNAME="$OS_USERNAME"
    export OS_PASSWORD="$OS_PASSWORD"

    # Test the Logstash configuration
    echo "Testing Logstash configuration for $index..."
    if sudo -E /usr/share/logstash/bin/logstash -f "$config_file" --config.test_and_exit; then
        echo "Logstash configuration for $index is valid."

        # Run Logstash
        echo "Running Logstash for data view $index..."
        if sudo -E /usr/share/logstash/bin/logstash -f "$config_file"; then
            echo "Data view $index processed successfully."
            update_indices_report "$uuid" "Done"
            return 0
        else
            echo "Failed to process data view $index."
            update_indices_report "$uuid" "Failed"
            return 1
        fi
    else
        echo "Logstash configuration for $index is invalid."
        update_indices_report "$uuid" "Failed"
        return 1
    fi
}

# Initialize report file with all indices marked as UnProcessed
generate_initial_indices_report() {
    local indices_file=$1

    # Check if jq is installed
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed."
        exit 1
    fi

    # Check if the indices file exists
    if [[ ! -f "$indices_file" ]]; then
        echo "Error: Indices file '$indices_file' not found."
        exit 1
    fi

    # Initialize the report file if it doesn't exist
    if [[ ! -f "$INDICES_REPORT_FILE" ]]; then
        echo "uuid, sid, Index Pattern, Index, Start Time, Last Update, Status" >"$INDICES_REPORT_FILE"
    fi

    # Extract the general information from the indices file
    sid=$(jq -r '.sid' "$indices_file")
    index_pattern=$(jq -r '.["Index Pattern"]' "$indices_file")

    # Set current time for Start Time and Last Update
    current_time=$(date +"%Y-%m-%d %H:%M:%S")

    # Iterate over each index entry within the indices array and avoid multiple jq calls per index
    jq -c '.indices[]' "$indices_file" | while IFS= read -r index; do
        uuid=$(echo "$index" | jq -r '.UUID')
        index_name=$(echo "$index" | jq -r '.["Index Name"]')

        # Validate the extracted fields
        if [[ -z "$uuid" || -z "$index_name" ]]; then
            echo "Warning: Missing UUID or Index Name for an entry, skipping."
            continue
        fi

        # Check if the UUID is already in the report file to avoid duplicates
        if ! grep -q "^$uuid," "$INDICES_REPORT_FILE"; then
            echo "$uuid, $sid, $index_pattern, $index_name, '', $current_time, UnProcessed" >>"$INDICES_REPORT_FILE"
        fi
    done

}

fetch_indices() {
    local id=$1
    local name=$2
    local title=$3

    local sanitized_title=$(sanitize_name "$title")
    local sid=$(sanitize_name "$id")
    local indices_json_file="$INDICES_DIR/$sid.json"

    echo "Fetching Indices List of data view $title from $ES_ENDPOINT..."

    # Fetch the list of indices and capture the HTTP status code
    response=$(curl -s -w "%{http_code}" $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" \
        "$ES_ENDPOINT/_cat/indices/$title?h=index,health,status,uuid,pri,rep,docs.count,docs.deleted,store.size,pri.store.size,rep.store.size")

    http_code="${response: -3}"        # Extract last 3 characters as HTTP status code
    raw_indices_list="${response%???}" # Remove last 3 characters to get the actual response body

    # Check if the HTTP status indicates a failure
    if [[ "$http_code" -ne 200 ]]; then
        echo "Error: Failed to fetch indices for data view $title. HTTP Status: $http_code"

        # Check if the error response is valid JSON
        if echo "$raw_indices_list" | jq . >/dev/null 2>&1; then
            # If JSON, include it directly in the error field
            jq -n --arg sid "$sid" \
                --arg name "$name" \
                --arg title "$title" \
                --argjson error "$raw_indices_list" \
                '{
                      sid: $sid,
                      "Data View": $name,
                      "Index Pattern": $title,
                      indices: [],
                      error: $error
                  }' >"$indices_json_file"
        else
            # If not JSON, treat it as a string
            jq -n --arg sid "$sid" \
                --arg name "$name" \
                --arg title "$title" \
                --arg error "Failed to fetch indices: HTTP Status $http_code - $raw_indices_list" \
                '{
                      sid: $sid,
                      "Data View": $name,
                      "Index Pattern": $title,
                      indices: [],
                      error: $error
                  }' >"$indices_json_file"
        fi
        return
    fi

    # Check if indices were returned (empty response means no indices)
    if [[ -z "$raw_indices_list" ]]; then
        echo "No indices found for data view $title. Saving empty indices list to JSON file."

        # Save JSON with empty indices and no error
        jq -n --arg sid "$sid" \
            --arg name "$name" \
            --arg title "$title" \
            '{
                  sid: $sid,
                  "Data View": $name,
                  "Index Pattern": $title,
                  indices: []
              }' >"$indices_json_file"
        return
    fi

    # Initialize the JSON file structure for successful fetch
    jq -n --arg sid "$sid" \
        --arg name "$name" \
        --arg title "$title" \
        '{
              sid: $sid,
              "Data View": $name,
              "Index Pattern": $title,
              indices: []
          }' >"$indices_json_file"

    # Append each index entry into the JSON structure using jq
    while IFS= read -r line; do

        # Check if the line is empty or only contains whitespace
        [[ -z "$line" ]] && continue

        read -ra columns <<<"$line"
        uuid="${columns[3]}"
        index_name="${columns[0]}"
        health="${columns[1]}"
        index_status="${columns[2]}"
        doc_count="${columns[6]}"
        primary_data_size="${columns[9]}"
        store_size="${columns[8]}"

        # Append index data to the indices array in the JSON file
        jq --arg uuid "$uuid" \
            --arg index_name "$index_name" \
            --arg health "$health" \
            --arg index_status "$index_status" \
            --arg doc_count "$doc_count" \
            --arg primary_data_size "$primary_data_size" \
            --arg store_size "$store_size" \
            '.indices += [{
               UUID: $uuid,
               "Index Name": $index_name,
               Health: $health,
               "Index Status": $index_status,
               "Doc Count": $doc_count,
               "Primary Data Size": $primary_data_size,
               "Store Size": $store_size
           }]' "$indices_json_file" >tmp.json && mv tmp.json "$indices_json_file"

        # Generate Initial Indices Report
        if generate_initial_indices_report "$indices_json_file"; then
            echo "Initial indices report generated: $INDICES_REPORT_FILE"
        else
            echo "Initial indices report generation at $INDICES_REPORT_FILE Failed!"
            exit 1
        fi

    done <<<"$raw_indices_list"

    echo "Indices details for data view $title saved to $indices_json_file"
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
    echo ""
}

# Initialize report file with all data views marked as UnProcessed
generate_initial_report() {
    # Initialize the report file if it doesn't exist
    if [[ ! -f "$REPORT_FILE" ]]; then
        echo "sid, id, Data View, Index Pattern, Status" >"$REPORT_FILE"
    fi

    # Add all data views to the report with "UnProcessed" status
    jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
        id=$(echo "$row" | jq -r '.id')
        name=$(echo "$row" | jq -r '.name')
        title=$(echo "$row" | jq -r '.title')
        sid=$(sanitize_name "$id")

        if ! grep -q "^$sid," "$REPORT_FILE"; then
            echo "$sid, $id, $name, $title, UnProcessed" >>"$REPORT_FILE"

            # Fetch Indices List
            fetch_indices "$id" "$name" "$title"
        fi
    done
}

# Update or append status in the report file
update_report() {
    local id=$1
    local name=$2
    local index_pattern=$3
    local status=$4
    local sid=$(sanitize_name "$id")

    if grep -q "^$sid," "$REPORT_FILE"; then
        sed -i "s/^$sid,.*/$sid, $id, $name, $index_pattern, $status/" "$REPORT_FILE"
    else
        echo "$sid, $id, $name, $index_pattern, $status" >>"$REPORT_FILE"
    fi
}

# Verify if the data view should be processed or skipped
verify_dataview() {
    local id=$1
    local name=$2
    local title=$3
    local sid=$(sanitize_name "$id")

    # Check the report file for the current data view's status
    local status=$(grep -E "^$sid," "$REPORT_FILE" | cut -d ',' -f5 | tr -d ' ')

    # If status is "Done" or "Skipped", skip processing
    if [[ "$status" == "Done" || "$status" == "Skipped" ]]; then
        echo "Data view $title is already processed. Skipping..."
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

# Update or append status in the report file
update_indices_report() {
    local uuid="$1"
    local status="$2"

    if [[ -z "$uuid" || -z "$status" || ! -f "$INDICES_REPORT_FILE" ]]; then
        echo "Error: UUID, status, or report file is missing."
        return 1
    fi

    # Update Status based on UUID
    awk -v uuid="$uuid" -v status=" $status" '
        BEGIN { FS = OFS = "," }          # Set field separator (FS) and output field separator (OFS) to comma
        NR == 1 { print; next }           # Print the header line as is
        $1 == uuid { $7 = status }        # If UUID matches, update the Status field (7th column)
        { print }                         # Print all lines (modified or not)
    ' "$INDICES_REPORT_FILE" >tmpfile && mv tmpfile "$INDICES_REPORT_FILE"
}

# Verify if the data view should be processed or skipped
verify_indices() {
    local uuid=$1
    local index=$2

    # Check the report file for the current data view's status
    local status=$(grep -E "^$uuid," "$INDICES_REPORT_FILE" | cut -d ',' -f7 | tr -d ' ')

    # If status is "Done" or "Skipped", skip processing
    if [[ "$status" == "Done" || "$status" == "Skipped" ]]; then
        echo "Indices $index is already processed. Skipping..."
        return 1
    fi

    # Skip system indexes if configured to do so
    if [[ "$IGNORE_SYSTEM_INDEXES" = true && "$title" == .* ]]; then
        echo "Ignoring system index: $title"
        update_indices_report "$uuid" "Skipped"
        return 1
    fi

    # Check if the index exists
    if ! curl -s $CURL_FLAGS -u "$ES_USERNAME:$ES_PASSWORD" -o /dev/null -w "%{http_code}" "$ES_ENDPOINT/_cat/indices/$index" | grep -q "200"; then
        echo "Index $index does not exist. Skipping this data view."
        update_indices_report "$uuid" "Skipped"
        return 1
    fi

    return 0
}

process_indices() {
    local uuid=$1
    local index=$2

    update_indices_report "$uuid" "InProgress"
    generate_logstash_config $uuid $index
    if ! run_logstash $uuid $index; then
        return 1
    fi
    logstash_cleanup $uuid $index
}

process_dataview() {
    local id=$1
    local name=$2
    local title=$3
    echo "Processing data view: $name (Index Pattern: $title)"

    # Sanitize title for the config filename
    local sid=$(sanitize_name "$id")
    local indices_list_file="$INDICES_DIR/$sid.json"

    jq -c '.indices[]' "$indices_list_file" | while read -r row; do
        uuid=$(echo "$row" | jq -r '.UUID')
        index=$(echo "$row" | jq -r '.["Index Name"]')

        if verify_indices "$uuid" "$index"; then
            if ! process_indices "$uuid" "$index"; then
                return 1
            fi
        fi
    done
}

migrate() {
    echo "Starting data migration..."

    # Fetch data views and generate initial report, with exit on failure
    fetch_dataviews || {
        echo "Error while fetching Data Views"
        exit 1
    }
    generate_initial_report || {
        echo "Error while generating initial Data Views report"
        exit 1
    }

    # Process each data view
    jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
        id=$(echo "$row" | jq -r '.id')
        title=$(echo "$row" | jq -r '.title')
        name=$(echo "$row" | jq -r '.name')

        if verify_dataview "$id" "$name" "$title"; then
            update_report "$id" "$name" "$title" "InProgress"
            if process_dataview "$id" "$name" "$title"; then
                update_report "$id" "$name" "$title" "Done"
            else
                update_report "$id" "$name" "$title" "Failed"
            fi
        fi
    done || exit 1
    echo "Data migration complete."
}

# Main function to run the steps in sequence
main() {
    # Process options
    while getopts "e:" opt; do
        case "$opt" in
        e) env_file="$OPTARG" ;;
        *)
            echo "Usage: $0 [-e env_file] {setup|migrate|getdashboards}"
            exit 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    # Set up environment variables
    setup_variables "$env_file"

    # Handle commands (setup or migrate)
    case "$1" in
    setup)
        setup
        ;;
    getdashboards)
        get_dashboards
        ;;
    migrate)
        migrate
        ;;
    *)
        echo "Invalid command. Usage: $0 {setup|migrate|getdashboards}"
        exit 1
        ;;
    esac
}

# Run the main function
main "$@"
