"""Check full private evidence, source pins, and exact selected teacher labels."""

import hashlib
import json
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
assert manifest["format"] == "coworld-private-candidates-v1"
assert len(manifest["runs"]) >= 10
for path in [root, *root.rglob("*")]:
    assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600)
assert not (root / "train.jsonl").exists()
assert not (root / "validation.jsonl").exists()
total_labels = 0
for run in manifest["runs"]:
    events = [json.loads(line) for line in (root / run["trajectory"]).read_text().splitlines()]
    assert events[-1]["event_type"] == "episode" and events[-1]["status"] == "completed"
    assert events[-1]["source_revision"] == manifest["source_revision"]
    seed_family = manifest["game"] + "-" + str(run["seed"])
    assert events[-1]["seed_family"] == seed_family
    assert set(events[-1]["participant_outcomes"]) == {"0", "1", "2", "3"}
    label_count = 0
    actual_labels = []
    for decision in events[:-1]:
        assert decision["visibility"] == "private"
        assert decision["source_revision"] == manifest["source_revision"]
        if decision["action_status"] == "fallback":
            assert decision["selected_attempt_id"] is None and decision["fallback_origin"]
            continue
        selected = next(a for a in decision["attempts"] if a["attempt_id"] == decision["selected_attempt_id"])
        assert selected["origin"] == "teacher" and selected["policy"] == manifest["selection"]["policy"]
        assert selected["accepted"] and selected["parsed_action"] == decision["executed_action"]
        assert selected["model"] is None and selected["request"] is None and selected["platform_call_id"] is None
        system, user = [m["content"] for m in selected["prompt"]]
        metadata = decision["observation"]["prompt_template"]
        assert metadata["system_sha256"] == hashlib.sha256(system.encode()).hexdigest()
        assert metadata["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
        assert metadata["variant"] not in ("heldout-briefing", "heldout-reference")
        assert json.loads(selected["response"]) == decision["executed_action"]
        actual_labels.append(
            {
                "decision_index": decision["decision_index"],
                "decision_id": decision["decision_id"],
            }
        )
        label_count += 1
    assert label_count == run["labels"] and actual_labels == run["label_ids"]
    total_labels += label_count
assert total_labels == manifest["candidate_examples"]
print(manifest["variant"], len(manifest["runs"]), "complete private episodes passed")
