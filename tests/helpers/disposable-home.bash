# Answers one question: has this environment declared its $HOME disposable?
#
# Deliberately dependency-free. This file defines a function and nothing else,
# so it can be sourced from a plain `bash -c` with a controlled environment --
# which is how tests/bashunit/idempotent_test.sh proves the table below.

# Echoes exactly one of: run, skip, misconfigured.
#
# MMS_DISPOSABLE_HOME is the only thing that grants `run`. GITHUB_ACTIONS and
# /.dockerenv are read here too, but only to tell a workstation apart from a
# runner that lost its marker -- never to grant the run verdict. Reading them
# for permission would re-create the bug this guard exists to stop: a developer
# who exports CI in their shell, or a long-lived dev container holding real
# work, would get a real `chezmoi apply` over their live dotfiles.
#
# The truth rule is exact-match "1". MMS_CI_MINIMAL treats any non-empty value
# as true; this guard diverges on purpose, because a safety guard fails closed.
# MMS_DISPOSABLE_HOME=0 therefore skips rather than running.
mms_disposable_home_verdict() {
  if [[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]]; then
    echo "run"
    return 0
  fi

  # GITHUB_ACTIONS is written by GitHub, /.dockerenv by the container runtime.
  # This repository can write neither and delete neither, which is what makes
  # them non-circular ground truth for "a marker should have been here".
  if [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -f /.dockerenv ]]; then
    echo "misconfigured"
    return 0
  fi

  echo "skip"
}
