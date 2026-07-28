#!/usr/bin/env python3
"""Report Vertex AI spend from an existing Cloud Billing BigQuery export.

This script uses the already authenticated gcloud and bq CLIs. It never reads or
prints credential files or access tokens, and it never enables APIs, creates an
export, or changes cloud configuration.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable, Optional, Sequence


DEFAULT_MAXIMUM_BYTES_BILLED = 1_073_741_824
BILLING_TABLE_PATTERN = re.compile(
    r"^gcp_billing_export_(?:(resource)_)?v1_([A-Z0-9_]+)$",
    re.IGNORECASE,
)


class DiagnosticError(RuntimeError):
    """A safe, user-facing diagnostic error."""


@dataclass(frozen=True)
class BillingLink:
    enabled: bool
    account_name: Optional[str]

    @property
    def account_id(self) -> Optional[str]:
        if not self.account_name:
            return None
        return self.account_name.rsplit("/", 1)[-1]

    @property
    def table_suffix(self) -> Optional[str]:
        if not self.account_id:
            return None
        return self.account_id.replace("-", "_").upper()


@dataclass(frozen=True)
class BillingTable:
    project_id: str
    dataset_id: str
    table_id: str
    location: str
    partition_field: Optional[str]
    is_time_partitioned: bool

    @property
    def qualified_name(self) -> str:
        return f"{self.project_id}.{self.dataset_id}.{self.table_id}"

    @property
    def is_detailed(self) -> bool:
        return self.table_id.lower().startswith("gcp_billing_export_resource_v1_")


@dataclass
class Discovery:
    billing_datasets: list[str]
    tables: list[BillingTable]
    project_errors: list[str]


def command_json(command: Sequence[str]) -> Any:
    process = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        raise DiagnosticError(safe_cli_error(command[0], process.stdout, process.stderr))
    text = process.stdout.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise DiagnosticError(
            f"{command[0]} returned non-JSON output; cannot inspect it safely ({error})."
        ) from error


def command_text(command: Sequence[str]) -> str:
    process = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        raise DiagnosticError(safe_cli_error(command[0], process.stdout, process.stderr))
    return process.stdout.strip()


def safe_cli_error(program: str, stdout: str, stderr: str) -> str:
    lines = [
        line.strip()
        for line in f"{stdout}\n{stderr}".splitlines()
        if line.strip()
        and not line.startswith("WARNING:")
        and "Python 3.9" not in line
        and "Cloud CLI" not in line
    ]
    message = " ".join(lines[-4:])[:500]
    return f"{program} failed: {message or 'no safe diagnostic text was returned'}"


def active_project(explicit_project: Optional[str]) -> str:
    if explicit_project:
        return explicit_project
    project_id = command_text(["gcloud", "config", "get-value", "project"])
    if not project_id or project_id == "(unset)":
        raise DiagnosticError(
            "No active gcloud project is configured. Pass --project PROJECT_ID."
        )
    return project_id


def active_account() -> str:
    try:
        return command_text(
            [
                "gcloud",
                "auth",
                "list",
                "--filter=status:ACTIVE",
                "--format=value(account)",
            ]
        )
    except DiagnosticError:
        return "(not available)"


def billing_link(project_id: str) -> BillingLink:
    payload = command_json(
        [
            "gcloud",
            "billing",
            "projects",
            "describe",
            project_id,
            "--format=json(projectId,billingEnabled,billingAccountName)",
        ]
    )
    if not isinstance(payload, dict):
        raise DiagnosticError("Cloud Billing returned no project metadata.")
    return BillingLink(
        enabled=bool(payload.get("billingEnabled")),
        account_name=payload.get("billingAccountName"),
    )


def accessible_projects(target_project: str) -> list[str]:
    projects = {target_project}
    try:
        payload = command_json(
            [
                "gcloud",
                "projects",
                "list",
                "--filter=lifecycleState:ACTIVE",
                "--format=json(projectId)",
            ]
        )
    except DiagnosticError:
        return sorted(projects)
    if isinstance(payload, list):
        for item in payload:
            if isinstance(item, dict) and item.get("projectId"):
                projects.add(str(item["projectId"]))
    return sorted(projects)


def discover_billing_tables(
    projects: Iterable[str],
    expected_suffix: Optional[str],
) -> Discovery:
    result = Discovery(billing_datasets=[], tables=[], project_errors=[])
    for project_id in projects:
        try:
            datasets = command_json(
                [
                    "bq",
                    "ls",
                    "--format=prettyjson",
                    f"--project_id={project_id}",
                ]
            )
        except DiagnosticError as error:
            result.project_errors.append(f"{project_id}: {error}")
            continue

        if not isinstance(datasets, list):
            continue
        for dataset in datasets:
            if not isinstance(dataset, dict):
                continue
            reference = dataset.get("datasetReference") or {}
            dataset_id = reference.get("datasetId")
            if not dataset_id:
                continue
            dataset_project = reference.get("projectId") or project_id
            location = str(dataset.get("location") or "")
            if "billing" in dataset_id.lower():
                result.billing_datasets.append(f"{dataset_project}.{dataset_id}")

            try:
                tables = command_json(
                    [
                        "bq",
                        "ls",
                        "--format=prettyjson",
                        f"--project_id={dataset_project}",
                        dataset_id,
                    ]
                )
            except DiagnosticError:
                continue
            if not isinstance(tables, list):
                continue

            for table in tables:
                if not isinstance(table, dict):
                    continue
                table_reference = table.get("tableReference") or {}
                table_id = table_reference.get("tableId")
                if not table_id:
                    continue
                match = BILLING_TABLE_PATTERN.fullmatch(table_id)
                if not match:
                    continue
                if expected_suffix and match.group(2).upper() != expected_suffix:
                    continue

                metadata = table_metadata(
                    dataset_project,
                    dataset_id,
                    table_id,
                )
                time_partitioning = metadata.get("timePartitioning") or {}
                result.tables.append(
                    BillingTable(
                        project_id=dataset_project,
                        dataset_id=dataset_id,
                        table_id=table_id,
                        location=str(metadata.get("location") or location or "US"),
                        partition_field=time_partitioning.get("field"),
                        is_time_partitioned=bool(time_partitioning),
                    )
                )
    result.tables.sort(key=lambda table: (table.is_detailed, table.qualified_name))
    result.billing_datasets = sorted(set(result.billing_datasets))
    return result


def table_metadata(project_id: str, dataset_id: str, table_id: str) -> dict[str, Any]:
    payload = command_json(
        [
            "bq",
            "show",
            "--format=prettyjson",
            f"{project_id}:{dataset_id}.{table_id}",
        ]
    )
    return payload if isinstance(payload, dict) else {}


def validate_identifier(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        raise DiagnosticError(f"Unsafe BigQuery identifier discovered: {value!r}")
    return value


def build_query(table: BillingTable) -> str:
    qualified_name = validate_identifier(table.qualified_name)
    partition_clause = ""
    if table.is_time_partitioned:
        partition_expression = (
            validate_identifier(table.partition_field)
            if table.partition_field
            else "_PARTITIONTIME"
        )
        partition_clause = f"""
    AND DATE({partition_expression}) >= @partition_start
    AND DATE({partition_expression}) < @partition_end"""

    return f"""
