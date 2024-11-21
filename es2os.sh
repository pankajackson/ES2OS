#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to set up the workstation with required applications
setup() {
    echo "Setting up the workstation..."

    # Import the GPG key for Elasticsearch
    wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -

    # Install transport package and add Elasticsearch source list
    sudo apt-get install -y apt-transport-https jq curl net-tools
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

    # Define Instance Details
    INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
    INSTANCE_ID="${INSTANCE_ID:-1}"

    # Define default values for environment variables
    ES_ENDPOINT="${ES_HOST:-https://es.la.local:9200}"
    KB_ENDPOINT="${KB_HOST:-https://kb.la.local:5601}"
    ES_USERNAME="${ES_USER:-elastic}"
    ES_PASSWORD="${ES_PASS:-default_elastic_password}"
    ES_SSL="${ES_SSL:-true}"
    ES_CA_FILE="${ES_CA_FILE:-}"
    ES_BATCH_SIZE="${ES_BATCH_SIZE:-2000}"
    DATAVIEW_API_INSECURE="${DATAVIEW_API_INSECURE:-true}"

    OS_ENDPOINT="${OS_HOST:-https://os.la.local:9200}"
    OS_USERNAME="${OS_USER:-admin}"
    OS_PASSWORD="${OS_PASS:-default_admin_password}"
    OS_SSL="${OS_SSL:-true}"
    OS_CA_FILE="${OS_CA_FILE:-}"
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

    LOGSTASH_DIR="$OUTPUT_DIR/logstash"
    mkdir -p "$LOGSTASH_DIR"
    LOGSTASH_CONF_DIR="$OUTPUT_DIR/logstash/conf"
    mkdir -p "$LOGSTASH_CONF_DIR"
    LOGSTASH_DATA_DIR="$OUTPUT_DIR/logstash/data"
    mkdir -p "$LOGSTASH_DATA_DIR"

    DASHBOARD_DIR="$OUTPUT_DIR/dashboards"
    mkdir -p "$DASHBOARD_DIR"

    LOGS_DIR="$OUTPUT_DIR/logs"
    mkdir -p "$LOGS_DIR"
    LOG_FILE="$LOGS_DIR/$(date '+%Y-%m-%d-%H-%M-%S').log"
    CURRENT_LOG_FILE="$LOGS_DIR/current.log"

    # Control config cleanup
    CONFIG_CLEANUP="${CONFIG_CLEANUP:-false}"

    # Set DEBUG to false by default
    DEBUG="${DEBUG:-false}"

    # Set concurrency, 2 is default
    CONCURRENCY="${CONCURRENCY:-2}"
    if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || [ "$CONCURRENCY" -lt 2 ]; then
        CONCURRENCY=2
    fi

    # Set indices pattern to exclude, default is none
    EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-}"

    # Logstash pipeline batch size, 500 is default
    LS_BATCH_SIZE="${LS_BATCH_SIZE:-125}"

    # Set default JAVAOPTS
    LS_JAVA_OPTS="${LS_JAVA_OPTS:-}"

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

