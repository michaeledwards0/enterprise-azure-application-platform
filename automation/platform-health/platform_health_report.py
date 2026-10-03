from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential
from azure.monitor.query import LogsQueryClient, LogsQueryStatus


STATUS_ORDER = {"Healthy": 0, "Warning": 1, "Critical": 2}


@dataclass
class CheckResult:
    name: str
    scope: str
    status: str
    summary: str
    details: list[dict[str, Any]] = field(default_factory=list)
    query_warning: str | None = None


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a read-only Azure Monitor health report for an AKS cluster "
            "and a Kubernetes namespace."
        )
    )
    parser.add_argument(
        "--workspace-id",
        required=True,
        help="Log Analytics Workspace ID (customer ID), not the Azure resource ID.",
    )
    parser.add_argument(
        "--namespace",
        default="eaap-app",
        help="Kubernetes namespace to assess. Default: eaap-app.",
    )
    parser.add_argument(
        "--time-window-hours",
        type=int,
        default=1,
        help="How far back to query telemetry. Default: 1.",
    )
    parser.add_argument(
        "--expected-running-pods",
        type=int,
        default=2,
        help="Minimum expected running pods in the application namespace. Default: 2.",
    )
    parser.add_argument(
        "--restart-warning-threshold",
        type=int,
        default=1,
        help="Restart count that produces a warning. Default: 1.",
    )
    parser.add_argument(
        "--reports-directory",
        default="reports",
        help="Directory for generated JSON and Markdown reports. Default: reports.",
    )
    return parser.parse_args()


def normalize_value(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (str, int, float, bool)):
        return value
    return str(value)


def rows_from_response(response: Any) -> tuple[list[dict[str, Any]], str | None]:
    if response.status == LogsQueryStatus.SUCCESS:
        tables = response.tables
        warning = None
    elif response.status == LogsQueryStatus.PARTIAL:
        tables = response.partial_data
        partial_error = getattr(response, "partial_error", None)
        warning = getattr(
            partial_error,
            "message",
            "The query returned partial data.",
        )
    else:
        return [], "The query did not return a usable result."

    rows: list[dict[str, Any]] = []

    for table in tables or []:
        columns = [
            column if isinstance(column, str) else column.name
            for column in table.columns
        ]

        for row in table.rows:
            rows.append(
                {
                    column_name: normalize_value(value)
                    for column_name, value in zip(columns, row)
                }
            )

    return rows, warning


def run_query(
    client: LogsQueryClient,
    workspace_id: str,
    query: str,
    hours: int,
) -> tuple[list[dict[str, Any]], str | None]:
    try:
        response = client.query_workspace(
            workspace_id=workspace_id,
            query=query,
            timespan=timedelta(hours=hours),
            server_timeout=120,
        )
        return rows_from_response(response)
    except HttpResponseError as error:
        return [], f"{type(error).__name__}: {error.message or str(error)}"
    except Exception as error:
        return [], f"{type(error).__name__}: {error}"


def status_from_checks(checks: list[CheckResult]) -> str:
    return max(checks, key=lambda check: STATUS_ORDER[check.status]).status


def count_as_int(row: dict[str, Any], field_name: str) -> int:
    value = row.get(field_name, 0)
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def kql_escape(value: str) -> str:
    return value.replace("'", "''")


