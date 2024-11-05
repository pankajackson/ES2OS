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

1. **Run Migration:**:

   ```bash
   ./es2os.sh
   ```

   This command will:

   - Fetch data views from Kibana.
   - Generate a Logstash configuration for each data view.
   - Migrate data to OpenSearch based on each configuration.

2. **Run Migration:**:

   The script generates a report file with the status of each data view in
   `output_files/dataviews_migration_report.csv.`

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
```

### Other Configurable Settings in `es2os.sh`

- `OUTPUT_DIR`: Directory where output files are saved. Default is `./output_files`.
- `CONFIG_CLEANUP`: Set to `true` or `false` to control whether generated Logstash configuration files are removed after processing.

## File Structure

- `es2os.sh`: Main script for data view migration.
- `output_files/`: Contains generated files:
  - `dataviews.json`: Fetched data views.
  - `dataviews_migration_report.csv`: Report file with migration status for each data view.
  - `ls_confs/`: Directory for generated Logstash configuration files.

## Notes

- Ensure `jq` and `curl` are installed before running the script.
- Ensure that all host URLs in the env.sh file include the protocol (http:// or https://) and port (:9200, :443, or :5601), along with the hostname.
- Run `./es2os.sh setup` before running the migration to install required applications.
- To modify the cleanup behavior, set `CONFIG_CLEANUP` to `true` or `false` within the script.

## License

This project is licensed under the MIT License.
