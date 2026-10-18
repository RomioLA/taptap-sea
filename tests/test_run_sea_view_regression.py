import importlib.util
from pathlib import Path
import sys
import unittest


SOURCE = Path(__file__).with_name("run_sea_view_regression.py")
SPEC = importlib.util.spec_from_file_location("sea_view_regression_under_test", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SummarizeReportTests(unittest.TestCase):
    def test_boolean_pass_is_not_compared_to_numeric_total(self):
        self.assertTrue(MODULE.summarize_report({"passed": True, "total": 86})["passed"])

    def test_boolean_failure_remains_a_failure(self):
        self.assertFalse(MODULE.summarize_report({"passed": False, "total": 86})["passed"])

    def test_matching_numeric_counts_pass(self):
        self.assertTrue(MODULE.summarize_report({"passed": 86, "total": 86})["passed"])

    def test_mismatched_numeric_counts_fail(self):
        self.assertFalse(MODULE.summarize_report({"passed": 85, "total": 86})["passed"])

    def test_mismatched_counts_fail_when_total_is_zero(self):
        self.assertFalse(MODULE.summarize_report({"passed": 1, "total": 0})["passed"])

    def test_failed_subitem_overrides_a_true_summary(self):
        report = {
            "passed": True,
            "total": 86,
            "results": [{"name": "explicit_failure", "passed": False}],
        }
        self.assertFalse(MODULE.summarize_report(report)["passed"])


if __name__ == "__main__":
    unittest.main()
