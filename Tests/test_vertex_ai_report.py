import argparse
import importlib.util
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "vertex_ai_report.py"
SPEC = importlib.util.spec_from_file_location("vertex_ai_report", SCRIPT)
assert SPEC and SPEC.loader
REPORT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REPORT
SPEC.loader.exec_module(REPORT)


class VertexAIReportTests(unittest.TestCase):
    def window(self) -> object:
        return REPORT.Window(
            start=datetime(2026, 7, 28, 10, 5, tzinfo=timezone.utc),
            end=datetime(2026, 7, 28, 11, 0, tzinfo=timezone.utc),
            bucket=timedelta(minutes=20),
            timezone=timezone.utc,
        )

    def test_bucket_boundaries_are_start_anchored_and_end_exclusive(self) -> None:
        window = self.window()
        self.assertEqual(
            REPORT.bucket_index(
                datetime(2026, 7, 28, 10, 25, tzinfo=timezone.utc),
                window,
            ),
            0,
        )
        self.assertEqual(
            REPORT.bucket_index(
                datetime(2026, 7, 28, 10, 25, 1, tzinfo=timezone.utc),
                window,
            ),
            1,
        )
        self.assertIsNone(
            REPORT.bucket_index(
                datetime(2026, 7, 28, 11, 0, 1, tzinfo=timezone.utc),
                window,
            )
        )
        self.assertEqual(REPORT.bucket_count(window), 3)
        self.assertEqual(
            REPORT.bucket_bounds(2, window),
            (
                datetime(2026, 7, 28, 10, 45, tzinfo=timezone.utc),
                datetime(2026, 7, 28, 11, 0, tzinfo=timezone.utc),
            ),
        )

    def test_aggregation_separates_fresh_cached_output_and_model(self) -> None:
        window = self.window()

        def series(token_type: str, cache: str, model: str, end: str, value: int):
            return {
                "metric": {
                    "labels": {
                        "type": token_type,
                        "explicit_caching": cache,
                    }
                },
                "resource": {"labels": {"model_user_id": model}},
                "points": [
                    {
                        "interval": {"endTime": end},
                        "value": {"int64Value": str(value)},
                    }
                ],
            }

        raw = [
            series("input", "not_cached", "gemini-a", "2026-07-28T10:10:00Z", 11),
            series("input", "cached", "gemini-a", "2026-07-28T10:20:00Z", 7),
            series("output", "", "gemini-a", "2026-07-28T10:30:00Z", 5),
            series("input", "", "gemini-b", "2026-07-28T10:30:00Z", 13),
        ]
        buckets, ignored, explicit_cache_reported = REPORT.aggregate_series(raw, window)

        self.assertFalse(ignored)
        self.assertTrue(explicit_cache_reported)
        self.assertEqual(buckets[(0, "gemini-a")].fresh_input, 11)
        self.assertEqual(buckets[(0, "gemini-a")].cached_input, 7)
        self.assertEqual(buckets[(0, "gemini-a")].total, 18)
        self.assertEqual(buckets[(1, "gemini-a")].output, 5)
        self.assertEqual(buckets[(1, "gemini-b")].fresh_input, 13)

    def test_unknown_model_fallback_is_explicit(self) -> None:
        book = REPORT.PriceBook(
            rates={
                "gemini-2.5-flash": REPORT.Rate(0.28, 2.33, "live Catalog")
            },
            catalog_status="test",
        )
        priced = REPORT.price_counts(
            "future-model",
            REPORT.TokenCounts(fresh_input=1_000_000, output=1_000_000),
            book,
            "gemini-2.5-flash",
        )
        self.assertAlmostEqual(priced.estimated_eur, 2.61)
        self.assertIn("UNKNOWN-MODEL FALLBACK", priced.price_note)

        unpriced = REPORT.price_counts(
            "future-model",
            REPORT.TokenCounts(fresh_input=1),
            book,
            None,
        )
        self.assertIsNone(unpriced.estimated_eur)
        self.assertIn("UNPRICED", unpriced.price_note)

    def test_date_inputs_are_midnight_and_end_is_exclusive(self) -> None:
        args = argparse.Namespace(
            timezone="UTC",
            chart_interval=timedelta(days=1),
            chart_start="2026-07-01",
            chart_end="2026-07-31",
            chart_last=None,
            summary_start="2026-06-01",
            summary_end="2026-07-01",
            summary_last=None,
        )
        window, summary, query = REPORT.resolve_windows(args)
        self.assertEqual(
            window.start,
            datetime(2026, 7, 1, 0, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(
            window.end,
            datetime(2026, 7, 31, 0, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(REPORT.bucket_count(window), 30)
        self.assertEqual(
            summary.start,
            datetime(2026, 6, 1, 0, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(query.start, summary.start)
        self.assertEqual(query.end, window.end)

    def test_json_payload_separates_chart_points_from_summary_estimate(self) -> None:
        chart_window = self.window()
        chart_buckets = {
            (0, "gemini-2.5-flash"): REPORT.TokenCounts(
                fresh_input=100,
                cached_input=0,
                output=200,
            ),
            (1, "gemini-2.5-flash"): REPORT.TokenCounts(
                fresh_input=300,
                cached_input=0,
                output=400,
            ),
        }
        summary_window = REPORT.Window(
            start=datetime(2026, 6, 28, 11, 0, tzinfo=timezone.utc),
            end=datetime(2026, 7, 28, 11, 0, tzinfo=timezone.utc),
            bucket=timedelta(days=1),
            timezone=timezone.utc,
        )
        summary_buckets = {
            (0, "gemini-2.5-flash"): REPORT.TokenCounts(
                fresh_input=1_000_000,
                cached_input=0,
                output=1_000_000,
            ),
            (1, "gemini-2.5-flash"): REPORT.TokenCounts(
                fresh_input=500_000,
                cached_input=0,
                output=0,
            ),
        }
        book = REPORT.PriceBook(
            rates={
                "gemini-2.5-flash": REPORT.Rate(0.28, 2.33, "live Catalog")
            },
            catalog_status="test catalog",
        )

        payload = REPORT.json_payload(
            "test-project",
            chart_window,
            chart_buckets,
            summary_window,
            summary_buckets,
            book,
            "gemini-2.5-flash",
            True,
        )

        self.assertEqual(payload["schema_version"], 2)
        self.assertEqual(payload["series"]["id"], "vertex-ai-token-usage")
        self.assertEqual(payload["series"]["unit"], "tokens")
        self.assertEqual(
            [point["value"] for point in payload["series"]["points"]],
            [300, 700, 0],
        )
        self.assertAlmostEqual(payload["estimated_eur"], 2.75)
        self.assertEqual(
            payload["estimate_kind"],
            "public_list_price_estimate_not_invoice",
        )
        self.assertEqual(
            payload["token_totals"]["input_not_marked_explicit_cache"],
            1_500_000,
        )
        self.assertEqual(
            payload["token_totals"]["explicit_cache_served_input"],
            0,
        )
        self.assertEqual(payload["token_totals"]["output"], 1_000_000)
        self.assertIsNone(payload["token_totals"]["implicit_cache_hit_rate"])
        self.assertIn(
            "cachedContentTokenCount",
            payload["token_totals"]["implicit_cache_status"],
        )
        self.assertEqual(
            payload["chart_window"]["bucket_seconds"],
            20 * 60,
        )
        self.assertNotEqual(
            payload["chart_window"]["start"],
            payload["summary_window"]["start"],
        )

    def test_relative_defaults_keep_chart_and_summary_independent(self) -> None:
        args = argparse.Namespace(
            timezone="UTC",
            chart_interval=timedelta(minutes=20),
            chart_start=None,
            chart_end=None,
            chart_last=None,
            summary_start=None,
            summary_end=None,
            summary_last=None,
        )
        chart, summary, query = REPORT.resolve_windows(args)

        self.assertEqual(chart.end - chart.start, timedelta(hours=8))
        self.assertEqual(chart.bucket, timedelta(minutes=20))
        self.assertEqual(summary.end - summary.start, timedelta(days=30))
        self.assertEqual(query.start, summary.start)
        self.assertEqual(query.end, chart.end)
        self.assertEqual(REPORT.bucket_count(chart), 24)

    def test_each_window_rejects_mixed_relative_and_explicit_inputs(self) -> None:
        args = argparse.Namespace(
            timezone="UTC",
            chart_interval=timedelta(minutes=20),
            chart_start="2026-07-28T00:00:00Z",
            chart_end="2026-07-28T08:00:00Z",
            chart_last=timedelta(hours=8),
            summary_start=None,
            summary_end=None,
            summary_last=timedelta(days=30),
        )

        with self.assertRaisesRegex(REPORT.ReportError, "--chart-last"):
            REPORT.resolve_windows(args)

    def test_cache_hit_rate_is_unavailable_when_label_is_not_reported(self) -> None:
        window = self.window()
        raw = [
            {
                "metric": {"labels": {"type": "input"}},
                "resource": {"labels": {"model_user_id": "gemini-test"}},
                "points": [
                    {
                        "interval": {"endTime": "2026-07-28T10:10:00Z"},
                        "value": {"int64Value": "100"},
                    }
                ],
            }
        ]

        _, _, explicit_cache_reported = REPORT.aggregate_series(raw, window)
        self.assertFalse(explicit_cache_reported)


if __name__ == "__main__":
    unittest.main()
