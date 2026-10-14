export const OPENCODE_V2_CAPTURED_EVENTS = {
  shell: {
    tool: "shell",
    input: {
      command: "printf 'shell-control\\n' > shell-effect.txt",
      workdir: "/tmp/agent-hooks-v2",
    },
  },
  write: {
    tool: "write",
    input: {
      path: "/tmp/agent-hooks-v2/write-effect.txt",
      content: "write-control\n",
    },
  },
  edit: {
    tool: "edit",
    input: {
      path: "/tmp/agent-hooks-v2/edit-effect.txt",
      oldString: "edit-before\n",
      newString: "edit-after\n",
    },
  },
  nestedFffGrep: {
    tool: "fff_grep",
    input: {
      query: "TDD_FFF_CONTROL",
      maxResults: 3,
    },
  },
} as const;