def build_checks(
    client: LogsQueryClient,
    workspace_id: str,
    namespace: str,
    hours: int,
    expected_running_pods: int,
    restart_warning_threshold: int,
) -> list[CheckResult]:
    namespace_literal = kql_escape(namespace)
    checks: list[CheckResult] = []

    node_query = f"""
KubeNodeInventory
| where TimeGenerated >= ago({hours}h)
| summarize arg_max(TimeGenerated, Status) by Computer
| project Node=Computer, Status
| order by Node asc
"""
    node_rows, node_warning = run_query(
    client,
    workspace_id,
    node_query,
    hours,
)
    unhealthy_nodes = [
        row for row in node_rows if str(row.get("Status", "")).lower() != "ready"
    ]

    if node_warning:
        node_status = "Warning"
        node_summary = (
            "Node inventory query was incomplete or unavailable; cluster node health "
            "cannot be fully confirmed."
        )
    elif not node_rows:
        node_status = "Warning"
        node_summary = "No recent node inventory was returned by Log Analytics."
    elif unhealthy_nodes:
        node_status = "Critical"
        node_summary = (
            f"{len(unhealthy_nodes)} of {len(node_rows)} observed nodes were not Ready."
        )
    else:
        node_status = "Healthy"
        node_summary = f"All {len(node_rows)} observed nodes reported Ready."

    checks.append(
        CheckResult(
            name="AKS node readiness",
            scope="AKS cluster",
            status=node_status,
            summary=node_summary,
            details=unhealthy_nodes if unhealthy_nodes else node_rows,
            query_warning=node_warning,
        )
    )

    pod_query = f"""
KubePodInventory
| where TimeGenerated >= ago({hours}h)
| where Namespace == '{namespace_literal}'
| summarize arg_max(TimeGenerated, PodStatus, ContainerStatus, ContainerRestartCount) by Name
| project Pod=Name, PodStatus, ContainerStatus, ContainerRestartCount
| order by Pod asc
"""
    pod_rows, pod_warning = run_query(
    client,
    workspace_id,
    pod_query,
    hours,
)
    running_pods = [
        row for row in pod_rows
        if str(row.get("PodStatus", "")).lower() == "running"
    ]
    unhealthy_pods = [
        row for row in pod_rows
        if str(row.get("PodStatus", "")).lower() not in {"running", "succeeded"}
    ]

    if pod_warning:
        pod_status = "Warning"
        pod_summary = (
            "Pod inventory query was incomplete or unavailable; application health "
            "cannot be fully confirmed."
        )
    elif not pod_rows:
        pod_status = "Critical"
        pod_summary = f"No recent pod inventory was returned for namespace '{namespace}'."
    elif unhealthy_pods:
        pod_status = "Critical"
        pod_summary = (
            f"{len(unhealthy_pods)} pod record(s) in '{namespace}' were not Running "
            "or Succeeded."
        )
    elif len(running_pods) < expected_running_pods:
        pod_status = "Critical"
        pod_summary = (
            f"Only {len(running_pods)} Running pod record(s) were observed in "
            f"'{namespace}'; expected at least {expected_running_pods}."
        )
    else:
        pod_status = "Healthy"
        pod_summary = (
            f"{len(running_pods)} Running pod record(s) were observed in '{namespace}'."
        )

    checks.append(
        CheckResult(
            name="Application pod availability",
            scope=namespace,
            status=pod_status,
            summary=pod_summary,
            details=unhealthy_pods if unhealthy_pods else running_pods,
            query_warning=pod_warning,
        )
    )

    restart_query = f"""
KubePodInventory
| where TimeGenerated >= ago({hours}h)
| where Namespace == '{namespace_literal}'
| summarize arg_max(TimeGenerated, ContainerRestartCount, PodStatus) by Name, ContainerName
| where toint(ContainerRestartCount) >= {restart_warning_threshold}
| project Pod=Name, Container=ContainerName, PodStatus, ContainerRestartCount
| order by toint(ContainerRestartCount) desc
"""
    restart_rows, restart_warning = run_query(
    client,
    workspace_id,
    restart_query,
    hours,
)

    if restart_warning:
        restart_status = "Warning"
        restart_summary = (
            "Container restart query was incomplete or unavailable; restart health "
            "cannot be fully confirmed."
        )
    elif restart_rows:
        restart_status = "Warning"
        restart_summary = (
            f"{len(restart_rows)} container record(s) met or exceeded the restart "
            f"threshold of {restart_warning_threshold}."
        )
    else:
        restart_status = "Healthy"
        restart_summary = (
            f"No containers met or exceeded the restart threshold of "
            f"{restart_warning_threshold}."
        )

    checks.append(
        CheckResult(
            name="Application container restarts",
            scope=namespace,
            status=restart_status,
            summary=restart_summary,
            details=restart_rows,
            query_warning=restart_warning,
        )
    )

    event_query = f"""
KubeEvents
| where TimeGenerated >= ago({hours}h)
| where Namespace == '{namespace_literal}'
| where Type =~ 'Warning'
| project TimeGenerated, Name, Reason, Message
| order by TimeGenerated desc
| take 50
"""
    event_rows, event_warning = run_query(
    client,
    workspace_id,
    event_query,
    hours,
)

    if event_warning:
        event_status = "Warning"
        event_summary = (
            "Kubernetes warning-event query was incomplete or unavailable. "
            "This table can also be empty when no collected events exist."
        )
    elif event_rows:
        event_status = "Warning"
        event_summary = (
            f"{len(event_rows)} recent Kubernetes Warning event(s) were found "
            f"in '{namespace}'."
        )
    else:
        event_status = "Healthy"
        event_summary = f"No recent collected Kubernetes Warning events were found in '{namespace}'."

    checks.append(
        CheckResult(
            name="Kubernetes warning events",
            scope=namespace,
            status=event_status,
            summary=event_summary,
            details=event_rows,
            query_warning=event_warning,
        )
    )

    application_error_query = f"""
ContainerLogV2
| where TimeGenerated >= ago({hours}h)
| where PodNamespace == '{namespace_literal}'
| where LogMessage matches regex @"(?i)\\b(error|exception|fatal|panic|fail(ed|ure)?)\\b"
| project TimeGenerated, PodName, ContainerName, LogMessage
| order by TimeGenerated desc
| take 50
"""
    app_error_rows, app_error_warning = run_query(
    client,
    workspace_id,
    application_error_query,
    hours,
)

    if app_error_warning:
        app_error_status = "Warning"
        app_error_summary = (
            "Application log-error query was incomplete or unavailable; application "
            "log health cannot be fully confirmed."
        )
    elif app_error_rows:
        app_error_status = "Warning"
        app_error_summary = (
            f"{len(app_error_rows)} recent log line(s) matched the configured "
            "error pattern."
        )
    else:
        app_error_status = "Healthy"
        app_error_summary = "No recent application log lines matched the configured error pattern."

    checks.append(
        CheckResult(
            name="Application log error patterns",
            scope=namespace,
            status=app_error_status,
            summary=app_error_summary,
            details=app_error_rows,
            query_warning=app_error_warning,
        )
    )

    control_plane_query = f"""
AKSControlPlane
| where TimeGenerated >= ago({hours}h)
| where tostring(Level) in~ ('error', 'critical', 'fatal')
| project TimeGenerated, Category, Level, Message
| order by TimeGenerated desc
| take 50
"""
    control_plane_rows, control_plane_warning = run_query(
    client,
    workspace_id,
    control_plane_query,
    hours,
)

    if control_plane_warning:
        control_plane_status = "Warning"
        control_plane_summary = (
            "AKS control-plane query was incomplete or unavailable; control-plane "
            "health cannot be fully confirmed."
        )
    elif control_plane_rows:
        control_plane_status = "Warning"
        control_plane_summary = (
            f"{len(control_plane_rows)} recent AKS control-plane error record(s) "
            "were found."
        )
    else:
        control_plane_status = "Healthy"
        control_plane_summary = "No recent AKS control-plane error records were found."

    checks.append(
        CheckResult(
            name="AKS control-plane errors",
            scope="AKS cluster",
            status=control_plane_status,
            summary=control_plane_summary,
            details=control_plane_rows,
            query_warning=control_plane_warning,
        )
    )

    return checks


