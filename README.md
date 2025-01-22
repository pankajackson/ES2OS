# ES2OS: Data View Migration Tool

A script for migrating data views, dashboards, and indices from Elasticsearch to OpenSearch with a focus on simplicity, configurability, and automation.

## Table of Contents

- [ES2OS: Data View Migration Tool](#es2os-data-view-migration-tool)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Requirements](#requirements)
  - [Installation](#installation)
  - [Usage](#usage)
    - [General Syntax](#general-syntax)
    - [Options](#options)
    - [Commands](#commands)
  - [Examples](#examples)
  - [Configuration](#configuration)
    - [Configurable Variables in `env.sh`](#configurable-variables-in-envsh)
    - [Elasticsearch Configuration](#elasticsearch-configuration)
    - [Kibana Configuration](#kibana-configuration)
    - [OpenSearch Configuration](#opensearch-configuration)
    - [Migration Configuration](#migration-configuration)
    - [Optional Settings](#optional-settings)
    - [Output Directory](#output-directory)
    - [Example `env.sh`](#example-envsh)
    - [Other Configurable Settings in `es2os.sh`](#other-configurable-settings-in-es2ossh)
  - [File Structure](#file-structure)
  - [Utilities](#utilities)
    - [**Policy Generator**:](#policy-generator)
      - [Usage](#usage-1)
      - [Command](#command)
  - [Notes](#notes)
  - [License](#license)

---

## Features

- Fetches data views from Kibana and generates migration reports with detailed statuses.
- Automatically sets up required dependencies, including Logstash and necessary plugins, via the `setup` command.
- Supports migration in **foreground** or **daemon mode** for flexible operation.
- Includes a **real-time log tracking** option with logs stored in the `logs/` directory:
  - `current.log`: Tracks the latest migration session.
  - **Timestamped logs** (`YYYY-MM-DD-HH-MM-SS.log`): Preserve logs for each migration session, enabling historical tracking.
- Generates a detailed report file for both **data views** and **indices** migrations, ensuring clear visibility of progress.
- Provides options to download and save dashboards in **ndjson** format.
- Offers an optional **clean-up mode** to remove generated Logstash configuration files after migration.
- Monitors Logstash heap usage during the migration process for optimized performance.
- Provides a **status command** to check the current progress of the migration process.
- Allows flexible configuration through an external `env.sh` file, supporting environment-specific setups.
- Supports excluding specific indices from migration using patterns defined in the configuration.
- Includes a `logs` command to view logs with an option to follow logs in real-time (`-f` flag).

## Requirements

- **Operating System**: Linux (tested on Ubuntu)
- **Dependencies**:
  - `jq`: JSON processing tool
  - `curl`: HTTP client
  - `net-tools`: Gather socket information
  - `logstash`: Logstash for data transfer
  - OpenSearch plugin for Logstash

## Installation

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/pankajackson/ES2OS.git
   cd ES2OS
   ```

2. **Run Setup: To install dependencies and set up the environment, use:**

   ```bash
   ./es2os.sh setup
   ```

   This command installs Logstash and required plugins.

   **_NOTE:_** The `setup` command has been tested and works on Ubuntu systems. If you're using a different OS, you may need to manually install dependencies such as `jq`, `curl`, `netstat`, and `logstash`.

## Usage

### General Syntax

```bash
./es2os.sh [-e <env_file>] [-d] [-f] {setup|migrate|status|getdashboards|logs|stop}
```

### Options

- -e <env_file>: Specify a custom environment file to load. Defaults to env.sh if not provided.
- -d: Run the migration process in daemon mode (background).
- -f: Follow logs in real-time (used with the logs command).

### Commands

1. **Run Migration with default env.sh file:**

   ```bash
   ./es2os.sh migrate
   ```

   This command will:

   - Fetch data views from Kibana.
   - Generate a Logstash configuration for each index.
   - Migrate data to OpenSearch using the configurations.
   - Generate reports:
     - Data views migration report: output_files/dataviews/dataviews_migration_report.csv.
     - Indices migration report: output_files/indices/indices_migration_report.csv.

2. **Run Migration with custom env file:**

   ```bash
   ./es2os.sh -e /some/location/custom_env.sh migrate
   ```

   This command functions the same as the default migration command, but uses the specified environment file.

3. **Run Migration in Daemon Mode:**

   ```bash
   ./es2os.sh -d migrate
   ```

   This command will:

   - Run the migration process in the background.
   - Save logs to:
     - A timestamped log file in the logs directory (LOGS_DIR).
     - A current.log file for monitoring the latest log entries.

4. **Download Dashboards:**

   ```bash
   ./es2os.sh getdashboards
   ```

   This command will:

   - Fetch dashboard list from Kibana.
   - Download ndjson file for each dashboard.
   - Save downloaded files in the `output_files/dashboards` directory.

5. **Check Logs:**

   - View Current Logs:

     ```bash
     ./es2os.sh logs
     ```

     Displays the contents of the current.log file.

   - Follow Logs in Real-Time:

     ```bash
     ./es2os.sh -f logs
     ```

     Continuously displays new log entries as they are written.

6. **Check Migration Status:**

   ```bash
   ./es2os.sh status
   ```

   Displays the current status of the migration process, including active jobs and pipelines.

7. **Stop All Processes:**

   ```bash
   ./es2os.sh stop
   ```

   Stops all running background processes initiated by the script.

8. **Set Up the Environment:**

   ```bash
   ./es2os.sh setup
   ```

   Sets up the necessary environment, including installing dependencies and preparing directories.

## Examples

1. **Run migration with the default environment file in foreground:**

   ```bash
   ./es2os.sh migrate
   ```

2. **Run migration with a custom environment file in background:**

   ```bash
   ./es2os.sh -e /custom/env.sh -d migrate
   ```

3. **Follow logs while monitoring the migration process:**

   ```bash
   ./es2os.sh -f logs
   ```

4. **Download dashboards to the specified directory:**

   ```bash
   ./es2os.sh getdashboards
   ```

## Configuration

This script allows you to set environment-specific values in an optional `env.sh` file. By configuring these variables, you can customize connections and defaults for Elasticsearch, Kibana, and OpenSearch.

### Configurable Variables in `env.sh`

To set up environment-specific values, create an env.sh file in the root directory with the following variables. Variables starting with # are optional and can be uncommented as needed.

### Elasticsearch Configuration

- `ES_HOST`: Elasticsearch host (default: `https://es.la.local:9200`).
- `KB_HOST`: Kibana host (default: `https://kb.la.local:5601`).
- `ES_USER`: Elasticsearch username (default: `elastic`).
- `ES_PASS`: Elasticsearch password (default: `elastic`).
- `ES_SSL`: Enable SSL for Elasticsearch (default: `true`).
- `ES_CA_FILE`: Path to the Elasticsearch CA file. Uncomment and set if needed for SSL verification (default: `none`).
- `ES_BATCH_SIZE`: Number of documents allowed to transfer in a single batch (default: `2000`).

### Kibana Configuration

- `DATAVIEW_API_INSECURE`: Disable SSL verification for Kibana API requests (default: `true`).

### OpenSearch Configuration

- `OS_HOST`: OpenSearch host (default: `https://os.la.local:9200`).
- `OS_USER`: OpenSearch username (default: `admin`).
- `OS_PASS`: OpenSearch password (default: `admin`).
- `OS_SSL`: Enable SSL for OpenSearch (default: `true`).
- `OS_CA_FILE`: Path to the OpenSearch CA file. Uncomment and set if needed for SSL verification (default: `none`).
- `OS_SSL_CERT_VERIFY`: Enable or disable SSL certificate verification for OpenSearch (default: `false`).

### Migration Configuration

- `CONCURRENCY`: Number of parallel Logstash instances to process indices. (default: `4`).
- `EXCLUDE_PATTERNS`: Comma-separated list of index patterns to exclude from migration (default: `none`).
- `INCLUDE_ONLY_PATTERNS`: Comma-separated list of index patterns to only include in migration, all other indices will be skipped (default: `none`).

### Optional Settings

- `LS_BATCH_SIZE`: Size of batches the Logstash pipeline is to work in. (default: `125`).
- `LS_JAVA_OPTS`: JVM options for Logstash. Uncomment and set if custom JVM settings are needed (default: `none`).
- `CONFIG_CLEANUP`: Enable cleanup of Logstash configuration files after processing (default: `false`).
- `DEBUG`: Enable debug output for detailed logs (default: `false`).

### Output Directory

- `OUTPUT_DIR`: Directory to store output files, including logs and reports (default: `./output_files`).

### Example `env.sh`

```bash
#!/bin/bash

# Elasticsearch Configuration
ES_HOST="https://es.la.local:9200"
KB_HOST="https://kb.la.local:5601"
ES_USER="elastic"
ES_PASS="elastic"
ES_SSL=true
# ES_CA_FILE="/path/to/elasticsearch-ca.pem"
ES_BATCH_SIZE=2000

# Kibana Configuration
DATAVIEW_API_INSECURE=true

# OpenSearch Configuration
OS_HOST="https://os.la.local:9200"
OS_USER="admin"
OS_PASS="admin"
OS_SSL=true
# OS_CA_FILE="/path/to/opensearch-ca.pem"
OS_SSL_CERT_VERIFY=false

# Migration Configuration
CONCURRENCY=4
CONFIG_CLEANUP=false
DEBUG=false
EXCLUDE_PATTERNS=""
INCLUDE_ONLY_PATTERNS=""
LS_BATCH_SIZE=300
LS_JAVA_OPTS="-Xms3g -Xmx3g"

# Output Directory
OUTPUT_DIR="./output_files"
```

### Other Configurable Settings in `es2os.sh`

- **Automatic Setup:** The script includes a `setup` function to install required applications and dependencies, simplifying the initial configuration.
- **Migration Report:** A detailed report file is generated during the migration process to track the status of each data view and index. The report includes:
  - ID
  - Data View name
  - Index Pattern
  - Status (e.g., Unprocessed, InProgress, Done, Failed)

## File Structure

- `es2os.sh`: Main script for data view migration.
- `utilities/`: Directory containing utilities.
- `output_files/`: Directory containing generated files:
  - `dashboards/`: Contains exported dashboards.
    - `dashboards.json`: Fetched dashboards.
  - `datadiews/`:
    - `indices/`: Directory for index-related data.
      - `dataviews_migration_report.csv`: Report tracking index migration status.
    - `dataviews.json`: Fetched data views.
    - `dataviews_migration_report.csv`: Report tracking data view migration status.
  - `logsrash/`: Directory for generated Logstash configuration files.
  - `logs/`: Directory for storing log files.
    - `current.log`: Tracks the latest migration session in real time.
    - `YYYY-MM-DD-HH-MM-SS.log`: Timestamped logs for each migration session, preserving historical logs.

## Utilities

The **Utilities** contains small programs designed to support and enhance the functionality of this project. These utilities provide specialized features that simplify common tasks, automate processes, and improve the overall user experience.

All utility scripts can be found in the `utilities/` directory of the project. Each script is designed to be modular and can be used independently as needed. Below are the available utilities:

### **Policy Generator**:

The Policy Generator is a utility to create ISM (Index State Management) policies for managing data lifecycles in OpenSearch. It helps define the transitions and actions between different data tiers (hot, warm, cold, and delete), making data lifecycle management easier and more efficient.

#### Usage

Run the script with positional arguments to specify the lifespan of each tier in days:

- **hot_life_span** (required): Number of days data should remain in the hot tier.
- **warm_life_span** (optional): Number of days data should remain in the warm tier before transitioning to the cold tier.
- **cold_life_span** (optional): Number of days data should remain in the cold tier before transitioning to the delete state.

#### Command

```bash
python generate_ism_policy.py <hot_life_span> [warm_life_span] [cold_life_span]
```

## Notes

- Prerequisites:
  - Ensure the following utilities are installed: jq, curl, and netstat.
  - Verify that all host URLs in the env.sh file include:
    - Protocol: http:// or https://
    - Port: :9200, :5601, or :443 (depending on the service)
  - Logstash installation is required for index migration.
- Setup Instructions:
  - Run ./es2os.sh setup to install the required dependencies.
    - For non-Ubuntu users, install the following manually:
      - jq
      - curl
      - netstat
      - logstash
    - Ensure you have password-less sudo permissions to execute the script and install packages.
- Environment Configuration:
  - Edit the env.sh file as needed to reflect your environment-specific settings.
  - Optional variables in env.sh (starting with #) can be uncommented and customized based on your requirements.

## License

This project is licensed under the MIT License.

```

```