WITH vertex_rows AS (
  SELECT
    currency,
    CAST(cost AS NUMERIC) AS gross_cost,
    COALESCE(
      (SELECT SUM(CAST(credit.amount AS NUMERIC)) FROM UNNEST(credits) AS credit),
      NUMERIC '0'
    ) AS credits
  FROM `{qualified_name}`
  WHERE project.id = @target_project
    AND service.description = 'Vertex AI'
    AND DATE(usage_start_time, 'UTC') >= @start_date
    AND DATE(usage_start_time, 'UTC') < @end_date{partition_clause}
)
SELECT
  currency,
  ROUND(SUM(gross_cost), 6) AS gross_cost,
  ROUND(SUM(credits), 6) AS credits,
  ROUND(SUM(gross_cost + credits), 6) AS net_spend,
  COUNT(*) AS billing_rows
FROM vertex_rows
GROUP BY currency
ORDER BY currency
""".strip()


def query_arguments(
    table: BillingTable,
    target_project: str,
    start_date: date,
    end_date: date,
) -> list[str]:
    arguments = [
        f"--project_id={table.project_id}",
        f"--location={table.location}",
        "--use_legacy_sql=false",
        "--parameter",
        f"target_project:STRING:{target_project}",
        "--parameter",
        f"start_date:DATE:{start_date.isoformat()}",
        "--parameter",
        f"end_date:DATE:{end_date.isoformat()}",
    ]
    if table.is_time_partitioned:
        arguments.extend(
            [
                "--parameter",
                f"partition_start:DATE:{(start_date - timedelta(days=7)).isoformat()}",
                "--parameter",
                f"partition_end:DATE:{(end_date + timedelta(days=7)).isoformat()}",
            ]
        )
    return arguments


def dry_run_bytes(
    table: BillingTable,
    target_project: str,
    start_date: date,
    end_date: date,
    query: str,
) -> int:
    process = subprocess.run(
        [
            "bq",
            "query",
            *query_arguments(table, target_project, start_date, end_date),
            "--dry_run",
            query,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        raise DiagnosticError(safe_cli_error("bq", process.stdout, process.stderr))
    output = f"{process.stdout}\n{process.stderr}"
    match = re.search(r"process ([0-9,]+) bytes", output, re.IGNORECASE)
    if not match:
        match = re.search(r'"totalBytesProcessed"\s*:\s*"?([0-9]+)"?', output)
    if not match:
        raise DiagnosticError("BigQuery validated the query but did not report byte usage.")
    return int(match.group(1).replace(",", ""))


def execute_query(
    table: BillingTable,
    target_project: str,
    start_date: date,
    end_date: date,
    query: str,
    maximum_bytes_billed: int,
) -> list[dict[str, Any]]:
    payload = command_json(
        [
            "bq",
            "query",
            *query_arguments(table, target_project, start_date, end_date),
            "--format=prettyjson",
            "--use_cache=false",
            f"--maximum_bytes_billed={maximum_bytes_billed}",
            query,
        ]
    )
    return payload if isinstance(payload, list) else []


def print_results(
    rows: list[dict[str, Any]],
    start_date: date,
    end_date: date,
) -> None:
    print(f"Vertex AI usage window: {start_date} through {end_date - timedelta(days=1)} (UTC)")
    if not rows:
        print("Actual Vertex AI spend: 0.00 (no matching billing rows)")
        return
    for row in rows:
        currency = str(row.get("currency") or "")
        gross = Decimal(str(row.get("gross_cost") or "0"))
        credits = Decimal(str(row.get("credits") or "0"))
        net = Decimal(str(row.get("net_spend") or "0"))
        count = row.get("billing_rows") or 0
        print(
            f"Actual Vertex AI spend ({currency}): {net:.6f} net "
            f"({gross:.6f} gross + {credits:.6f} credits; {count} billing rows)"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Discover an existing Cloud Billing BigQuery export and report "
            "Vertex AI spend for the last 30 complete UTC calendar days."
        )
    )
    parser.add_argument("--project", help="Target project; defaults to active gcloud project.")
    parser.add_argument(
        "--diagnose-only",
        action="store_true",
        help="Discover export state but do not submit a spend query.",
    )
    parser.add_argument(
        "--maximum-bytes-billed",
        type=int,
        default=DEFAULT_MAXIMUM_BYTES_BILLED,
        help="Hard BigQuery query cap in bytes (default: 1 GiB).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for program in ("gcloud", "bq"):
        if not shutil.which(program):
            print(f"BLOCKED: required command not found: {program}", file=sys.stderr)
            return 2

    try:
        target_project = active_project(args.project)
        link = billing_link(target_project)
        projects = accessible_projects(target_project)
        discovery = discover_billing_tables(projects, link.table_suffix)
    except DiagnosticError as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2

    print(f"Active identity: {active_account() or '(none)'}")
    print(f"Target project: {target_project}")
    print(f"Billing enabled: {'yes' if link.enabled else 'no'}")
    print(f"Billing account: {link.account_id or '(not visible)'}")
    print(f"Accessible projects inspected: {len(projects)}")
    if discovery.billing_datasets:
        print("Billing-named datasets: " + ", ".join(discovery.billing_datasets))
    else:
        print("Billing-named datasets: none found")

    if not link.enabled:
        print("BLOCKED: billing is not enabled for the target project.", file=sys.stderr)
        return 2
    if not discovery.tables:
        print(
            "BLOCKED: no accessible Cloud Billing export table for this billing "
            "account was found. No spend query was run and no cloud setting was changed.",
            file=sys.stderr,
        )
        if discovery.billing_datasets:
            print(
                "A billing-named dataset exists, but it currently contains no matching "
                "gcp_billing_export_v1_* or gcp_billing_export_resource_v1_* table.",
                file=sys.stderr,
            )
        return 2

    table = discovery.tables[0]
    print(f"Billing table: {table.qualified_name} ({table.location})")
    if args.diagnose_only:
        print("Diagnostic mode: query not submitted.")
        return 0

    end_date = datetime.now(timezone.utc).date()
    start_date = end_date - timedelta(days=30)
    query = build_query(table)
    try:
        processed_bytes = dry_run_bytes(
            table,
            target_project,
            start_date,
            end_date,
            query,
        )
    except DiagnosticError as error:
        print(f"BLOCKED: query dry-run failed: {error}", file=sys.stderr)
        return 2

    print(f"Dry-run bytes: {processed_bytes}")
    if processed_bytes > args.maximum_bytes_billed:
        print(
            "BLOCKED: dry-run exceeds --maximum-bytes-billed; no billed query was run.",
            file=sys.stderr,
        )
        return 2

    try:
        rows = execute_query(
            table,
            target_project,
            start_date,
            end_date,
            query,
            args.maximum_bytes_billed,
        )
    except DiagnosticError as error:
        print(f"BLOCKED: spend query failed: {error}", file=sys.stderr)
        return 2
    print_results(rows, start_date, end_date)
    print(
        "Caveat: this includes Cloud Billing rows whose service is exactly "
        "'Vertex AI'; related storage, networking, support, tax, and late-arriving "
        "export corrections may appear elsewhere or later."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