# Function to get Logstash PIDs with active network connections
get_logstash_processes() {
    # Get all Logstash PIDs
    local LOGSTASH_PIDS
    LOGSTASH_PIDS=$(pgrep -f logstash 2>/dev/null)

    # Check if no Logstash processes are found
    if [ -z "$LOGSTASH_PIDS" ]; then
        return 1 # Indicate failure
    fi

    # Filter PIDs to include only those with network activity
    local FILTERED_PIDS=()
    for PID in $LOGSTASH_PIDS; do
        if sudo netstat -nptul | grep -q "$PID"; then
            FILTERED_PIDS+=("$PID")
        fi
    done

    # Check if no filtered PIDs remain
    if [ ${#FILTERED_PIDS[@]} -eq 0 ]; then
        return 1 # Indicate failure
    fi

    # return filtered PIDs as a space-separated string
    echo "${FILTERED_PIDS[@]}"
    return 0 # Indicate success
}

get_master_processes() {
    # Get the script name for filtering the processes
    local SC_NAME="$0"

    # Get all PIDs of processes related to the script and "migrate" keyword
    local MASTER_PIDS
    MASTER_PIDS=$(pgrep -f "$SC_NAME.*migrate" 2>/dev/null)

    # Check if no processes are found
    if [ -z "$MASTER_PIDS" ]; then
        return 1 # Indicate failure
    fi

    # Return the filtered PIDs as a space-separated string
    echo "$MASTER_PIDS"
    return 0 # Indicate success
}

# Monitoring function
status() {
    # Temporarily disable `set -e` for this function
    set +e

    local LOGSTASH_PIDS
    LOGSTASH_PIDS=$(get_logstash_processes)

    # Check if there are no Logstash processes
    if [[ -z "$LOGSTASH_PIDS" ]]; then
        echo "No Logstash processes found."
        return
    fi

    echo "============================"

    for PID in $LOGSTASH_PIDS; do
        echo "Logstash Instance:"
        echo "PID: $PID"
        echo "----------------------------"

        PORT=$(sudo netstat -nptul | awk -v pid="$PID" '$0 ~ pid {split($4, a, ":"); print a[2]}')
        echo "Port: ${PORT:-Unavailable}"

        CONFIG_FILE=$(sudo ps -aux | awk -v pid="$PID" '$2 == pid {split($0, a, "-f "); split(a[2], b, " "); print b[1]}')
        echo "Config File: ${CONFIG_FILE:-Unavailable}"

        PATH_DATA=$(sudo ps -aux | awk -v pid="$PID" '$2 == pid {split($0, a, "--path.data="); split(a[2], b, " "); print b[1]}')
        echo "Data Path: ${PATH_DATA:-Unavailable}"

        if [[ -n "$PATH_DATA" ]]; then
            INDICES_UUID=$(awk -F '/' '{print $NF}' <<<"$PATH_DATA")
        fi

        if [[ -n "$INDICES_UUID" ]]; then
            indices_json_file=$(grep -rl --include="*.json" "$INDICES_UUID" "$INDICES_DIR" | head -n 1)
            echo "File: $indices_json_file"

            while IFS= read -r index_entry; do
                indices_uuid=$(echo "$index_entry" | jq -r '.UUID')
                if [[ "$indices_uuid" == "$INDICES_UUID" ]]; then
                    indices_name=$(echo "$index_entry" | jq -r '.["Index Name"]')
                    indices_docs=$(echo "$index_entry" | jq -r '.["Doc Count"]')
                    indices_size=$(echo "$index_entry" | jq -r '.["Store Size"]')
                    break
                fi
            done < <(jq -c '.indices[]' "$indices_json_file")
        fi

        echo "Index Info:"
        echo "  UUID:   ${INDICES_UUID}"
        echo "  Name:   ${indices_name:-Unknown}"
        echo "  Docs:   ${indices_docs:-Unknown}"
        echo "  Size:   ${indices_size:-Unknown}"

        # Fetch pipeline stats from Logstash
        ls_endpoint="http://localhost:$PORT"
        PIPELINE_STATE=$(curl -s "$ls_endpoint/_node/stats/pipelines")
        PIPELINE_STATUS=$(echo "$PIPELINE_STATE" | jq -r .status 2>/dev/null)
        PIPELINE_BATCH_SIZE=$(echo "$PIPELINE_STATE" | jq -r .pipeline.batch_size 2>/dev/null)
        PIPELINE_WORKER=$(echo "$PIPELINE_STATE" | jq -r .pipeline.workers 2>/dev/null)
        PIPELINE_DIM=$(echo "$PIPELINE_STATE" | jq -r .pipelines.main.events.duration_in_millis 2>/dev/null)
        PIPELINE_OUT=$(echo "$PIPELINE_STATE" | jq -r .pipelines.main.events.out 2>/dev/null)

        if [[ -n "$PIPELINE_DIM" && "$PIPELINE_DIM" -gt 0 ]]; then
            PIPELINE_RATE=$(awk "BEGIN { printf \"%.2f\", $PIPELINE_OUT / ($PIPELINE_DIM / 1000) }")
        else
            PIPELINE_RATE=0
        fi

        if [[ "${indices_docs:-0}" -eq 0 ]]; then
            PERCENTAGE=0
        else
            PERCENTAGE=$(awk "BEGIN { printf \"%.2f\", ${PIPELINE_OUT:-0} / ${indices_docs:-1} * 100 }")
        fi

        echo "Pipeline Info:"
        echo "  Status:     ${PIPELINE_STATUS:-Unavailable}"
        echo "  Batch Size: ${PIPELINE_BATCH_SIZE:-Unavailable}"
        echo "  Workers:    ${PIPELINE_WORKER:-Unavailable}"
        echo "  Out:        ${PIPELINE_OUT:-0} / ${indices_docs:-0} (${PERCENTAGE}%)"
        echo "  Rate:       ${PIPELINE_RATE:-0.00} events/sec"

        sudo /usr/share/logstash/jdk/bin/jstat -gc "$PID" 2>/dev/null |
            awk 'NR > 1 {
                used_heap = $3 + $4 + $6 + $8
                total_heap = $5 + $7 + $9
                printf "Heap Usage: %.2f / %.2f MB\n", used_heap / 1024, total_heap / 1024
            }'

        echo "----------------------------"
    done

    echo "End of Logstash Instance"
    echo "============================"

    set -e
}

logs() {
    local follow_logs=$1

    if [[ ! -f "$CURRENT_LOG_FILE" ]]; then
        echo "No logs found. Migration might not have started yet."
        exit 1
    fi

    if $follow_logs; then
        tail -f "$CURRENT_LOG_FILE"
    else
        cat "$CURRENT_LOG_FILE"
    fi
}

stop_all_processes() {
    # Temporarily disable `set -e` for this function
    set +e

    local LOGSTASH_PIDS
    LOGSTASH_PIDS=$(get_logstash_processes)
    MASTER_PIDS=$(get_master_processes)

    # Function to kill parent processes recursively and update the report if needed
    kill_parent_processes() {
        local PID=$1
        local UUID=$2
        while [[ -n "$PID" ]]; do
            # Get the parent PID
            PARENT_PID=$(ps -o ppid= -p "$PID" | xargs)
            # Kill the process
            sudo kill -9 "$PID" 2>/dev/null
            echo "Terminated process with PID $PID (parent PID: $PARENT_PID)"
            # If UUID is provided and not empty, update the report
            if [[ -n "$UUID" ]]; then
                update_indices_report "$UUID" "Stopped"
            fi
            # Stop if parent PID is 1 (init system)
            if [[ "$PARENT_PID" -eq 1 ]]; then
                break
            fi
            # Set PID to the parent PID for the next iteration
            PID=$PARENT_PID
        done
    }

    if [[ -n "$MASTER_PIDS" ]]; then
        for MPID in $MASTER_PIDS; do

            # Terminate the main Logstash process and its parent processes
            kill_parent_processes "$MPID"

            # Check if the Logstash process was terminated
            if pgrep -x "$MPID" >/dev/null; then
                echo "Failed to terminate Master process with PID $MPID."
            else
                echo "Master process with PID $MPID terminated successfully."
            fi
        done
    else
        echo "No Master processes found."
    fi

    # First, terminate all Logstash processes if they exist
    if [[ -n "$LOGSTASH_PIDS" ]]; then
        for LPID in $LOGSTASH_PIDS; do
            PATH_DATA=$(sudo ps -aux | awk -v pid="$LPID" '$2 == pid {split($0, a, "--path.data="); split(a[2], b, " "); print b[1]}')

            if [[ -n "$PATH_DATA" ]]; then
                if [[ ! -f "$INDICES_REPORT_FILE" ]]; then
                    echo "Error: Indices report file not found at $INDICES_REPORT_FILE"
                    INDICES_UUID=""
                else
                    INDICES_UUID=$(awk -F '/' '{print $NF}' <<<"$PATH_DATA")
                fi
            fi

            # Terminate the main Logstash process and its parent processes
            kill_parent_processes "$LPID" "$INDICES_UUID"

            # Check if the Logstash process was terminated
            if pgrep -x "$LPID" >/dev/null; then
                echo "Failed to terminate Logstash process with PID $LPID."
            else
                echo "Logstash process with PID $LPID terminated successfully."
                if [[ -n "$INDICES_UUID" ]]; then
                    update_indices_report "$INDICES_UUID" "Stopped"
                fi
            fi
        done
    else
        echo "No Logstash processes found."
    fi

    # Then, process the PID file for associated processes, even if no Logstash processes were found
    if [[ -f "$LOGSTASH_DIR/pids" ]]; then
        while read -r pid uuid; do
            # Kill the process from the pids file and its parent processes
            kill_parent_processes "$pid" "$uuid"
            sleep 1
            if pgrep -x "$pid" >/dev/null; then
                echo "Failed to terminate process with PID $pid for UUID $uuid."
            else
                echo "Process with PID $pid for UUID $uuid terminated successfully."
                # Update the report for this UUID
                if [[ -n "$uuid" ]]; then
                    update_indices_report "$uuid" "Stopped"
                fi
                # Remove the entry from the pids file
                sed -i "/^$pid $uuid$/d" "$LOGSTASH_DIR/pids"
            fi
        done <"$LOGSTASH_DIR/pids"
    fi
    set -e
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
    local logstash_data_dir="$LOGSTASH_DATA_DIR/$uuid"

    # Remove config if CONFIG_CLEANUP is true
    if [ "$CONFIG_CLEANUP" = true ]; then
        rm "$config_file"
        rm -rf $logstash_data_dir
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
        size => $ES_BATCH_SIZE
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
EOF

    # Add ca_file only if ES_CA_FILE is set
    if [ -n "$OS_CA_FILE" ]; then
        echo "        cacert => \"$OS_CA_FILE\"" >>"$config_file"
    fi

    # Close the input and start output section
    cat <<EOF >>"$config_file"
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

    # Create a unique path.data directory for each instance of Logstash
    local logstash_data_dir="$LOGSTASH_DATA_DIR/$uuid"
    mkdir -p "$logstash_data_dir" # Create the directory if it doesn't exist

    # Update report file status to "InProgress"
    update_indices_report "$uuid" "InProgress"

    # Set environment variables for Logstash
    export ES_USERNAME="$ES_USERNAME"
    export ES_PASSWORD="$ES_PASSWORD"
    export OS_USERNAME="$OS_USERNAME"
    export OS_PASSWORD="$OS_PASSWORD"
    export LS_JAVA_OPTS="$LS_JAVA_OPTS"

    # Test the Logstash configuration
    echo "Testing Logstash configuration for $index..."
    if sudo -E /usr/share/logstash/bin/logstash -f "$config_file" --path.data="$logstash_data_dir" --config.test_and_exit; then
        echo "Logstash configuration for $index is valid."

        # Run Logstash in the background with the unique path.data
        echo "Running Logstash for index $index..."
        sudo -E /usr/share/logstash/bin/logstash -b $LS_BATCH_SIZE -f "$config_file" --path.data="$logstash_data_dir" & # Run in background
        pid=$!                                                                                                          # Capture the background process's PID
        echo "Logstash for index $index started with PID $pid."
        echo "$pid $uuid" >>"$LOGSTASH_DIR/pids" # Store UUID and PID in pids file

        # Wait for the background process to finish
        wait $pid # This ensures we wait for Logstash to finish before continuing

        # Check if Logstash succeeded or failed
        if [ $? -eq 0 ]; then
            echo "Index $index processed successfully."
            update_indices_report "$uuid" "Done"
            sed -i "/$pid $uuid/d" "$LOGSTASH_DIR/pids" # Remove the entry from pids after completion
            return 0
        else
            echo "Failed to process Index $index."
            update_indices_report "$uuid" "Failed"
            sed -i "/$pid $uuid/d" "$LOGSTASH_DIR/pids" # Remove the entry from pids after completion
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

    echo "Generating initial report for $indices_file"

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
        echo "uuid, sid, Index Pattern, Index, Doc Count, Primary Data Size, Start Time, Last Update, Status" >"$INDICES_REPORT_FILE"
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
        doc_count=$(echo "$index" | jq -r '.["Doc Count"]')
        primary_size=$(echo "$index" | jq -r '.["Primary Data Size"]')

        # Validate the extracted fields
        if [[ -z "$uuid" || -z "$index_name" ]]; then
            echo "Warning: Missing UUID or Index Name for an entry, skipping."
            continue
        fi

        # Check if the UUID is already in the report file
        if grep -q "^$uuid," "$INDICES_REPORT_FILE"; then
            # Extract existing values from the report file
            existing_line=$(grep "^$uuid," "$INDICES_REPORT_FILE")
            existing_doc_count=$(echo "$existing_line" | cut -d',' -f5 | xargs)

            # Compare and update if the new doc count is greater
            if [[ "$doc_count" -gt "$existing_doc_count" ]]; then
                # Update the line in the report file and set Status to Updated
                sed -i "s|^$uuid,.*|$uuid, $sid, $index_pattern, $index_name, $doc_count, $primary_size, , $current_time, Updated|" "$INDICES_REPORT_FILE"
            fi
        else
            # Add new entry if UUID is not present
            echo "$uuid, $sid, $index_pattern, $index_name, $doc_count, $primary_size, , $current_time, UnProcessed" >>"$INDICES_REPORT_FILE"
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

    done <<<"$raw_indices_list"

    # Generate Initial Indices Report
    if ! generate_initial_indices_report "$indices_json_file"; then
        echo "Error: Failed to generate the initial indices report at $INDICES_REPORT_FILE"
        exit 1
    fi

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
    else
        jq -c '.data_view |= sort_by(.id)' "$DATAVIEW_FILE" >"$DATAVIEW_FILE.tmp" && mv "$DATAVIEW_FILE.tmp" "$DATAVIEW_FILE"
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
        fi
        # Fetch Indices List
        fetch_indices "$id" "$name" "$title"
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

    # Backup strategy: Create backup only if 15 minutes have passed since the last backup
    BKP_REPORT_FILE="$DATAVIEW_DIR/dataviews_migration_report-$(date '+%Y-%m-%d-%H-%M').csv"
    if [[ ! -f "$BKP_REPORT_FILE" || $(find "$DATAVIEW_DIR" -name "dataviews_migration_report-*.csv" -mmin +15 | wc -l) -gt 0 ]]; then
        cp "$REPORT_FILE" "$BKP_REPORT_FILE"
        cp "$REPORT_FILE" "$DATAVIEW_DIR/dataviews_migration_report-latest.csv"
        echo "Backup created for Data view Report: $BKP_REPORT_FILE"
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

    # Set the current time
    local current_time
    current_time=$(date +"%Y-%m-%d %H:%M:%S")

    # Update Status, Last Update, and Start Time if empty, based on UUID
    awk -v uuid="$uuid" -v status="$status" -v current_time="$current_time" '
        BEGIN { FS = OFS = ", " }                     # Set field separator (FS) and output field separator (OFS) to comma
        NR == 1 { print; next }                      # Print the header line as is
        $1 == uuid {                                 # Check if UUID matches
            $9 = status                              # Update the Status field (7th column)
            $8 = current_time                        # Always update Last Update field (6th column)
            if ($7 == "") $7 = current_time          # Update Start Time (5th column) only if it is empty
        }
        { print }                                    # Print all lines (modified or not)
    ' "$INDICES_REPORT_FILE" >tmpfile && mv tmpfile "$INDICES_REPORT_FILE"

    # Backup Report in every Change
    BKP_INDICES_REPORT_FILE="$INDICES_DIR/indices_migration_report-$(date '+%Y-%m-%d-%H-%M').csv"

    # Create backup only if 15 minutes have passed since the last backup
    if [[ ! -f "$BKP_INDICES_REPORT_FILE" || $(find "$INDICES_DIR" -name "indices_migration_report-*.csv" -mmin +15 | wc -l) -gt 0 ]]; then
        cp "$INDICES_REPORT_FILE" "$BKP_INDICES_REPORT_FILE"
        cp "$INDICES_REPORT_FILE" "$INDICES_DIR/indices_migration_report-latest.csv"
        echo "Backup created for Indices: $BKP_INDICES_REPORT_FILE"
    fi
}

# Verify if the data view should be processed or skipped
verify_indices() {
    local uuid=$1
    local index=$2
    local indices_list_file=$3
    local original_ifs="$IFS"
    local normalized_patterns=$(echo "$EXCLUDE_PATTERNS" | tr -s ' ' ',')
    IFS=',' read -r -a patterns <<<"$normalized_patterns"
    IFS="$original_ifs" # Restore the original IFS value

    # Check the report file for the current data view's status
    local status=$(grep -E "^$uuid," "$INDICES_REPORT_FILE" | cut -d ',' -f9 | tr -d ' ')

    if [[ -n "$status" ]]; then
        # If status is "Done" or "Skipped", skip processing
        if [[ "$status" == "Done" || "$status" == "Skipped" ]]; then
            echo "Index $index is already processed. Skipping..."
            return 1
        fi
    else
        os_response=$(curl -s -w "%{http_code}" --insecure -u "$OS_USERNAME:$OS_PASSWORD" \
            "$OS_ENDPOINT/_cat/indices/$index?h=index,health,status,uuid,pri,rep,docs.count,docs.deleted,store.size,pri.store.size,rep.store.size")

        http_code="${os_response: -3}"        # Extract last 3 characters as HTTP status code
        raw_indices_list="${os_response%???}" # Remove last 3 characters to get the actual response body

        # Check if the request was successful
        if [[ "$http_code" -ne 200 && "$http_code" -ne 404 ]]; then
            echo "Failed to fetch index information for Opensearch index $index. HTTP code: $http_code"
            return 1
        fi

        # Extract document count from the response for opensearch
        if [[ "$http_code" -eq 404 ]]; then
            echo "Index $index not found in Opensearch. HTTP code: $http_code"
            # Handle as needed when the index is not found
            os_docs_count=0
            echo "Opensearch document count for index $index: $os_docs_count"
        else
            os_docs_count=$(echo "$raw_indices_list" | awk '{print $7}') # Assuming docs.count is the 7th column
            if [[ -z "$os_docs_count" ]]; then
                echo "Document count for index $index is unavailable or empty."
                return 1
            else
                echo "Opensearch document count for index $index: $os_docs_count"
            fi
        fi

        # Extract document count from the response for opensearch
        es_docs_count=0
        while IFS= read -r index_entry; do
            indices_uuid=$(echo "$index_entry" | jq -r '.UUID')
            indices_docs_count=$(echo "$index_entry" | jq -r '.["Doc Count"]')

            if [[ "$indices_uuid" == "$uuid" ]]; then
                es_docs_count=$indices_docs_count
                break
            fi
        done < <(jq -c '.indices[]' "$indices_list_file") # Process substitution avoids a subshell

        echo "Elasticsearch document count for index $index: $es_docs_count"

        if [[ "$os_docs_count" -ge "$es_docs_count" ]]; then
            echo "Opensearch document count ($os_docs_count) is greater than or equal to Elasticsearch document count ($es_docs_count). Skipping index $index."
            update_indices_report "$uuid" "Done"
            return 1
        fi

    fi

    # Skip system indexes if configured to do so
    if [[ "$IGNORE_SYSTEM_INDEXES" = true && "$index" == .* ]]; then
        echo "Ignoring system index: $index"
        update_indices_report "$uuid" "Skipped"
        return 1
    fi

    # Check if the index matches any exclude pattern
    for pattern in "${patterns[@]}"; do
        if [[ "$index" == $pattern ]]; then
            echo "Excluding index: $index"
            update_indices_report "$uuid" "Excluded"
            return 1
        fi
    done

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

    # Max number of parallel processes (example: 4)
    local max_parallel=$CONCURRENCY
    local count=0

    # Trap to handle Ctrl+C and stop all background Logstash processes
    trap 'echo "Interrupt received, stopping all background processes..."; stop_all_processes; exit 1' SIGINT

    # Create a background process for each index
    jq -c '.indices[]' "$indices_list_file" | while read -r row; do
        uuid=$(echo "$row" | jq -r '.UUID')
        index=$(echo "$row" | jq -r '.["Index Name"]')
        index_status=$(echo "$row" | jq -r '.["Index Status"]')

        if [[ "$index_status" == "open" ]]; then
            if verify_indices "$uuid" "$index" "$indices_list_file"; then
                # Process the index in the background
                process_indices "$uuid" "$index" &

                count=$((count + 1))

                # Check if we've reached the concurrency limit
                if [[ $count -ge $max_parallel ]]; then
                    # Wait for any of the running processes to finish before starting new ones
                    wait -n
                    count=$((count - 1)) # Decrement the counter after waiting
                fi
            fi
        else
            update_indices_report "$uuid" "Closed"
        fi
    done

    # Wait for running processes
    while [ -s "$LOGSTASH_DIR/pids" ]; do
        sleep 2
    done

    echo "All Logstash processes have completed."
    trap - SIGINT # Reset the trap after processes are complete
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

    # Clean pid file
    >"$LOGSTASH_DIR/pids"

    # Define total instances and current instance ID
    total_instances="$INSTANCE_COUNT" # Total number of instances
    instance_id="$INSTANCE_ID"        # Current instance ID

    if [[ -z "$total_instances" || -z "$instance_id" || "$instance_id" -gt "$total_instances" || "$instance_id" -lt 1 ]]; then
        echo "Invalid input. Please provide valid total_instances and instance_id (1 <= instance_id <= total_instances)."
        exit 1
    fi

    # Initialize counter for the data view index
    counter=0

    # Process each data view
    jq -c '.data_view[]' "$DATAVIEW_FILE" | while read -r row; do
        id=$(echo "$row" | jq -r '.id')
        title=$(echo "$row" | jq -r '.title')
        name=$(echo "$row" | jq -r '.name')
        assigned_instance_id=$((counter % total_instances + 1))

        # Check if the current index matches the instance number
        if ((assigned_instance_id == instance_id)); then
            echo "Instance $instance_id processing data view with ID: $id"

            if verify_dataview "$id" "$name" "$title"; then
                update_report "$id" "$name" "$title" "InProgress"
                if process_dataview "$id" "$name" "$title"; then
                    update_report "$id" "$name" "$title" "Done"
                else
                    update_report "$id" "$name" "$title" "Failed"
                fi
            fi
        else
            echo "Skipping data view $title for Instance $assigned_instance_id"
        fi

        # Increment counter to track the current index
        ((counter++))
    done || exit 1

    echo "Data migration complete."
}

# Main function to run the steps in sequence
main() {
    daemon_mode=false
    follow_logs=false
    env_file=""

    # Process options
    while getopts "e:df" opt; do
        case "$opt" in
        e)
            env_file="$OPTARG"
            ;;
        d)
            daemon_mode=true
            ;;
        f)
            follow_logs=true
            ;;
        *)
            echo "Usage: $0 [-e <env_file>] [-d] [-f] {setup|migrate|status|getdashboards|logs|stop}"
            echo "  -e <env_file>   Specify the environment file to load."
            echo "  -d              Run the migration in daemon mode (background)."
            echo "  -f              Follow logs in real-time."
            exit 1
            ;;
        esac
    done
    shift $((OPTIND - 1)) # Shift positional arguments after options

    # Set up environment variables
    if [[ -n "$env_file" && ! -f "$env_file" ]]; then
        echo "Error: Environment file '$env_file' does not exist."
        exit 1
    fi
    setup_variables "$env_file"

    # Handle commands (setup or migrate)
    case "$1" in
    setup)
        setup
        ;;
    status)
        status
        ;;
    getdashboards)
        get_dashboards
        ;;
    migrate)

        >"$CURRENT_LOG_FILE" # Clear the current log
        if $daemon_mode; then
            echo "Starting migration in the background. Logs will be saved to $LOG_FILE and $CURRENT_LOG_FILE."
            {
                migrate
            } 2>&1 | tee -a "$LOG_FILE" "$CURRENT_LOG_FILE" >/dev/null &
            disown # Detach the background process from the terminal
        else
            echo "Starting migration in the foreground. Logs will be saved to $LOG_FILE and $CURRENT_LOG_FILE."
            {
                migrate
            } 2>&1 | tee -a "$LOG_FILE" "$CURRENT_LOG_FILE"
        fi
        ;;
    logs)
        logs $follow_logs
        ;;
    stop)
        stop_all_processes
        ;;
    help)
        echo "Usage: $0 [-e <env_file>] [-d] [-f] {setup|migrate|status|getdashboards|logs|stop}"
        echo "  -e <env_file>   Specify the environment file to load."
        echo "  -d              Run the migration in daemon mode (background)."
        echo "  -f              Follow logs in real-time."
        ;;
    *)
        echo "Error: Invalid command. Usage: $0 [-e <env_file>] [-d] [-f] {setup|migrate|status|getdashboards|logs|stop}"
        exit 1
        ;;
    esac
}

# Run the main function
main "$@"
