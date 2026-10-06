import yaml from "eslint-plugin-yml";

export default [
  { ignores: ["**/node_modules/**", ".worktrees/**", ".claude/worktrees/**", ".context/**", "archive/**"] },
  ...yaml.configs.base,
];
