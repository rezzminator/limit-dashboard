#!/usr/bin/env python3
"""Bucketed Vertex AI token usage and estimated EUR list-price report.

The report reads the DELTA metric
`aiplatform.googleapis.com/publisher/online_serving/token_count` from Cloud
Monitoring and prices those tokens with the public Cloud Billing Catalog.

Authentication comes from `gcloud auth print-access-token`. The token is kept
in memory only, sent only to Google APIs, and is never printed or cached.
All API calls are read-only.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time as datetime_time, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Optional, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


METRIC = "aiplatform.googleapis.com/publisher/online_serving/token_count"
MONITORING_API = "https://monitoring.googleapis.com/v3/projects/{project}/timeSeries"
CATALOG_API = "https://cloudbilling.googleapis.com/v1/services/{service}/skus"
VERTEX_SERVICE_ID = "C7E2-9256-1C43"
SOURCE_ALIGNMENT_SECONDS = 60
DEFAULT_PRICE_CACHE = (
    Path(tempfile.gettempdir()) / "limit-dashboard-vertex-prices-eur.json"
)
DEFAULT_PRICE_CACHE_TTL = 24 * 60 * 60
CACHED_INPUT_FACTOR = 0.25

# Model prefix -> exact public Catalog SKU descriptions.
SKU_MAP: dict[str, tuple[str, str]] = {
    "gemini-2.5-flash-lite": (
        "Gemini 2.5 Flash Lite Text Input - Predictions",
        "Gemini 2.5 Flash Lite Text Output - Predictions",
    ),
    "gemini-2.5-flash": (
        "Gemini 2.5 Flash GA Text Input - Predictions",
        "Gemini 2.5 Flash GA Text Output - Predictions",
    ),
    "gemini-2.5-pro": (
        "Gemini 2.5 Pro Text Input - Predictions",
        "Gemini 2.5 Pro Text Output - Predictions",
    ),
    "gemini-3.5-flash": (
        "Gemini 3.5 Flash Regional Text Input - Predictions",
        "Gemini 3.5 Flash Regional Text Output - Predictions",
    ),
}

# EUR per one million tokens. These are emergency fallbacks supplied with the
# project, not live prices. Any use is reported prominently.
EMBEDDED_FALLBACK_EUR: dict[str, tuple[float, float]] = {
    "gemini-2.5-flash-lite": (0.093, 0.37),
    "gemini-2.5-flash": (0.28, 2.33),
    "gemini-2.5-pro": (1.16, 9.30),
    "gemini-3.5-flash": (1.53, 9.21),
}

DURATION_PATTERN = re.compile(r"^(?P<amount>[1-9][0-9]*)(?P<unit>[smhd])$")


class ReportError(RuntimeError):
    """A concise error that is safe to show without credential contents."""


@dataclass(frozen=True)
class Window:
    start: datetime
    end: datetime
    bucket: timedelta
    timezone: Any

    def __post_init__(self) -> None:
        if self.start.tzinfo is None or self.end.tzinfo is None:
            raise ValueError("Window timestamps must be timezone-aware.")
        if self.end <= self.start:
            raise ValueError("Window end must be after start.")
        if self.bucket.total_seconds() < SOURCE_ALIGNMENT_SECONDS:
            raise ValueError("Bucket interval must be at least 1 minute.")
        if self.bucket.total_seconds() % SOURCE_ALIGNMENT_SECONDS:
            raise ValueError("Bucket interval must be a whole number of minutes.")


@dataclass
class TokenCounts:
    fresh_input: int = 0
    cached_input: int = 0
    output: int = 0

    @property
    def total(self) -> int:
        return self.fresh_input + self.cached_input + self.output

    def add(self, other: "TokenCounts") -> None:
        self.fresh_input += other.fresh_input
        self.cached_input += other.cached_input
        self.output += other.output


@dataclass(frozen=True)
class Rate:
    input_per_million: float
    output_per_million: float
    source: str


@dataclass
class PriceBook:
    rates: dict[str, Rate]
    catalog_status: str


@dataclass(frozen=True)
class PricedCounts:
    estimated_eur: Optional[float]
    price_note: str


def parse_duration(value: str) -> timedelta:
    match = DURATION_PATTERN.fullmatch(value.strip().lower())
    if not match:
        raise argparse.ArgumentTypeError(
            f"invalid duration {value!r}; use an integer followed by s, m, h, or d"
        )
    amount = int(match.group("amount"))
    unit = match.group("unit")
    seconds = amount * {"s": 1, "m": 60, "h": 3_600, "d": 86_400}[unit]
    return timedelta(seconds=seconds)


def local_timezone() -> Any:
    return datetime.now().astimezone().tzinfo or timezone.utc


def parse_timezone(value: Optional[str]) -> Any:
    if not value or value.lower() == "local":
        return local_timezone()
    if value.upper() == "UTC":
        return timezone.utc
    try:
        return ZoneInfo(value)
    except ZoneInfoNotFoundError as error:
        raise ReportError(f"Unknown timezone: {value}") from error


def parse_timestamp(value: str, report_timezone: Any) -> datetime:
    cleaned = value.strip()
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", cleaned):
            parsed_date = date.fromisoformat(cleaned)
            return datetime.combine(parsed_date, datetime_time.min, tzinfo=report_timezone)
        normalized = cleaned[:-1] + "+00:00" if cleaned.endswith("Z") else cleaned
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ReportError(
            f"Invalid timestamp {value!r}; use YYYY-MM-DD or RFC 3339/ISO 8601."
        ) from error
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=report_timezone)
    return parsed


def resolve_named_window(
    *,
    start_value: Optional[str],
    end_value: Optional[str],
    last_value: Optional[timedelta],
    bucket: timedelta,
    report_timezone: Any,
    default_duration: timedelta,
    option_prefix: str,
) -> Window:
    explicit = start_value is not None or end_value is not None
    option = f"--{option_prefix}-" if option_prefix else "--"
    if explicit:
        if start_value is None or end_value is None:
            raise ReportError(
                f"{option}start and {option}end must be supplied together."
            )
        if last_value is not None:
            raise ReportError(
                f"Use either {option}last or {option}start/{option}end, not both."
            )
        start = parse_timestamp(start_value, report_timezone)
        end = parse_timestamp(end_value, report_timezone)
    else:
        duration = last_value or default_duration
        # Monitoring samples at one-minute granularity. End at the current
        # minute boundary so relative windows have stable, honest bucket edges.
        end = datetime.now(report_timezone).replace(second=0, microsecond=0)
        start = end - duration

    try:
        return Window(start=start, end=end, bucket=bucket, timezone=report_timezone)
    except ValueError as error:
        raise ReportError(str(error)) from error


def resolve_windows(args: argparse.Namespace) -> tuple[Window, Window, Window]:
    """Resolve independent chart/summary windows plus their one-fetch union."""
    report_timezone = parse_timezone(args.timezone)
    chart = resolve_named_window(
        start_value=args.chart_start,
        end_value=args.chart_end,
        last_value=args.chart_last,
        bucket=args.chart_interval,
        report_timezone=report_timezone,
        default_duration=timedelta(hours=8),
        option_prefix="chart",
    )
    summary = resolve_named_window(
        start_value=args.summary_start,
        end_value=args.summary_end,
        last_value=args.summary_last,
        bucket=timedelta(days=1),
        report_timezone=report_timezone,
        default_duration=timedelta(days=30),
        option_prefix="summary",
    )
    query = Window(
        start=min(chart.start, summary.start),
        end=max(chart.end, summary.end),
        bucket=timedelta(minutes=1),
        timezone=report_timezone,
    )
    return chart, summary, query


def rfc3339(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def login_command() -> str:
    """The exact command that re-authorises *this* report's credentials.

    Each account is a separate `CLOUDSDK_CONFIG` directory, so a bare
    `gcloud auth login` signs the wrong one in when several are configured.
    The home directory is abbreviated because this string is shown on screen.
    """
    config = os.environ.get("CLOUDSDK_CONFIG")
    if not config:
        return "gcloud auth login"
    home = os.path.expanduser("~")
    if config == home or config.startswith(home + os.sep):
        config = "~" + config[len(home):]
    return f"CLOUDSDK_CONFIG={config} gcloud auth login"


def auth_failure_reason(error: Exception) -> str:
    """Names the failure without echoing gcloud's output.

    An organisation that enforces periodic reauthentication produces a session
    that still lists an account and still fails every token request, which
    reads as a broken app rather than an expired sign-in unless it is said.
    """
    stderr = getattr(error, "stderr", "") or ""
    if "eauthentication" in stderr:
        return "gcloud requires reauthentication for this account."
    return "Existing gcloud authentication was unavailable."


def access_token() -> str:
    try:
        process = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except FileNotFoundError as error:
        raise ReportError("gcloud was not found.") from error
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ReportError(
            f"{auth_failure_reason(error)} Run: {login_command()}"
        ) from error
    token = process.stdout.strip()
    if not token:
        raise ReportError("gcloud returned no access token.")
    return token


def read_json_url(
    url: str,
    token: str,
    timeout: int = 90,
) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            body = error.read().decode("utf-8", "replace")
            payload = json.loads(body)
            detail = payload.get("error", {}).get("message", "")
        except Exception:
            detail = ""
        safe_detail = re.sub(r"\s+", " ", str(detail))[:400]
        raise ReportError(
            f"Google API returned HTTP {error.code}"
            + (f": {safe_detail}" if safe_detail else ".")
        ) from error
    except urllib.error.URLError as error:
        raise ReportError(f"Google API connection failed: {error.reason}") from error
    if not isinstance(payload, dict):
        raise ReportError("Google API returned an unexpected response.")
    return payload


def monitoring_series(
    project: str,
    window: Window,
    token: str,
) -> list[dict[str, Any]]:
    # Use one-minute source buckets, then aggregate locally. This keeps user
    # bucket boundaries anchored to the exact requested start timestamp instead
    # of inheriting a provider-selected chart alignment.
    group_by = [
        "metric.label.type",
        "metric.label.explicit_caching",
        "resource.label.model_user_id",
    ]
    parameters: list[tuple[str, str]] = [
        ("filter", f'metric.type = "{METRIC}"'),
        ("interval.startTime", rfc3339(window.start)),
        ("interval.endTime", rfc3339(window.end)),
        ("aggregation.alignmentPeriod", f"{SOURCE_ALIGNMENT_SECONDS}s"),
        ("aggregation.perSeriesAligner", "ALIGN_SUM"),
        ("aggregation.crossSeriesReducer", "REDUCE_SUM"),
        ("view", "FULL"),
        ("pageSize", "100000"),
    ]
    parameters.extend(("aggregation.groupByFields", field) for field in group_by)

    base_url = MONITORING_API.format(project=urllib.parse.quote(project, safe=""))
    series: list[dict[str, Any]] = []
    page_token = ""
    while True:
        query = parameters.copy()
        if page_token:
            query.append(("pageToken", page_token))
        payload = read_json_url(
            f"{base_url}?{urllib.parse.urlencode(query)}",
            token,
        )
        page_series = payload.get("timeSeries", [])
        if not isinstance(page_series, list):
            raise ReportError("Monitoring returned malformed time-series data.")
        series.extend(item for item in page_series if isinstance(item, dict))
        page_token = str(payload.get("nextPageToken") or "")
        if not page_token:
            break
    return series


def bucket_count(window: Window) -> int:
    return math.ceil((window.end - window.start) / window.bucket)


def bucket_index(point_end: datetime, window: Window) -> Optional[int]:
    # Monitoring DELTA points describe (start, end]. Subtract one microsecond so
    # a point ending exactly on a bucket boundary belongs to the prior bucket.
    instant = point_end.astimezone(window.start.tzinfo) - timedelta(microseconds=1)
    if instant < window.start or instant >= window.end:
        return None
    return int((instant - window.start) // window.bucket)


def bucket_bounds(index: int, window: Window) -> tuple[datetime, datetime]:
    start = window.start + index * window.bucket
    return start, min(start + window.bucket, window.end)


def point_integer(point: dict[str, Any]) -> int:
    value = point.get("value") or {}
    if "int64Value" in value:
        return int(value["int64Value"])
    if "doubleValue" in value:
        return int(round(float(value["doubleValue"])))
    return 0


def aggregate_series(
    series: Iterable[dict[str, Any]],
    window: Window,
) -> tuple[dict[tuple[int, str], TokenCounts], set[str], bool]:
    buckets: dict[tuple[int, str], TokenCounts] = defaultdict(TokenCounts)
    ignored_types: set[str] = set()
    saw_input = False
    saw_explicit_cache_label = False

    for time_series in series:
        metric_labels = (time_series.get("metric") or {}).get("labels") or {}
        resource_labels = (time_series.get("resource") or {}).get("labels") or {}
        token_type = str(metric_labels.get("type") or "").lower()
        caching = str(metric_labels.get("explicit_caching") or "").lower()
        model = str(resource_labels.get("model_user_id") or "unknown-model")
        if token_type not in {"input", "output"}:
            ignored_types.add(token_type or "(missing)")
            continue
        for point in time_series.get("points") or []:
            try:
                point_end = parse_timestamp(
                    str((point.get("interval") or {})["endTime"]),
                    timezone.utc,
                )
            except (KeyError, ReportError):
                continue
            index = bucket_index(point_end, window)
            if index is None:
                continue
            if token_type == "input":
                saw_input = True
                if "explicit_caching" in metric_labels:
                    saw_explicit_cache_label = True
            value = point_integer(point)
            counts = buckets[(index, model)]
            if token_type == "output":
                counts.output += value
            elif caching in {"cached", "true", "yes", "explicit"}:
                counts.cached_input += value
            else:
                counts.fresh_input += value
    return dict(buckets), ignored_types, saw_input and saw_explicit_cache_label


def money_value(value: dict[str, Any]) -> float:
    return float(value.get("units", "0") or 0) + float(value.get("nanos", 0) or 0) / 1e9


def current_pricing_expression(sku: dict[str, Any]) -> Optional[dict[str, Any]]:
    pricing = sku.get("pricingInfo") or []
    if not isinstance(pricing, list) or not pricing:
        return None
    latest = max(
        (entry for entry in pricing if isinstance(entry, dict)),
        key=lambda entry: str(entry.get("effectiveTime") or ""),
        default=None,
    )
    expression = (latest or {}).get("pricingExpression")
    return expression if isinstance(expression, dict) else None


def per_million_price(sku: dict[str, Any]) -> Optional[float]:
    expression = current_pricing_expression(sku)
    if not expression:
        return None
    tiers = expression.get("tieredRates") or []
    if not tiers:
        return None
    # Vertex token SKUs currently have a single zero-start tier. Refuse to
    # pretend a multi-tier formula is a single exact rate.
    zero_tiers = [
        tier
        for tier in tiers
        if isinstance(tier, dict)
        and float(tier.get("startUsageAmount", 0) or 0) == 0
    ]
    if len(tiers) != 1 or len(zero_tiers) != 1:
        return None
    unit_price = money_value(zero_tiers[0].get("unitPrice") or {})
    conversion = float(expression.get("baseUnitConversionFactor", 1) or 1)
    if conversion <= 0:
        return None
    return unit_price / conversion * 1_000_000


def cache_payload(price_book: PriceBook) -> dict[str, Any]:
    return {
        "created_at": int(time.time()),
        "currency": "EUR",
        "rates": {
            model: [
                rate.input_per_million,
                rate.output_per_million,
                rate.source,
            ]
            for model, rate in price_book.rates.items()
        },
        "catalog_status": price_book.catalog_status,
    }


def load_price_cache(path: Path, ttl_seconds: int) -> Optional[PriceBook]:
    try:
        if time.time() - path.stat().st_mtime > ttl_seconds:
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("currency") != "EUR":
            return None
        rates = {
            model: Rate(float(values[0]), float(values[1]), str(values[2]))
            for model, values in (payload.get("rates") or {}).items()
        }
        if not rates:
            return None
        return PriceBook(
            rates=rates,
            catalog_status=f"cached live Catalog prices ({path})",
        )
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return None


def save_price_cache(path: Path, price_book: PriceBook) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(
            json.dumps(cache_payload(price_book), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        temporary.replace(path)
    except OSError:
        # A cache failure should not invalidate an otherwise valid report.
        pass


def live_catalog_price_book(token: str) -> PriceBook:
    wanted: dict[str, tuple[str, str]] = {}
    for model, (input_sku, output_sku) in SKU_MAP.items():
        wanted[input_sku] = (model, "input")
        wanted[output_sku] = (model, "output")

    found: dict[str, dict[str, float]] = defaultdict(dict)
    page_token = ""
    pages = 0
    while True:
        pages += 1
        if pages > 25:
            raise ReportError("Billing Catalog pagination exceeded the safety limit.")
        parameters = {"pageSize": "5000", "currencyCode": "EUR"}
        if page_token:
            parameters["pageToken"] = page_token
        payload = read_json_url(
            CATALOG_API.format(service=VERTEX_SERVICE_ID)
            + "?"
            + urllib.parse.urlencode(parameters),
            token,
        )
        for sku in payload.get("skus") or []:
            if not isinstance(sku, dict):
                continue
            match = wanted.get(str(sku.get("description") or ""))
            if not match:
                continue
            price = per_million_price(sku)
            if price is not None:
                model, direction = match
                found[model][direction] = price
        page_token = str(payload.get("nextPageToken") or "")
        if not page_token:
            break

    rates: dict[str, Rate] = {}
    missing: list[str] = []
    for model in SKU_MAP:
        values = found.get(model) or {}
        if "input" in values and "output" in values:
            rates[model] = Rate(
                input_per_million=values["input"],
                output_per_million=values["output"],
                source="live Catalog",
            )
        else:
            missing.append(model)
    status = "live Cloud Billing Catalog"
    if missing:
        status += "; missing mapped SKUs: " + ", ".join(missing)
    return PriceBook(rates=rates, catalog_status=status)


def price_book(
    token: str,
    cache_path: Path,
    cache_ttl: int,
) -> PriceBook:
    cached = load_price_cache(cache_path, cache_ttl)
    if cached:
        return cached
    try:
        book = live_catalog_price_book(token)
    except ReportError as error:
        return PriceBook(
            rates={
                model: Rate(input_rate, output_rate, "embedded fallback")
                for model, (input_rate, output_rate) in EMBEDDED_FALLBACK_EUR.items()
            },
            catalog_status=f"live Catalog unavailable ({error}); embedded fallback prices",
        )

    for model, (input_rate, output_rate) in EMBEDDED_FALLBACK_EUR.items():
        if model not in book.rates:
            book.rates[model] = Rate(
                input_per_million=input_rate,
                output_per_million=output_rate,
                source="embedded fallback",
            )
    save_price_cache(cache_path, book)
    return book


def matching_rate(model: str, book: PriceBook) -> Optional[tuple[str, Rate]]:
    matches = [
        prefix
        for prefix in book.rates
        if model == prefix or model.startswith(prefix + "-")
    ]
    if not matches:
        return None
    prefix = max(matches, key=len)
    return prefix, book.rates[prefix]


def price_counts(
    model: str,
    counts: TokenCounts,
    book: PriceBook,
    unknown_fallback_model: Optional[str],
) -> PricedCounts:
    matched = matching_rate(model, book)
    if matched:
        prefix, rate = matched
        note = rate.source if model == prefix else f"{rate.source}; prefix {prefix}"
    else:
        if not unknown_fallback_model:
            return PricedCounts(None, "UNPRICED unknown model")
        fallback = matching_rate(unknown_fallback_model, book)
        if not fallback:
            return PricedCounts(None, "UNPRICED fallback model has no rate")
        prefix, rate = fallback
        note = f"UNKNOWN-MODEL FALLBACK priced as {prefix} ({rate.source})"

    estimated = (
        counts.fresh_input * rate.input_per_million
        + counts.cached_input * rate.input_per_million * CACHED_INPUT_FACTOR
        + counts.output * rate.output_per_million
    ) / 1_000_000
    return PricedCounts(estimated, note)


def all_models(
    buckets: dict[tuple[int, str], TokenCounts],
) -> list[str]:
    return sorted({model for _, model in buckets})


def combined_counts(
    buckets: dict[tuple[int, str], TokenCounts],
    index: int,
    models: Iterable[str],
) -> TokenCounts:
    combined = TokenCounts()
    for model in models:
        combined.add(buckets.get((index, model), TokenCounts()))
    return combined


def combined_price(
    buckets: dict[tuple[int, str], TokenCounts],
    index: int,
    models: Iterable[str],
    book: PriceBook,
    unknown_fallback_model: Optional[str],
) -> tuple[Optional[float], set[str]]:
    total = 0.0
    notes: set[str] = set()
    complete = True
    for model in models:
        priced = price_counts(
            model,
            buckets.get((index, model), TokenCounts()),
            book,
            unknown_fallback_model,
        )
        notes.add(f"{model}: {priced.price_note}")
        if priced.estimated_eur is None:
            complete = False
        else:
            total += priced.estimated_eur
    return (total if complete else None), notes


def format_time(value: datetime, report_timezone: Any) -> str:
    return value.astimezone(report_timezone).isoformat(timespec="minutes")


def table_rows(
    buckets: dict[tuple[int, str], TokenCounts],
    window: Window,
    by_model: bool,
    book: PriceBook,
    unknown_fallback_model: Optional[str],
) -> tuple[list[tuple[Any, ...]], set[str]]:
    models = all_models(buckets)
    rows: list[tuple[Any, ...]] = []
    notes: set[str] = set()
    for index in range(bucket_count(window)):
        start, end = bucket_bounds(index, window)
        if by_model:
            row_models = models or ["all-models"]
            for model in row_models:
                counts = buckets.get((index, model), TokenCounts())
                priced = price_counts(model, counts, book, unknown_fallback_model)
                notes.add(f"{model}: {priced.price_note}")
                rows.append(
                    (
                        format_time(start, window.timezone),
                        format_time(end, window.timezone),
                        model,
                        counts.fresh_input,
                        counts.cached_input,
                        counts.output,
                        counts.total,
                        priced.estimated_eur,
                    )
                )
        else:
            counts = combined_counts(buckets, index, models)
            estimated, row_notes = combined_price(
                buckets,
                index,
                models,
                book,
                unknown_fallback_model,
            )
            notes.update(row_notes)
            rows.append(
                (
                    format_time(start, window.timezone),
                    format_time(end, window.timezone),
                    counts.fresh_input,
                    counts.cached_input,
                    counts.output,
                    counts.total,
                    estimated,
                )
            )
    return rows, notes


def print_csv(rows: Sequence[tuple[Any, ...]], by_model: bool) -> None:
    writer = csv.writer(sys.stdout)
    header = ["bucket_start", "bucket_end"]
    if by_model:
        header.append("model")
    header.extend(
        [
            "input_not_marked_explicit_cache_tokens",
            "explicit_cache_served_input_tokens",
            "output_tokens",
            "total_tokens",
            "estimated_eur",
        ]
    )
    writer.writerow(header)
    for row in rows:
        rendered = list(row)
        rendered[-1] = "" if row[-1] is None else f"{row[-1]:.6f}"
        writer.writerow(rendered)


def print_table(rows: Sequence[tuple[Any, ...]], by_model: bool) -> None:
    if by_model:
        heading = (
            f"{'bucket start':<23} {'bucket end':<23} {'model':<27} "
            f"{'non-exp in':>12} {'explicit in':>12} {'output':>12} "
            f"{'total':>12} {'est EUR':>10}"
        )
    else:
        heading = (
            f"{'bucket start':<23} {'bucket end':<23} "
            f"{'non-exp in':>12} {'explicit in':>12} {'output':>12} "
            f"{'total':>12} {'est EUR':>10}"
        )
    print(heading)
    print("-" * len(heading))
    for row in rows:
        estimated = "UNPRICED" if row[-1] is None else f"{row[-1]:.4f}"
        if by_model:
            start, end, model, fresh, cached, output, total, _ = row
            print(
                f"{start:<23} {end:<23} {model:<27} "
                f"{fresh:>12,} {cached:>12,} {output:>12,} "
                f"{total:>12,} {estimated:>10}"
            )
        else:
            start, end, fresh, cached, output, total, _ = row
            print(
                f"{start:<23} {end:<23} "
                f"{fresh:>12,} {cached:>12,} {output:>12,} "
                f"{total:>12,} {estimated:>10}"
            )


def report_summary(
    buckets: dict[tuple[int, str], TokenCounts],
    book: PriceBook,
    unknown_fallback_model: Optional[str],
    output: Any,
) -> None:
    models = all_models(buckets)
    total_counts = TokenCounts()
    estimated_eur = 0.0
    complete = True
    notes: set[str] = set()
    for model in models:
        model_counts = TokenCounts()
        for (index, bucket_model), counts in buckets.items():
            del index
            if bucket_model == model:
                model_counts.add(counts)
        total_counts.add(model_counts)
        priced = price_counts(model, model_counts, book, unknown_fallback_model)
        notes.add(f"{model}: {priced.price_note}")
        if priced.estimated_eur is None:
            complete = False
        else:
            estimated_eur += priced.estimated_eur

    print("", file=output)
    print("Window summary (bucket values above are SUM totals, never averages):", file=output)
    print(
        "  Input tokens not marked explicit-cache: "
        f"{total_counts.fresh_input:,}",
        file=output,
    )
    print(
        f"  Explicit-cache-served input tokens: {total_counts.cached_input:,}",
        file=output,
    )
    print(f"  Output tokens: {total_counts.output:,}", file=output)
    print(f"  Total tokens: {total_counts.total:,}", file=output)
    if complete:
        print(f"  ESTIMATED EUR list-price spend: ~EUR {estimated_eur:,.2f}", file=output)
    else:
        print("  ESTIMATED EUR list-price spend: incomplete (unpriced model tokens)", file=output)
    print(f"  Pricing source: {book.catalog_status}", file=output)
    for note in sorted(notes):
        if "fallback" in note.lower() or "unpriced" in note.lower():
            print(f"  PRICE WARNING: {note}", file=output)
    print(
        "  Implicit cache hits/rate: unavailable historically; they require "
        "request-level UsageMetadata.cachedContentTokenCount capture.",
        file=output,
    )
    print(
        "  ESTIMATE ONLY: token_count x public list price. This is not an invoice "
        "or exact billed charge and excludes credits, tier/context/modality and "
        "regional differences, cache storage, non-token SKUs, taxes, and late corrections.",
        file=output,
    )
    print(
        "  Exact spend requires Cloud Billing BigQuery export; use "
        "scripts/vertex_ai_spend.py for that separate read-only check.",
        file=output,
    )


def json_payload(
    project: str,
    chart_window: Window,
    chart_buckets: dict[tuple[int, str], TokenCounts],
    summary_window: Window,
    summary_buckets: dict[tuple[int, str], TokenCounts],
    book: PriceBook,
    unknown_fallback_model: Optional[str],
    explicit_cache_metric_reported: bool,
) -> dict[str, Any]:
    models = all_models(summary_buckets)
    total_counts = TokenCounts()
    estimated_eur = 0.0
    estimate_complete = True
    price_warnings: set[str] = set()

    for model in models:
        model_counts = TokenCounts()
        for (_, bucket_model), counts in summary_buckets.items():
            if bucket_model == model:
                model_counts.add(counts)
        total_counts.add(model_counts)
        priced = price_counts(
            model,
            model_counts,
            book,
            unknown_fallback_model,
        )
        if priced.estimated_eur is None:
            estimate_complete = False
        else:
            estimated_eur += priced.estimated_eur
        if "fallback" in priced.price_note.lower() or "unpriced" in priced.price_note.lower():
            price_warnings.add(f"{model}: {priced.price_note}")

    points: list[dict[str, Any]] = []
    chart_models = all_models(chart_buckets)
    for index in range(bucket_count(chart_window)):
        bucket_start, _ = bucket_bounds(index, chart_window)
        counts = combined_counts(chart_buckets, index, chart_models)
        points.append(
            {
                "timestamp": bucket_start.isoformat(timespec="seconds"),
                "value": counts.total,
            }
        )

    return {
        "schema_version": 2,
        "project": project,
        "chart_window": {
            "start": chart_window.start.isoformat(timespec="seconds"),
            "end": chart_window.end.isoformat(timespec="seconds"),
            "bucket_seconds": int(chart_window.bucket.total_seconds()),
        },
        "summary_window": {
            "start": summary_window.start.isoformat(timespec="seconds"),
            "end": summary_window.end.isoformat(timespec="seconds"),
        },
        "series": {
            "id": "vertex-ai-token-usage",
            "label": "Vertex AI token totals",
            "unit": "tokens",
            "points": points,
        },
        "token_totals": {
            "input_not_marked_explicit_cache": total_counts.fresh_input,
            "explicit_cache_served_input": total_counts.cached_input,
            "output": total_counts.output,
            "total": total_counts.total,
            "explicit_cache_metric_reported": explicit_cache_metric_reported,
            "implicit_cache_hit_tokens": None,
            "implicit_cache_hit_rate": None,
            "implicit_cache_status": (
                "unavailable_historically_without_request_usage_metadata_"
                "cachedContentTokenCount"
            ),
        },
        "estimated_eur": estimated_eur if estimate_complete else None,
        "estimate_kind": "public_list_price_estimate_not_invoice",
        "pricing_source": book.catalog_status,
        "pricing_warnings": sorted(price_warnings),
    }


def active_project(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    try:
        process = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ReportError("No active gcloud project is available; pass --project.") from error
    project = process.stdout.strip()
    if not project or project == "(unset)":
        raise ReportError("No active gcloud project is available; pass --project.")
    return project


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Report bucketed Vertex AI token totals and estimated EUR list-price "
            "spend using existing gcloud authentication."
        )
    )
    parser.add_argument("--project", help="GCP project; defaults to active gcloud project.")
    parser.add_argument(
        "--chart-start",
        "--start",
        dest="chart_start",
        help="Chart inclusive date/timestamp (YYYY-MM-DD or RFC 3339).",
    )
    parser.add_argument(
        "--chart-end",
        "--end",
        dest="chart_end",
        help="Chart exclusive date/timestamp (YYYY-MM-DD or RFC 3339).",
    )
    parser.add_argument(
        "--chart-last",
        "--last",
        dest="chart_last",
        type=parse_duration,
        help="Relative chart window (default: 8h); cannot be combined with chart start/end.",
    )
    parser.add_argument(
        "--chart-interval",
        "--interval",
        dest="chart_interval",
        type=parse_duration,
        default=timedelta(minutes=20),
        help="Chart SUM bucket size (default: 20m; whole minutes only).",
    )
    parser.add_argument(
        "--summary-start",
        help="Summary inclusive date/timestamp (YYYY-MM-DD or RFC 3339).",
    )
    parser.add_argument(
        "--summary-end",
        help="Summary exclusive date/timestamp (YYYY-MM-DD or RFC 3339).",
    )
    parser.add_argument(
        "--summary-last",
        type=parse_duration,
        help="Relative summary window (default: 30d); cannot be combined with summary start/end.",
    )
    parser.add_argument(
        "--timezone",
        default="local",
        help="Timezone for date-only inputs and labels: local, UTC, or IANA name.",
    )
    parser.add_argument("--by-model", action="store_true", help="Print one row per model per bucket.")
    parser.add_argument("--csv", action="store_true", help="Emit bucket rows as CSV.")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit one JSON object containing chart series and window estimate.",
    )
    parser.add_argument(
        "--price-cache",
        type=Path,
        default=DEFAULT_PRICE_CACHE,
        help=f"Catalog price cache (default: {DEFAULT_PRICE_CACHE}).",
    )
    parser.add_argument(
        "--price-cache-ttl",
        type=int,
        default=DEFAULT_PRICE_CACHE_TTL,
        help="Catalog cache lifetime in seconds (default: 86400).",
    )
    parser.add_argument(
        "--unknown-fallback-model",
        default="gemini-2.5-flash",
        help=(
            "Explicit assumption for unknown model labels (default: gemini-2.5-flash); "
            "every use is flagged."
        ),
    )
    parser.add_argument(
        "--no-unknown-fallback",
        action="store_true",
        help="Leave unknown-model token spend unpriced instead of applying an assumption.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        args = parse_args(argv)
        if args.csv and args.json:
            raise ReportError("--csv and --json cannot be combined.")
        chart_window, summary_window, query_window = resolve_windows(args)
        project = active_project(args.project)
        token = access_token()
        # The Monitoring API is queried once for the union. Both requested
        # windows are then filtered and aggregated locally.
        series = monitoring_series(project, query_window, token)
        chart_buckets, chart_ignored_types, _ = aggregate_series(
            series,
            chart_window,
        )
        summary_buckets, summary_ignored_types, explicit_cache_metric_reported = (
            aggregate_series(
                series,
                summary_window,
            )
        )
        ignored_types = chart_ignored_types | summary_ignored_types
        book = price_book(token, args.price_cache, args.price_cache_ttl)
    except (ReportError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    unknown_fallback = (
        None if args.no_unknown_fallback else args.unknown_fallback_model
    )
    if args.json:
        print(
            json.dumps(
                json_payload(
                    project,
                    chart_window,
                    chart_buckets,
                    summary_window,
                    summary_buckets,
                    book,
                    unknown_fallback,
                    explicit_cache_metric_reported,
                ),
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 0

    rows, _ = table_rows(
        chart_buckets,
        chart_window,
        args.by_model,
        book,
        unknown_fallback,
    )

    if not args.csv:
        print(f"Project: {project}")
        print(
            f"Chart window: {format_time(chart_window.start, chart_window.timezone)} "
            f"inclusive to {format_time(chart_window.end, chart_window.timezone)} exclusive"
        )
        print(
            f"Chart bucket interval: {int(chart_window.bucket.total_seconds())} seconds; "
            "each value is the SUM within that bucket (not an average)."
        )
        print(
            f"Summary window: {format_time(summary_window.start, summary_window.timezone)} "
            f"inclusive to {format_time(summary_window.end, summary_window.timezone)} exclusive"
        )
        print()
        print_table(rows, args.by_model)
        summary_output = sys.stdout
    else:
        print_csv(rows, args.by_model)
        summary_output = sys.stderr

    if ignored_types:
        print(
            "WARNING: ignored unexpected token type label(s): "
            + ", ".join(sorted(ignored_types)),
            file=summary_output,
        )
    report_summary(summary_buckets, book, unknown_fallback, summary_output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
