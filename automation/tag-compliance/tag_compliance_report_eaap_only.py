#!/usr/bin/env python3
"""
Generate an Azure tag-compliance CSV report for EAAP resource groups only.
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions


REQUIRED_TAGS = [
    "Project",
    "Environment",
    "ManagedBy",
    "Owner",
    "CostCenter",
    "DataClassification",
    "Criticality",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate an EAAP-only Azure tag-compliance report."
    )
    parser.add_argument(
        "--subscription-id",
        default=os.getenv("AZURE_SUBSCRIPTION_ID"),
        help="Azure subscription ID. Defaults to AZURE_SUBSCRIPTION_ID.",
    )
    parser.add_argument(
        "--resource-group-prefix",
        default="rg-eaap-",
        help='Only include resource groups beginning with this value. Default: "rg-eaap-"',
    )
    parser.add_argument(
        "--include-resource-groups",
        action="store_true",
        help="Include matching resource-group objects in the report.",
    )
    parser.add_argument(
        "--output-directory",
        default="reports",
        help='Directory for generated CSV files. Default: "reports"',
    )
    parser.add_argument(
        "--no-fail-on-noncompliance",
        action="store_true",
        help="Return exit code 0 even when noncompliant resources are found.",
    )
    return parser.parse_args()


def escape_kusto_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "''")


def build_resource_query(resource_group_prefix: str) -> str:
    prefix = escape_kusto_string(resource_group_prefix)
    return f"""
Resources
| where resourceGroup startswith '{prefix}'
| project id, name, type, resourceGroup, location, subscriptionId, tags
| order by resourceGroup asc, type asc, name asc
""".strip()


def build_resource_group_query(resource_group_prefix: str) -> str:
    prefix = escape_kusto_string(resource_group_prefix)
    return f"""
ResourceContainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| where name startswith '{prefix}'
| project id, name, type, resourceGroup = name, location, subscriptionId, tags
| order by name asc
""".strip()


def run_resource_graph_query(
    client: ResourceGraphClient,
    subscription_id: str,
    query: str,
) -> list[dict[str, Any]]:
    request = QueryRequest(
        subscriptions=[subscription_id],
        query=query,
        options=QueryRequestOptions(result_format="objectArray", top=1000),
    )
    response = client.resources(request)
    return list(response.data or [])


def query_eaap_resources(
    subscription_id: str,
    resource_group_prefix: str,
    include_resource_groups: bool,
) -> list[dict[str, Any]]:
    credential = DefaultAzureCredential()
    client = ResourceGraphClient(credential)

    try:
        results = run_resource_graph_query(
            client,
            subscription_id,
            build_resource_query(resource_group_prefix),
        )

        if include_resource_groups:
            results.extend(
                run_resource_graph_query(
                    client,
                    subscription_id,
                    build_resource_group_query(resource_group_prefix),
                )
            )

        return results
    finally:
        close_client = getattr(client, "close", None)
        if callable(close_client):
            close_client()

        close_credential = getattr(credential, "close", None)
        if callable(close_credential):
            close_credential()


def normalize_tags(raw_tags: Any) -> dict[str, str]:
    if not isinstance(raw_tags, dict):
        return {}
    return {
        str(key).strip(): "" if value is None else str(value).strip()
        for key, value in raw_tags.items()
    }


def evaluate_resource(resource: dict[str, Any]) -> dict[str, str]:
    tags = normalize_tags(resource.get("tags"))
    missing_tags = [tag for tag in REQUIRED_TAGS if not tags.get(tag)]

    return {
        "resource_name": str(resource.get("name", "")),
        "resource_type": str(resource.get("type", "")),
        "resource_group": str(resource.get("resourceGroup", "")),
        "location": str(resource.get("location", "")),
        "compliance_status": "Compliant" if not missing_tags else "Noncompliant",
        "missing_tags": "; ".join(missing_tags),
        "resource_id": str(resource.get("id", "")),
    }


def write_csv(rows: list[dict[str, str]], output_directory: str) -> Path:
    output_path = Path(output_directory)
    output_path.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = output_path / f"eaap-tag-compliance-{timestamp}.csv"

    fieldnames = [
        "resource_name",
        "resource_type",
        "resource_group",
        "location",
        "compliance_status",
        "missing_tags",
        "resource_id",
    ]

    with report_path.open("w", newline="", encoding="utf-8-sig") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    return report_path.resolve()


def print_summary(
    rows: list[dict[str, str]],
    report_path: Path,
    resource_group_prefix: str,
) -> None:
    total = len(rows)
    compliant = sum(1 for row in rows if row["compliance_status"] == "Compliant")
    noncompliant = total - compliant
    rate = (compliant / total * 100) if total else 0.0

    print()
    print("EAAP Tag Compliance Summary")
    print("===========================")
    print(f"Resource-group prefix : {resource_group_prefix}")
    print(f"Resources evaluated   : {total}")
    print(f"Compliant resources   : {compliant}")
    print(f"Noncompliant          : {noncompliant}")
    print(f"Compliance rate       : {rate:.2f}%")
    print(f"CSV report            : {report_path}")


def main() -> int:
    args = parse_args()

    if not args.subscription_id:
        print(
            "ERROR: No subscription ID was provided.\n"
            "Set AZURE_SUBSCRIPTION_ID or use --subscription-id.",
            file=sys.stderr,
        )
        return 1

    try:
        resources = query_eaap_resources(
            subscription_id=args.subscription_id,
            resource_group_prefix=args.resource_group_prefix,
            include_resource_groups=args.include_resource_groups,
        )
    except Exception as exc:
        print(f"ERROR: Azure Resource Graph query failed: {exc}", file=sys.stderr)
        return 1

    rows = [evaluate_resource(resource) for resource in resources]
    report_path = write_csv(rows, args.output_directory)
    print_summary(rows, report_path, args.resource_group_prefix)

    noncompliant_count = sum(
        1 for row in rows if row["compliance_status"] == "Noncompliant"
    )

    if noncompliant_count and not args.no_fail_on_noncompliance:
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
