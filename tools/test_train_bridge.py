"""Play each certified trick-taking variant through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"tricks-{variant}-{teacher}", "players": 4})
        widths = set()
        phases = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            widths.add(len(encoding["values"]))
            assert encoding["decision_id"] == observation["decision_id"]
            assert len(encoding["actions"]) == 286
            legal = [action for action in encoding["actions"] if action is not None]
            assert legal == observation["action_schema"]["enum"]
            assert len(legal) == len({json.dumps(action, sort_keys=True) for action in legal})
            view = observation["semantic_view"]
            assert len(view["seats"]) == 4
            assert len(view["own_cards"]) <= 13
            phases.add(view["phase"])
            if view["phase"] == "pass":
                assert len(legal) == 286
                assert all(len(action["cards"]) == 3 for action in legal)
            action = json.loads(request({"kind": "teacher"})["response"]) if teacher else rng.choice(legal)
            assert action in legal
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 240
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1", "2", "3"}
        assert all(0 <= score <= 1 for score in observation["scores"].values())
        assert abs(sum(observation["scores"].values()) - 2) < 1e-9
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, sorted(phases), widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    for variant in ("euchre", "spades", "hearts", "oh-hell"):
        for teacher in (True, False):
            play(binary, variant, teacher)