def markdown_table(rows: list[dict[str, Any]], limit: int = 10) -> str:
    if not rows:
        return "_No matching records._"

    shown_rows = rows[:limit]
    columns = list(shown_rows[0].keys())
    header = "| " + " | ".join(columns) + " |"
    separator = "| " + " | ".join("---" for _ in columns) + " |"
    body = []

    for row in shown_rows:
        values = []
        for column in columns:
            value = str(row.get(column, "")).replace("|", "\\|").replace("\n", " ")
            if len(value) > 180:
                value = value[:177] + "..."
            values.append(value)
        body.append("| " + " | ".join(values) + " |")

    suffix = ""
    if len(rows) > limit:
        suffix = f"\n\n_Showing {limit} of {len(rows)} records._"

    return "\n".join([header, separator, *body]) + suffix


def report_to_dict(
    generated_at: str,
    workspace_id: str,
    namespace: str,
    hours: int,
    expected_running_pods: int,
    restart_warning_threshold: int,
    checks: list[CheckResult],
) -> dict[str, Any]:
    overall_status = status_from_checks(checks)
    return {
        "report_name": "EAAP Platform Health Report",
        "generated_at_utc": generated_at,
        "overall_status": overall_status,
        "configuration": {
            "workspace_id": workspace_id,
            "namespace": namespace,
            "time_window_hours": hours,
            "expected_running_pods": expected_running_pods,
            "restart_warning_threshold": restart_warning_threshold,
        },
        "summary": {
            "healthy": sum(check.status == "Healthy" for check in checks),
            "warning": sum(check.status == "Warning" for check in checks),
            "critical": sum(check.status == "Critical" for check in checks),
        },
        "checks": [
            {
                "name": check.name,
                "scope": check.scope,
                "status": check.status,
                "summary": check.summary,
                "query_warning": check.query_warning,
                "details": check.details,
            }
            for check in checks
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    configuration = report["configuration"]
    summary = report["summary"]

    lines = [
        "# EAAP Platform Health Report",
        "",
        f"**Overall status:** {report['overall_status']}",
        "",
        "## Report context",
        "",
        f"- Generated (UTC): {report['generated_at_utc']}",
        f"- Kubernetes namespace: `{configuration['namespace']}`",
        f"- Health window: previous {configuration['time_window_hours']} hour(s)",
        f"- Expected running pods: {configuration['expected_running_pods']}",
        f"- Restart warning threshold: {configuration['restart_warning_threshold']}",
        "",
        "## Summary",
        "",
        "| Healthy | Warning | Critical |",
        "| --- | --- | --- |",
        f"| {summary['healthy']} | {summary['warning']} | {summary['critical']} |",
        "",
        "## Checks",
        "",
        "| Check | Scope | Status | Summary |",
        "| --- | --- | --- | --- |",
    ]

    for check in report["checks"]:
        lines.append(
            f"| {check['name']} | {check['scope']} | {check['status']} | "
            f"{check['summary']} |"
        )

    for check in report["checks"]:
        lines.extend(
            [
                "",
                f"## {check['name']}",
                "",
                f"- Scope: `{check['scope']}`",
                f"- Status: {check['status']}",
                f"- Summary: {check['summary']}",
            ]
        )

        if check["query_warning"]:
            lines.extend(
                [
                    f"- Query note: {check['query_warning']}",
                ]
            )

        lines.extend(
            [
                "",
                "### Matching records",
                "",
                markdown_table(check["details"]),
            ]
        )

    lines.extend(
        [
            "",
            "## Interpretation",
            "",
            "- Healthy means the query completed and did not identify the configured issue.",
            "- Warning means the reporter found a non-critical signal or could not fully verify a telemetry source.",
            "- Critical means the reporter found a direct availability concern, such as unhealthy AKS nodes, unhealthy application pods, or too few Running pods.",
            "- This is a read-only report. It does not change Azure, AKS, Terraform, or GitHub resources.",
            "",
        ]
    )

    return "\n".join(lines)


def write_reports(
    reports_directory: Path,
    report: dict[str, Any],
) -> tuple[Path, Path]:
    reports_directory.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    json_path = reports_directory / f"eaap-platform-health-{timestamp}.json"
    markdown_path = reports_directory / f"eaap-platform-health-{timestamp}.md"

    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")

    return json_path, markdown_path


def main() -> int:
    args = parse_arguments()

    if args.time_window_hours <= 0:
        print("--time-window-hours must be greater than zero.", file=sys.stderr)
        return 2

    if args.expected_running_pods <= 0:
        print("--expected-running-pods must be greater than zero.", file=sys.stderr)
        return 2

    if args.restart_warning_threshold < 0:
        print("--restart-warning-threshold cannot be negative.", file=sys.stderr)
        return 2

    credential = DefaultAzureCredential()
    client = LogsQueryClient(credential)

    checks = build_checks(
        client=client,
        workspace_id=args.workspace_id,
        namespace=args.namespace,
        hours=args.time_window_hours,
        expected_running_pods=args.expected_running_pods,
        restart_warning_threshold=args.restart_warning_threshold,
    )

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    report = report_to_dict(
        generated_at=generated_at,
        workspace_id=args.workspace_id,
        namespace=args.namespace,
        hours=args.time_window_hours,
        expected_running_pods=args.expected_running_pods,
        restart_warning_threshold=args.restart_warning_threshold,
        checks=checks,
    )

    json_path, markdown_path = write_reports(
        Path(args.reports_directory),
        report,
    )

    print(f"EAAP platform health status: {report['overall_status']}")
    print(
        "Checks: "
        f"{report['summary']['healthy']} Healthy, "
        f"{report['summary']['warning']} Warning, "
        f"{report['summary']['critical']} Critical"
    )
    print(f"JSON report: {json_path}")
    print(f"Markdown report: {markdown_path}")

    if report["overall_status"] == "Healthy":
        return 0
    if report["overall_status"] == "Warning":
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())