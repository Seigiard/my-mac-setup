#!/bin/sh
# After the #576 rounds: merge repetitions, export the blind packet, split per case with the minor sample, dispatch one blind adjudicator per case.
H=/Users/andrew.b/.local/state/revmux-bench/576-holdout; A=/Users/andrew.b/Projects/my-mac-setup/scripts/analyze_revmux_benchmark.py
set -e
python3 $H/merge.py $H
mkdir -p $H/packet $H/adjudication/in $H/adjudication/out
python3 $A export-blind --tasks-dir $H/archive --out $H/packet --key $H/key.json
python3 $A --tasks-dir $H/archive --json > $H/analysis.json
python3 $H/split.py $H/packet/packet.json $H/adjudication/in
python3 $H/prompts.py
for p in $H/adjudication/prompt-case-*.md; do
  n=$(basename $p .md | sed 's/prompt-//')
  herdr-child start --kind opencode --posture rw --model openai/gpt-5.6-terra --effort high --cwd $H/adjudication --prompt-file $p --label adj576-$n --detach --timeout 90000 2>&1 | tail -1 | cut -c1-80
done
