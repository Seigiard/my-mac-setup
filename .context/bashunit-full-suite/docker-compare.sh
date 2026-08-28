# Command string for: docker compose -f docker/docker-compose.yml run --rm -T test-ubuntu "$(cat this-file)"
# Mirrors the test-ubuntu service staging, then runs the per-file side-by-side
# comparison (bats vs bashunit) for all five files instead of the plain suite.
set -e
echo "=== Staging writable test worktree ==="
mkdir -p /home/testuser/worktree/.git /home/testuser/worktree/docs /home/testuser/worktree/scripts
cp -r /home/testuser/dotfiles /home/testuser/worktree/home
cp -r /home/testuser/tests /home/testuser/worktree/tests
cp /home/testuser/issues-cli /home/testuser/worktree/scripts/issues
cp -r /home/testuser/issues /home/testuser/worktree/docs/issues
cp /home/testuser/Makefile /home/testuser/worktree/Makefile
cp /home/testuser/README.md /home/testuser/worktree/README.md
rm -rf /home/testuser/worktree/home/private_dot_claude/dot_smithers/node_modules
cd /home/testuser/worktree

echo "=== Copying dotfiles to chezmoi source ==="
(cd home && cp -r . /home/testuser/.local/share/chezmoi/)

echo "=== Initializing chezmoi ==="
chezmoi init --source=/home/testuser/.local/share/chezmoi \
  --promptString name="Test User" \
  --promptString email="test@example.com"

echo "=== Applying dotfiles (with package installation) ==="
chezmoi apply --source=/home/testuser/.local/share/chezmoi --verbose

echo "=== Side-by-side comparison: bats vs bashunit (full mode) ==="
mkdir -p .context/bashunit-full-suite
overall=0
for f in platform palette smoke scripts idempotent; do
  echo "### $f"
  bash tests/bashunit/compare-suite-file.sh "$f" || overall=1
done
echo "=== Paired timing (full mode, 3 reps) ==="
bash tests/bashunit/bench-bats-vs-bashunit.sh full 3 || overall=1
cat .context/bashunit-full-suite/bench-full.csv || true
exit $overall
