#!/usr/bin/env python3
"""Guard: each user-facing fact has exactly one resolver (Zoop 2.0, WP-04).

AGENTS.md: "two readouts of one fact must not be able to disagree", and a guard should assert the
single resolver rather than count call sites. WP-04 moved Stress, Illness and Sleep need into one
resolver each in Packages/StrandAnalytics and took the alternates out of user-facing code. These
checks fail when a removed duplicate comes back or a surface starts resolving the fact itself.

Run with::

    python3 Tools/test_single_resolver.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANALYTICS = ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics"

# Apple app code (Android is out of scope for the fork) and the package sources.
APP_DIRS = ["Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "ZoopWatch", "ZoopWatchComplications"]


def swift_files(*dirs: str | Path) -> list[Path]:
    files: list[Path] = []
    for d in dirs:
        base = d if isinstance(d, Path) else ROOT / d
        if base.exists():
            files.extend(sorted(f for f in base.rglob("*.swift")
                                if f.is_file() and ".build" not in f.parts))
    return files


def app_files() -> list[Path]:
    return swift_files(*APP_DIRS)


def all_apple_files() -> list[Path]:
    return app_files() + swift_files(ROOT / "Packages", ROOT / "StrandTests")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(source: str) -> str:
    """Drop // line comments so a guard matches code, not the prose explaining what was removed."""
    return "\n".join(line.split("//", 1)[0] for line in source.splitlines())


def files_matching(pattern: str, files: list[Path], code_only: bool = True) -> list[str]:
    rx = re.compile(pattern)
    hits = []
    for f in files:
        text = read(f)
        if code_only:
            text = strip_comments(text)
        if rx.search(text):
            hits.append(str(f.relative_to(ROOT)))
    return hits


class StressHasOneResolver(unittest.TestCase):
    def test_stress_math_lives_only_in_daytime_stress(self) -> None:
        defs = files_matching(r"\bfunc\s+(rawScore|squash)\s*\(", all_apple_files())
        self.assertEqual(["Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift"], defs)
        self.assertEqual([], files_matching(r"\bStressMath\b", all_apple_files()))

    def test_removed_stress_duplicates_stay_removed(self) -> None:
        self.assertEqual([], files_matching(r"\bfunc\s+evaluateStress\b", all_apple_files()))
        self.assertEqual([], files_matching(r"\bliveStressLevel\b", all_apple_files()))

    def test_daily_level_comes_from_the_package(self) -> None:
        stress_view = strip_comments(read(ROOT / "Strand/Screens/StressView.swift"))
        self.assertIn("DaytimeStress.daily(days: days, stored: stored)", stress_view)
        today = strip_comments(read(ROOT / "Strand/Features/Today/TodayLoader.swift"))
        self.assertIn("DaytimeStress.daily(", today)

    def test_headline_surfaces_ask_the_one_resolver(self) -> None:
        # The Stress hero and the Home tile/card show "stress now"; both must resolve it through
        # DaytimeStress.headline rather than choosing between hourly and daily themselves.
        for rel in ("Strand/Screens/StressDayHero.swift", "Strand/Features/Today/TodayLoader.swift"):
            self.assertIn("DaytimeStress.headline(", strip_comments(read(ROOT / rel)), rel)
        readouts = strip_comments(read(ROOT / "Strand/Features/Today/TodayReadouts+Body.swift"))
        self.assertIn("_ headline: Assessment<Double, DaytimeStress.HeadlineSource>", readouts)

    def test_alternate_stress_definitions_are_test_centre_only(self) -> None:
        stress_view = strip_comments(read(ROOT / "Strand/Screens/StressView.swift"))
        gate = stress_view.index("guard TestCentre.active(.stress) else")
        self.assertLess(gate, stress_view.index("StressIndex.components(rr: rr)"))
        coach = strip_comments(read(ROOT / "Strand/AI/AICoach.swift"))
        self.assertIn("TestCentre.active(.stress), let line = await stressIndexLine()", coach)


class IllnessHasOneResolver(unittest.TestCase):
    def test_app_never_builds_engine_inputs(self) -> None:
        pattern = r"IllnessSignalEngine\.(SignalReading|Inputs)\s*\("
        self.assertEqual([], files_matching(pattern, app_files()))

    def test_app_model_holds_no_illness_math(self) -> None:
        app_model = strip_comments(read(ROOT / "Strand/App/AppModel.swift"))
        start = app_model.index("private func evaluateIllness(")
        illness = app_model[start:app_model.index("func evaluateStrainTarget(", start)]
        for forbidden in ("Baselines.foldHistory", "Baselines.deviation", "skinTempIllnessZ", "zIllnessward"):
            self.assertNotIn(forbidden, illness, forbidden)
        self.assertIn("IllnessSignalEngine.reading(days: days)", illness)

    def test_distance_alternate_is_test_centre_only(self) -> None:
        app_model = strip_comments(read(ROOT / "Strand/App/AppModel.swift"))
        gate = app_model.index("illnessDistance = TestCentre.active(.stress)")
        self.assertLess(gate, app_model.index("IllnessDistance.evaluate("))


class SleepNeedHasOneResolver(unittest.TestCase):
    def test_pattern_insights_duplicate_stays_removed(self) -> None:
        self.assertEqual([], files_matching(r"\bsleepNeedTonight\b", all_apple_files(), code_only=False))
        self.assertIn("static func needTonight(", read(ANALYTICS / "SleepDebt.swift"))


class TrainingLoadHasOneModel(unittest.TestCase):
    def test_acwr_is_not_computed_or_shown(self) -> None:
        # Training load is CTL/ATL/TSB only (TrainingLoadEngine); ACWR is gone from every output.
        # Tests are excluded: one asserts the signal is absent by naming it.
        hits = files_matching(r"\bacwr\b|acwrSignal|trainingLoad\(acute", app_files() + swift_files(ANALYTICS))
        self.assertEqual([], hits)


class AlternatesStayOffIOS(unittest.TestCase):
    def test_ios_only_targets_do_not_read_alternate_engines(self) -> None:
        ios_only = swift_files("StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "ZoopWatch", "ZoopWatchComplications")
        pattern = r"\b(ReadinessEngine|WatchRecovery|HRVReadiness|VitalityEngine|StressIndex|IllnessDistance)\b"
        self.assertEqual([], files_matching(pattern, ios_only))

    def test_vitality_card_is_test_centre_only_on_ios(self) -> None:
        cards = strip_comments(read(ROOT / "Strand/Screens/DashboardCards.swift"))
        self.assertIn("if self == .vitality { return TestCentre.active(.longevity) }", cards)

    def test_readiness_pill_is_not_drawn_under_recovery_on_ios(self) -> None:
        coupled = read(ROOT / "Strand/Screens/CoupledView.swift")
        pill = coupled.index("readinessPill(word)")
        self.assertGreater(pill, coupled.rindex("#if !os(iOS)", 0, pill))
        self.assertLess(coupled.rfind("#endif", 0, pill), coupled.rindex("#if !os(iOS)", 0, pill))


if __name__ == "__main__":
    unittest.main()
