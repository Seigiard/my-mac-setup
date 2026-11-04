const LEASE = ["caffeinate", ["-d", "-i", "-t", "25"]];

const QUIET_GRACE_MS = 1200 * 1000;

const LEASE_RENEWAL_MS = 15 * 1000;

function hasWorkingLocalTerminal(terminals) {
  return terminals.some((terminal) =>
    terminal.state === "live" &&
    terminal.status === "working" &&
    !terminal.address.includes("/")
  );
}

export function createKeepAwake({ exec, now, terminals }) {
  let lastLeaseStartedAt = null;
  let lastWorkingAt = null;

  async function startLease(startedAt) {
    lastLeaseStartedAt = startedAt;

    try {
      await exec(...LEASE);
    } catch {
      if (lastLeaseStartedAt === startedAt) lastLeaseStartedAt = null;
    }
  }

  return {
    tick() {
      const currentTime = now();
      const working = hasWorkingLocalTerminal(terminals());

      if (working) lastWorkingAt = currentTime;

      const inGrace = lastWorkingAt !== null && currentTime - lastWorkingAt < QUIET_GRACE_MS;

      if ((!working && !inGrace) ||
          (lastLeaseStartedAt !== null && currentTime - lastLeaseStartedAt < LEASE_RENEWAL_MS)) return;

      return startLease(currentTime);
    },
  };
}
