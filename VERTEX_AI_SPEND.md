# Vertex AI token and spend reports

Two independent, read-only reports are included:

1. `scripts/vertex_ai_report.py`: Cloud Monitoring chart buckets plus an
   independently ranged **estimated** EUR/token summary.
2. `scripts/vertex_ai_spend.py`: **exact exported** Cloud Billing cost when a
   billing-export table exists.

They use existing `gcloud` authentication, have no third-party Python
dependencies, keep access tokens in memory only, and never print or cache token
contents.

## Bucketed tokens and estimated EUR

`vertex_ai_report.py` has two independent windows:

- **Chart:** defaults to the last 8 hours in 20-minute buckets.
- **Summary:** defaults to the last 30 days and supplies aggregate token totals
  and estimated EUR spend.

Each accepts either a relative duration or explicit date/RFC 3339 start and end
timestamps. Start is inclusive and end is exclusive. Date-only values mean
midnight in `--timezone` (local by default). Every chart bucket is a **sum
total**, not an average.

The script asks Monitoring once for the union of the two windows, then performs
both filters/aggregations locally. A long summary range therefore does not
force the chart to use long buckets, and a short chart does not truncate the
summary.

Last 30 days, one-day chart buckets, grouped by model, with the matching
30-day summary:

```sh
python3 scripts/vertex_ai_report.py \
  --project personal-project \
  --chart-last 30d \
  --chart-interval 1d \
  --summary-last 30d \
  --by-model
```

Last 8 hours in 20-minute chart buckets plus the default 30-day summary:

```sh
python3 scripts/vertex_ai_report.py \
  --project personal-project \
  --chart-last 8h \
  --chart-interval 20m \
  --summary-last 30d
```

Arbitrary, different explicit chart and summary date windows:

```sh
python3 scripts/vertex_ai_report.py \
  --project personal-project \
  --chart-start 2026-07-27 \
  --chart-end 2026-07-29 \
  --chart-interval 1h \
  --summary-start 2026-06-01 \
  --summary-end 2026-07-01 \
  --timezone Europe/Amsterdam \
  --by-model
```

Explicit chart timestamps with a relative summary:

```sh
python3 scripts/vertex_ai_report.py \
  --project personal-project \
  --chart-start 2026-07-27T09:10:00+02:00 \
  --chart-end 2026-07-27T17:10:00+02:00 \
  --chart-interval 20m \
  --summary-last 14d \
  --by-model
```

The shorter aliases `--start`, `--end`, `--last`, and `--interval` remain
available for the chart options. Add `--csv` for machine-readable chart rows or
`--json` for the dashboard-ready chart series plus summary object. Chart
intervals must be whole minutes. The script retrieves one-minute `ALIGN_SUM`
source points and aggregates them locally, anchoring buckets to the requested
chart start timestamp. This avoids mistaking a rate/average for a token total
and gives deterministic partial final buckets.

Pricing uses live EUR SKU data from the Cloud Billing Catalog, cached for 24
hours in the operating-system temporary directory. If a mapped SKU is absent
or the Catalog call fails, the report uses an embedded fallback and labels it
`PRICE WARNING`. Unknown model labels use the
`--unknown-fallback-model` assumption (default `gemini-2.5-flash`) and are also
flagged. Use `--no-unknown-fallback` to leave those tokens visibly unpriced.

The estimate applies public list price to Monitoring tokens, with input marked
as explicit-cache-served priced at the script's visible 25% assumption. It is
not a charge or invoice: it can differ because of credits, free/tiered pricing,
prompt-length, modality, region/priority/batch distinctions, caching storage,
non-token SKUs, tax, and late corrections.

### Validated 30-day result

For the explicit local-calendar window from 2026-06-29 through 2026-07-29
(end exclusive), the live read-only report returned:

- Input not marked explicit-cache: **132,247,169 tokens**
- Explicit-cache-served input: **not reported by the returned metric labels**
- Output: **28,859,150 tokens**
- Total: **161,106,319 tokens**
- Estimated list-price spend: **~EUR 97.30**

The Monitoring label is only about explicit caching. It is not a cache-hit
rate, and input not marked explicit-cache can include implicit caching.
Historical implicit cache-hit tokens/rate are unavailable unless
request-level `UsageMetadata.cachedContentTokenCount` was captured. The report
therefore never turns the absent label into a real `0%` cache-hit result.

The estimate warned that `gemini-2.5-flash` used its embedded rate because the
configured live SKU description was not returned. It also visibly priced
`gemini-3.1-flash-lite` and `gemini-embedding-001` using the configured
unknown-model fallback. Therefore EUR 97.30 must not be presented as exact.

The live independent-window request also succeeded: it returned 24
20-minute chart buckets for 8 hours while preserving the full 30-day summary
above. Unit tests cover start-anchored bucket boundaries, exclusive end
handling, independent ranges, union-query selection, token/model aggregation,
cache-label semantics, and fallback labeling:

```sh
python3 -m unittest discover -s Tests -p 'test_vertex_ai_report.py' -v
```

Official references:

- Cloud Monitoring lists `publisher/online_serving/token_count` as a DELTA,
  INT64 Vertex token-count metric:
  <https://docs.cloud.google.com/monitoring/api/metrics_gcp_a_b>
- Cloud Monitoring aggregation semantics:
  <https://docs.cloud.google.com/monitoring/api/v3/aggregation>
- Cloud Billing Catalog SKU listing and pricing-expression fields:
  <https://docs.cloud.google.com/billing/docs/reference/rest/v1/services.skus/list>
- GenerateContent response usage metadata, including
  `cachedContentTokenCount`:
  <https://cloud.google.com/vertex-ai/generative-ai/docs/reference/rest/v1/GenerateContentResponse>

## Exact exported Cloud Billing spend

`scripts/vertex_ai_spend.py` uses the existing `gcloud`/Application Default
Credentials setup and an existing Cloud Billing BigQuery export. It is
read-only: it does not print credential contents, enable APIs, create datasets,
enable billing export, or change a cloud setting.

### Run

```sh
cd ~/work/limit-dashboard
python3 scripts/vertex_ai_spend.py --diagnose-only
python3 scripts/vertex_ai_spend.py
```

The target defaults to `gcloud config get-value project`; override it with
`--project PROJECT_ID`.

The script:

1. Reads the target project's Cloud Billing link with `gcloud`.
2. Lists accessible BigQuery datasets and looks only for the standard or
   detailed Cloud Billing export table matching that billing account.
3. Uses the latest 30 complete UTC calendar days (today is excluded).
4. Filters the export with query parameters for project, start date, and end
   date, and filters `service.description = 'Vertex AI'`.
5. Dry-runs before execution and refuses to run above 1 GiB by default.
6. Reports gross cost, credits, and net spend separately by billing currency.

To use a different hard cap:

```sh
python3 scripts/vertex_ai_spend.py --maximum-bytes-billed 536870912
```

### Current local result

Verified 2026-07-28:

- Active identity: `account-1@…`
- Active project: `personal-project`
- Billing: enabled
- Accessible billing dataset: `personal-project.billing_export` in `EU`
- Export tables in that dataset: none

The dataset description says it is intended for the standard Cloud Billing
usage-cost export, but no `gcp_billing_export_v1_*` (or detailed
`gcp_billing_export_resource_v1_*`) table exists. Therefore no actual Vertex AI
amount can be calculated yet. The diagnostic did not enable the export, change
Cloud Billing, enable APIs, or submit a billed data query.

Once Google Cloud starts populating a matching export table, rerunning the same
script will discover it automatically. Historical data before export was
enabled may not be backfilled, and late corrections can change recent totals.
