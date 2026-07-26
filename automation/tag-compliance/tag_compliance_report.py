#!/usr/bin/env python3
"""Generate an Azure tag-compliance CSV report with Azure Resource Graph."""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
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
        description="Check Azure resources for the required EAAP tags."
    )

    parser.add_argument(
        "--include-resource-groups",
        action="store_true",
        help="Include Azure resource groups in the compliance check.",
    )

    parser.add_argument(
        "--no-fail-on-noncompliance",
        action="store_true",
        help="Return exit code 0 even when missing tags are found.",
    )

    parser.add_argument(
        "--subscription-id",
        help=(
            "Azure subscription ID. When omitted, the script checks "
            "AZURE_SUBSCRIPTION_ID, ARM_SUBSCRIPTION_ID, and Azure CLI."
        ),
    )

    parser.add_argument(
        "--output-dir",
        default="reports",
        help="Directory where the CSV report will be written. Default: reports",
    )

    return parser.parse_args()


def get_subscription_id(explicit_id: str | None) -> str:
    """Find the subscription ID to evaluate."""

    possible_ids = [
        explicit_id,
        os.getenv("AZURE_SUBSCRIPTION_ID"),
        os.getenv("ARM_SUBSCRIPTION_ID"),
    ]

    for subscription_id in possible_ids:
        if subscription_id and subscription_id.strip():
            return subscription_id.strip()

    try:
        result = subprocess.run(
            ["az", "account", "show", "--query", "id", "--output", "tsv"],
            check=True,
            capture_output=True,
            text=True,
        )

        subscription_id = result.stdout.strip()

        if subscription_id:
            return subscription_id

    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(
            "Could not determine the Azure subscription ID. "
            "Run 'az login' and select a subscription, or set "
            "AZURE_SUBSCRIPTION_ID."
        ) from exc

    raise RuntimeError("The Azure subscription ID could not be determined.")


def build_resource_query() -> str:
    """Return the query used to retrieve Azure resources."""

    return """
Resources
| project
    id,
    name,
    type,
    location,
    resourceGroup,
    subscriptionId,
    tags
| order by type asc, name asc
""".strip()


def build_resource_group_query() -> str:
    """Return the query used to retrieve Azure resource groups."""

    return """
ResourceContainers
| where type =~ "microsoft.resources/subscriptions/resourcegroups"
| project
    id,
    name,
    type,
    location,
    resourceGroup = name,
    subscriptionId,
    tags
| order by name asc
""".strip()


def normalize_tags(tags: Any) -> dict[str, str]:
    """Convert Azure tags into a case-insensitive dictionary."""

    if not isinstance(tags, dict):
        return {}

    normalized: dict[str, str] = {}

    for key, value in tags.items():
        normalized[str(key).casefold()] = (
            "" if value is None else str(value).strip()
        )

    return normalized


def evaluate_resource(resource: dict[str, Any]) -> dict[str, Any]:
    """Check one Azure resource for the required tags."""

    tags = normalize_tags(resource.get("tags"))

    missing_tags = [
        required_tag
        for required_tag in REQUIRED_TAGS
        if not tags.get(required_tag.casefold())
    ]

    return {
        "subscription_id": resource.get("subscriptionId", ""),
        "resource_group": resource.get("resourceGroup", ""),
        "resource_name": resource.get("name", ""),
        "resource_type": resource.get("type", ""),
        "location": resource.get("location", ""),
        "resource_id": resource.get("id", ""),
        "compliance_status": (
            "Compliant" if not missing_tags else "Noncompliant"
        ),
        "missing_tags": "; ".join(missing_tags),
        **{
            f"tag_{required_tag}": tags.get(required_tag.casefold(), "")
            for required_tag in REQUIRED_TAGS
        },
    }


def run_resource_graph_query(
    client: ResourceGraphClient,
    subscription_id: str,
    query: str,
) -> list[dict[str, Any]]:
    """Run one Azure Resource Graph query."""

    request = QueryRequest(
        subscriptions=[subscription_id],
        query=query,
        options=QueryRequestOptions(
            result_format="objectArray",
            top=1000,
        ),
    )

    response = client.resources(request)

    return list(response.data or [])


def query_resources(
    subscription_id: str,
    include_resource_groups: bool,
) -> list[dict[str, Any]]:
    """Retrieve Azure resources and optionally resource groups."""

    credential = DefaultAzureCredential()
    client = ResourceGraphClient(credential)

    try:
        results = run_resource_graph_query(
            client=client,
            subscription_id=subscription_id,
            query=build_resource_query(),
        )

        if include_resource_groups:
            resource_groups = run_resource_graph_query(
                client=client,
                subscription_id=subscription_id,
                query=build_resource_group_query(),
            )

            results.extend(resource_groups)

        return results

    finally:
        client.close()
        credential.close()


def write_csv(
    rows: list[dict[str, Any]],
    output_dir: str,
) -> Path:
    """Write the compliance results to a timestamped CSV file."""

    report_directory = Path(output_dir)
    report_directory.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    report_path = (
        report_directory
        / f"azure-tag-compliance-{timestamp}.csv"
    )

    fieldnames = [
        "subscription_id",
        "resource_group",
        "resource_name",
        "resource_type",
        "location",
        "resource_id",
        "compliance_status",
        "missing_tags",
        *[f"tag_{tag}" for tag in REQUIRED_TAGS],
    ]

    with report_path.open(
        "w",
        newline="",
        encoding="utf-8-sig",
    ) as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=fieldnames,
        )

        writer.writeheader()
        writer.writerows(rows)

    return report_path.resolve()


def print_summary(
    rows: list[dict[str, Any]],
    report_path: Path,
) -> None:
    """Display the compliance results in the terminal."""

    total_resources = len(rows)

    compliant_resources = sum(
        row["compliance_status"] == "Compliant"
        for row in rows
    )

    noncompliant_resources = (
        total_resources - compliant_resources
    )

    compliance_rate = (
        compliant_resources / total_resources * 100
        if total_resources
        else 100.0
    )

    print()
    print("Azure Tag Compliance Summary")
    print("============================")
    print(f"Resources evaluated : {total_resources}")
    print(f"Compliant resources : {compliant_resources}")
    print(f"Noncompliant        : {noncompliant_resources}")
    print(f"Compliance rate     : {compliance_rate:.2f}%")
    print(f"CSV report          : {report_path}")


def main() -> int:
    """Run the compliance report."""

    args = parse_args()

    try:
        subscription_id = get_subscription_id(
            args.subscription_id
        )

        resources = query_resources(
            subscription_id=subscription_id,
            include_resource_groups=args.include_resource_groups,
        )

        rows = [
            evaluate_resource(resource)
            for resource in resources
        ]

        report_path = write_csv(
            rows=rows,
            output_dir=args.output_dir,
        )

        print_summary(
            rows=rows,
            report_path=report_path,
        )

    except Exception as exc:
        print(
            f"ERROR: {exc}",
            file=sys.stderr,
        )

        return 1

    has_noncompliance = any(
        row["compliance_status"] == "Noncompliant"
        for row in rows
    )

    if (
        has_noncompliance
        and not args.no_fail_on_noncompliance
    ):
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())