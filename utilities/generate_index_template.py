#!/usr/bin/env python3
"""
============================
Meta Information
============================
Script Name: generate_index_template.py
Description: This script generates an index template for Elasticsearch/Opensearch with configurable shard count, replica count, and index patterns.
Author: Pankaj Kumar Patel
Email: pankajackson@live.co.uk
Maintainer: Pankaj Kumar Patel
Version: 1.0.0
License: MIT License
Dependencies: argparse, json
Usage: 
    python generate_index_template.py -sc 3 -rc 1 -ip index1 index2
============================
"""

import json
import argparse


def generate_template(
    index_patterns: set,
    shard_count: int,
    replica_count: int,
) -> str:
    """
    Generate an Elasticsearch index template as a JSON string.

    Args:
        index_patterns (set): A set of index patterns to include in the template.
        shard_count (int): The number of shards for the index.
        replica_count (int): The number of replicas for the index.

    Returns:
        str: The generated index template as a JSON string.
    """
    index_patterns = set(index_patterns)
    template_dict = {
        "index_patterns": list(index_patterns),
        "template": {
            "settings": {
                "index": {
                    "number_of_shards": shard_count,
                    "number_of_replicas": replica_count,
                }
            }
        },
    }
    return json.dumps(template_dict)


def get_args() -> argparse.ArgumentParser:
    """
    Parse command line arguments.

    Returns:
        argparse.ArgumentParser: The argument parser object.
    """
    args = argparse.ArgumentParser()
    args.add_argument(
        "-sc",
        "--shard-count",
        type=int,
        default=2,
        help="Number of shards",
    )
    args.add_argument(
        "-rc",
        "--replica-count",
        type=int,
        default=2,
        help="Number of replicas",
    )
    args.add_argument(
        "-ip",
        "--index-patterns",
        type=str,
        nargs="+",
        help="List of index patterns",
        required=True,
    )
    return args


def main() -> None:
    """
    Main function to parse arguments and generate the index template.
    """
    args = get_args().parse_args()
    index_patterns = set(args.index_patterns)
    template = generate_template(
        index_patterns=index_patterns,
        replica_count=args.replica_count,
        shard_count=args.shard_count,
    )
    print(template)


if __name__ == "__main__":
    main()
