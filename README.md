# ES2OS: Data View Migration Tool

This project is a Bash script for migrating data views from Elasticsearch to OpenSearch. It fetches data views from Kibana, generates Logstash configurations, and transfers data between indices.

## Table of Contents

- [ES2OS: Data View Migration Tool](#es2os-data-view-migration-tool)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Requirements](#requirements)
  - [Installation](#installation)
  - [Usage](#usage)
  - [Configuration](#configuration)
    - [Configurable Variables in `env.sh`](#configurable-variables-in-envsh)
    - [Example `env.sh`:](#example-envsh)
    - [Other Configurable Settings in `es2os.sh`](#other-configurable-settings-in-es2ossh)
  - [File Structure](#file-structure)
  - [Notes](#notes)
  - [License](#license)

---

## Features

- Fetches data views from Kibana and generates a report file with migration statuses.
- Supports automatic setup for dependencies like Logstash and required plugins.
- Migration report with detailed status tracking.
- Cleanup option to remove generated configuration files after migration.

## Requirements

- **Operating System**: Linux (tested on Ubuntu)
- **Dependencies**:
  - `jq`: JSON processing tool
  - `curl`: HTTP client
  - `logstash`: Logstash for data transfer
  - OpenSearch plugin for Logstash

## Installation

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/pankajackson/ES2OS.git
   cd ES2OS
   ```

2. **Run Setup: To install dependencies and set up the environment, use:**:

   ```bash
   ./es2os.sh setup
   ```

   This command installs Logstash and required plugins.

## Usage

1. **Run Migration with default env.sh file:**:

   ```bash
   ./es2os.sh migrate
   ```

2. **Run Migration with custom env file:**:

   ```bash
   ./es2os.sh -e /some/location/custom_env.sh migrate
   ```

   This command will:

   - Fetch data views from Kibana.
   - Generate a Logstash configuration for each data view.
   - Migrate data to OpenSearch based on each configuration.
   - The script generates a report file with the status of each data view in `output_files/dataviews/dataviews_migration_report.csv.`

3. **Download Dashboards:**:

   ```bash
   ./es2os.sh getdashboards
   ```

   This command will:

   - Fetch dashboard list from Kibana.
   - Download ndjson file for each dashboard.
   - The script download all dashboard in `output_files/dashboards.`

## Configuration

This script allows you to set environment-specific values in an optional `env.sh` file. By configuring these variables, you can customize connections and defaults for Elasticsearch, Kibana, and OpenSearch.

### Configurable Variables in `env.sh`

To set up environment-specific values, create an `env.sh` file in the root directory with the following variables:

- **`ES_HOST`**: Elasticsearch host (default: `https://es.la.local:9200`)
- **`KB_HOST`**: Kibana host (default: `https://kb.la.local:5601`)
- **`ES_USER`**: Elasticsearch username (default: `elastic`)
- **`ES_PASS`**: Elasticsearch password (default: `default_elastic_password`)
- **`DATAVIEW_API_INSECURE`**: Set to `true` to disable SSL verification for API requests (default: `true`)
- **`OS_HOST`**: OpenSearch host (default: `https://os.la.local:9200`)
- **`OS_USER`**: OpenSearch username (default: `admin`)
- **`OS_PASS`**: OpenSearch password (default: `default_admin_password`)
- **`CONFIG_CLEANUP`**: Enable Logstash config cleanup (default: `false`)
- **`DEBUG`**: Enable debug output (default: `false`)
- **`OUTPUT_DIR`**: Directory to store output files (default: `./output_files`)

### Example `env.sh`:

```bash
ES_HOST="https://your-elasticsearch-host:9200"
KB_HOST="https://your-kibana-host:5601"
ES_USER="your_es_username"
ES_PASS="your_es_password"
DATAVIEW_API_INSECURE=true
OS_HOST="https://your-opensearch-host:9200"
OS_USER="your_os_username"
OS_PASS="your_os_password"
CONFIG_CLEANUP=false
DEBUG=false
OUTPUT_DIR="./output_files"
```

### Other Configurable Settings in `es2os.sh`

- The script includes an automatic setup function to install required applications and dependencies.
- A report file is generated to track the status of each data view during migration, ensuring clear visibility of progress.

## File Structure

- `es2os.sh`: Main script for data view migration.
- `output_files/`: Contains generated files:
  - `dashboards/`: Directory to export all the dashboards.
    - `dashboards.json`: Fetched dashboards.
  - `datadiews/`:
    - `dataviews.json`: Fetched data views.
    - `dataviews_migration_report.csv`: Report file with migration status for each data view.
  - `logsrash/`: Directory for generated Logstash configuration files.

## Notes

- Ensure `jq` and `curl` are installed before running the script.
- Ensure that all host URLs in the `env.sh` file include the protocol (http:// or https://) and port (:9200, :443, or :5601), along with the hostname.
- Run `./es2os.sh setup` before running the migration to install required applications.
- Ensure you have the necessary permissions to run the script and install software packages.
- Modify the `env.sh` file as needed to reflect your environment settings.

## License

This project is licensed under the MIT License.
