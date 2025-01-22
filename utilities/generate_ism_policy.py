#!/usr/bin/env python3

"""
Script Name: generate_ism_policy.py
Description: This script generates an ISM (Index State Management) policy
             for managing data lifecycle in OpenSearch.

Author: Pankaj Kumar Patel
Email: pankajackson@live.co.uk
Maintainer: Pankaj Kumar Patel
Version: 1.0.0
License: MIT License

Usage:
    python generate_ism_policy.py <hot_life_span> [warm_life_span] [cold_life_span]
"""

from dataclasses import dataclass, asdict
import argparse
import json


@dataclass
class Transition:
    state_name: str
    conditions: dict


@dataclass
class State:
    name: str
    actions: list
    transitions: list[Transition]


@dataclass
class ISMTemplate:
    index_patterns: list[str]


@dataclass
class Policy:
    description: str
    default_state: str
    states: list[State]
    ism_template: list[ISMTemplate]


@dataclass
class PolicyTemplate:
    policy: Policy


class ISMPolicy:
    def __init__(
        self,
        hot_life_span: int,
        warm_life_span: int = 0,
        cold_life_span: int = 0,
        description: str | None = None,
        default_state: str = "hot",
        index_patterns: list[str] = [],
    ) -> None:
        self.default_state = default_state
        self.hot_life_span = hot_life_span
        self.warm_life_span = warm_life_span
        self.cold_life_span = cold_life_span
        self.index_patterns = index_patterns
        self.delete_after = max(hot_life_span, warm_life_span, cold_life_span)
        self.action_retry = {
            "count": 3,
            "backoff": "exponential",
            "delay": "1m",
        }
        self.description = description or f"Delete index after {self.delete_after} days"

    def _get_transition(self, name: str, index_age: int) -> Transition:
        return Transition(
            state_name=name,
            conditions={
                "min_index_age": f"{index_age}d",
            },
        )

    def get_hot_state(self, life_span: int) -> State:
        return State(
            name="hot",
            actions=[],
            transitions=(
                [self._get_transition("warm", life_span)]
                if self.warm_life_span > 0
                else (
                    [self._get_transition("cold", life_span)]
                    if self.cold_life_span > 0
                    else [self._get_transition("delete", life_span)]
                )
            ),
        )

    def get_warm_state(self, life_span: int) -> State:
        warm_migration_action = {"retry": self.action_retry, "warm_migration": {}}
        return State(
            name="warm",
            actions=[warm_migration_action],
            transitions=(
                [self._get_transition("cold", life_span)]
                if self.cold_life_span > 0
                else [self._get_transition("delete", life_span)]
            ),
        )

    def get_cold_state(self, life_span: int) -> State:
        cold_migration_action = {"retry": self.action_retry, "cold_migration": {}}
        return State(
            name="cold",
            actions=[cold_migration_action],
            transitions=[self._get_transition("delete", life_span)],
        )

    def get_delete_state(self) -> State:
        delete_action = {"retry": self.action_retry, "delete": {}}
        return State(
            name="delete",
            actions=[delete_action],
            transitions=[],
        )

    def get_ism_template(self, indexes: list[str]) -> ISMTemplate:
        return ISMTemplate(
            index_patterns=indexes,
        )

    def get_policy_states(self) -> list[State]:
        states = [self.get_hot_state(self.hot_life_span)]
        if self.warm_life_span > 0:
            states.append(self.get_warm_state(self.warm_life_span))
        if self.cold_life_span > 0:
            states.append(self.get_cold_state(self.cold_life_span))
        states.append(self.get_delete_state())
        return states

    def get_policy(self) -> PolicyTemplate:
        ism_policy = PolicyTemplate(
            policy=Policy(
                description=self.description,
                default_state=self.default_state,
                states=self.get_policy_states(),
                ism_template=(
                    [self.get_ism_template(self.index_patterns)]
                    if self.index_patterns
                    else []
                ),
            )
        )
        return ism_policy


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate an ISM policy for managing data lifecycle in OpenSearch."
    )
    parser.add_argument(
        "hot_life_span",
        type=int,
        help="Number of days data should remain in the hot tier (required).",
    )
    parser.add_argument(
        "--warm-life-span",
        "-wl",
        type=int,
        help="Number of days data should remain in the warm tier (optional).",
    )
    parser.add_argument(
        "--cold-life-span",
        "-cl",
        type=int,
        help="Number of days data should remain in the cold tier (optional).",
    )
    parser.add_argument(
        "index_patterns", nargs="*", help="List of index names to apply the policy."
    )
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()

    # hot_life_span = args.hot_life_span if args.hot_life_span else args.hot_life_span
    # if args.hot_life_span:
    hot_life_span: int = args.hot_life_span
    warm_life_span: int = args.warm_life_span or 0
    cold_life_span: int = args.cold_life_span or 0
    index_patterns: list[str] = args.index_patterns

    ism_policy = ISMPolicy(
        hot_life_span=hot_life_span,
        warm_life_span=warm_life_span,
        cold_life_span=cold_life_span,
        index_patterns=[pattern.strip() for pattern in index_patterns],
    )
    print(json.dumps(asdict(ism_policy.get_policy()), indent=4))


if __name__ == "__main__":
    main()
