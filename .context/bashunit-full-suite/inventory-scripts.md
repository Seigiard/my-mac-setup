# Inventory: tests/scripts.bats (Bats → bashunit migration)

Source file: `tests/scripts.bats` (6437 lines). Reference helper: `tests/helpers/common.bash` (loaded via `load 'helpers/common'`, which itself loads bats-support, bats-assert, bats-file and sources `disposable-home.bash`). Second helper loaded: `load 'helpers/herdr_task_sync'` (provides every `hts_*` function; not inventoried here per task scope, but its API surface used by this file is listed below).

## 1. Test list

**Exact @test count found: 254** (matches expectation).

Names exactly as written, with source line numbers:

1. `python3 is present and at least 3.9, the floor README.md declares` (line 45)
2. `lint target propagates shellcheck failures` (line 53)
3. `CI-minimal Linux render skips Homebrew but keeps the remaining setup` (line 88)
4. `full Linux render keeps Homebrew package installation` (line 102)
5. `CI-minimal non-Linux render keeps Homebrew package installation` (line 114)
6. `install-packages script renders as valid bash` (line 126)
7. `macos-tunes script is valid bash` (line 138)
8. `darwin scripts excluded from managed list on Linux` (line 144)
9. `ask-in-herdr script requires arguments` (line 197)
10. `ask.sh rejects unknown agents and the removed headless flag` (line 204)
11. `ask.sh refuses outside herdr and when herdr-child is absent` (line 224)
12. `ask.sh starts a read-only live child and returns its answer` (line 242)
13. `ask.sh keeps a settled answer when the parent reminder cannot be queued` (line 263)
14. `ask.sh forwards posture and every native caller option` (line 274)
15. `ask.sh retries a colliding derived name with a valid suffix` (line 293)
16. `ask.sh reports blocked children after printing their answer` (line 302)
17. `ask.sh reports undelivered when child output cannot be read` (line 321)
18. `ask.sh reports a still-working child with exit 124` (line 330)
19. `ask.sh classifies successful waits with working, unknown, and fallback statuses` (line 340)
20. `ask.sh maps child start failures to refused or undelivered` (line 363)
21. `herdr-child requires a subcommand and herdr environment` (line 781)
22. `herdr-child refuses pi read-only before splitting a pane` (line 793)
23. `herdr-child start requires exactly one explicit mode before Herdr mutation` (line 801)
24. `herdr-child validates tab placement before Herdr mutation` (line 825)
25. `herdr-child validates launch and supervision timeouts before Herdr mutation` (line 844)
26. `herdr-child attached mode starts no watcher` (line 878)
27. `herdr-child detached mode fails closed without a parent session` (line 891)
28. `herdr-child detached mode closes only its new pane without a child session` (line 901)
29. `herdr-child detached mode returns only after liveness and causal watcher arming` (line 912)
30. `herdr-child detached arm failure preserves the child and returns recovery JSON` (line 931)
31. `herdr-child signal before prompt submission closes owned state and pane` (line 947)
32. `herdr-child catchable launch signals preserve ownership after prompt submission` (line 1001)
33. `herdr-child signal and arm handshake resolves abort before reporting supervision` (line 1066)
34. `herdr-child detached watcher ignores stale settlement and delivers a fresh observed outcome` (line 1142)
35. `herdr-child detached timeout wakes once and later settlement wakes the same generation` (line 1162)
36. `herdr-child detached delivery follows parent terminal identity and fails closed on session replacement` (line 1183)
37. `herdr-child detached delivery retries temporary parent blockage and prompt transport failure` (line 1205)
38. `herdr-child detached delivery uses capped increasing retry backoff and one terminal failure` (line 1243)
39. `herdr-child transient pane reads never become child-gone and delivery continues` (line 1261)
40. `herdr-child superseded watcher cannot publish failure metadata over a new generation` (line 1280)
41. `herdr-child watcher switches from fresh polling to sliced agent wait` (line 1307)
42. `herdr-child sliced wait revalidates generation before liveness refresh` (line 1327)
43. `herdr-child sliced wait publishes one typed non-timeout failure` (line 1353)
44. `herdr-child detached watcher rejects malformed state and child identity replacement` (line 1367)
45. `herdr-child reap invalidates before close while spontaneous loss wakes the parent` (line 1393)
46. `herdr-child failed reap restores supervision for the kept child` (line 1421)
47. `herdr-child detached ask follows parent identity and suppresses its ordinary blocked wake` (line 1454)
48. `herdr-child attached ask follows captured parent identity after the parent moves` (line 1482)
49. `herdr-child callback intent suppresses blocked wake until confirmed receipt` (line 1496)
50. `herdr-child callback delivery exhaustion keeps decision waiting and blocks reap` (line 1533)
51. `herdr-child detached callbacks fail closed when supervision metadata is unreadable` (line 1567)
52. `herdr-child detached reply advances generation and rearms later settlement` (line 1598)
53. `herdr-child managed prompt requires a mode and attached wait observes a newer sequence` (line 1622)
54. `herdr-child attached prompt wait rejects the first one-step settlement after a working baseline` (line 1644)
55. `herdr-child managed detached prompt advances generation and preserves the child on rearm failure` (line 1665)
56. `herdr-child continuation preflight failures preserve the prior generation` (line 1708)
57. `herdr-child attached child promoted to detach asks through validated metadata` (line 1764)
58. `herdr child source contracts document attached and detached lifecycle boundaries` (line 1788)
59. `herdr-child rejects invalid and live names before splitting` (line 1811)
60. `herdr-child maps claude postures and skill directories` (line 1825)
61. `herdr-child maps opencode permissions, model, and configured agent` (line 1840)
62. `herdr-child maps pi model, effort, skills, and question exclusion` (line 1855)
63. `herdr-child rejects native options that the selected kind cannot map` (line 1867)
64. `herdr-child splits, starts, and prompts in order with both coordinates` (line 1881)
65. `herdr-child tab mode records ownership before starting an attached child` (line 1896)
66. `herdr-child tab launch signal closes a parsed creation before ownership publication` (line 1915)
67. `herdr-child tab mode composes with detached supervision` (line 1954)
68. `herdr-child tab mode preserves malformed creations and cleans owned failures` (line 1965)
69. `herdr-child tab mode reports the tab on timeout and names it on launch failure` (line 1986)
70. `herdr-child caps startup timeout while preserving a long prompt wait` (line 2005)
71. `herdr-child retries only the pane-readiness start failure` (line 2016)
72. `herdr-child closes its pane after three readiness failures` (line 2032)
73. `herdr-child distinguishes a stalled initial prompt` (line 2042)
74. `herdr-child preserves a working pane when the wait times out` (line 2050)
75. `herdr-child ask requires every injected child coordinate` (line 2060)
76. `herdr-child ask publishes before delivery and uses the versioned marker` (line 2069)
77. `herdr-child ask leaves the label when parent lookup or delivery fails` (line 2088)
78. `herdr-child reply validates the live pair, delivers, then clears` (line 2107)
79. `herdr-child ask and reply publish strictly increasing label sequences` (line 2137)
80. `herdr-child reply keeps the label when delivery fails and refuses child callers` (line 2153)
81. `herdr-child reap closes only settled, unfocused, non-waiting panes` (line 2168)
82. `herdr-child reap closes an unfocused idle pane` (line 2184)
83. `herdr-child reap rejects an empty expected pane` (line 2196)
84. `herdr-child reap preserves a reused name outside the expected pane` (line 2206)
85. `herdr-child reap preserves a pane when fresh state no longer matches` (line 2217)
86. `herdr-child reap refuses outside herdr and from a child pane` (line 2229)
87. `herdr-child reap preserves a settled pane with a waiting label` (line 2240)
88. `herdr-child reap preserves a settled pane when pane metadata is malformed` (line 2251)
89. `herdr-child reap closes a positively owned one-pane tab` (line 2262)
90. `herdr-child reap closes the child pane but reports a surviving multi-pane tab` (line 2273)
91. `herdr-child reap preserves ambiguous tab ownership` (line 2282)
92. `herdr-child tab reap invalidates detached supervision before close` (line 2294)
93. `herdr-integrations script exits 0 and skips when herdr is absent` (line 2316)
94. `fff-grep-guard denies a query of several bare words` (line 2334)
95. `fff-grep-guard stays silent on a single identifier` (line 2344)
96. `fff-grep-guard stays silent on a path-scoped or glob-scoped query` (line 2355)
97. `fff-grep-guard fails open on malformed input` (line 2369)
98. `webfetch-markdown-hint adds context for a plain URL` (line 2375)
99. `webfetch-markdown-hint stays silent when the URL already uses markdown.new` (line 2386)
100. `settings template registers both PreToolUse hooks with their matchers` (line 2395)
101. `herdr-task-sync descriptor probe lives in a one-test Bats file` (line 2416)
102. `herdr-task-sync bounded Bats invocation exits after detached work` (line 2424)
103. `herdr-task-sync bounded Bats invocation refuses a vacuous run` (line 2736)
104. `herdr-task-sync harness fresh reads follow pane and tab mutations` (line 2756)
105. `herdr-task-sync harness controls reverse model completion by generation` (line 2784)
106. `herdr-task-sync harness isolates colliding sanitized socket names` (line 2808)
107. `herdr-task-sync harness applies source metadata sequence and clear rules` (line 2841)
108. `herdr-task-sync harness models target loss move reuse and final-read change` (line 2860)
109. `herdr-task-sync latest committed request survives stale completion and a third request` (line 2894)
110. `herdr-task-sync active native session fences reused pane and session identifiers` (line 2929)
111. `herdr-task-sync prompt transcript and direct set share one committed-generation contract` (line 2953)
112. `herdr-task-sync failed latest model retains newest context and prior slug` (line 2987)
113. `herdr-task-sync atomic records never expose truncation or mixed fields` (line 3014)
114. `herdr-task-sync one-way legacy import is atomic idempotent and ignores late legacy writes` (line 3076)
115. `herdr-task-sync restart recovers accepted and interrupted worker generations` (line 3112)
116. `herdr-task-sync clock rollback and restart cannot lower generation or task high-water` (line 3143)
117. `herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions` (line 3180)
118. `herdr-task-sync fail-open guard ignores terminal input and preserves redirected input` (line 3213)
119. `herdr-task-sync fail-open deadline rejects late success before the hang guard` (line 3263)
120. `herdr-task-sync fail-open guard uses the greater baseline` (line 3275)
121. `herdr-task-sync fails open for missing tools contention write failure and malformed input` (line 3285)
122. `herdr-task-sync orders adapter calls by inbox commit rather than invocation start` (line 3356)
123. `herdr-task-sync adapters return when a direct engine hangs` (line 3385)
124. `herdr-task-sync opencode forgets a deleted child session` (line 3478)
125. `herdr-task-sync presentation coordinates concurrent panes in one shared tab` (line 3507)
126. `herdr-task-sync presentation accepts pi jsonl path sessions that end with the active session id` (line 3528)
127. `herdr-task-sync presentation labels a detected agent without task state` (line 3546)
128. `herdr-task-sync presentation publishes only the newest accepted generation` (line 3561)
129. `herdr-task-sync presentation coalesces event bursts into an active pass and rerun` (line 3589)
130. `herdr-task-sync presentation retries a newer invalidation after transient pass failure` (line 3612)
131. `herdr-task-sync presentation release recheck does not lose a pending invalidation` (line 3631)
132. `herdr-task-sync event presentation leaves the hook process group` (line 3652)
133. `herdr-task-sync presentation automatically corrects divergent pane and tab labels` (line 3673)
134. `herdr-task-sync presentation drops a malformed-width record and keeps labeling the rest` (line 3698)
135. `herdr-task-sync presentation skips pre-read deletion and repairs the post-read race next pass` (line 3718)
136. `herdr-task-sync presentation skips reused pane and tab identities at the final read` (line 3746)
137. `herdr-task-sync age cleanup removes only inactive task payloads` (line 3775)
138. `herdr-task-sync presentation preserves state on incomplete and transient snapshots` (line 3803)
139. `herdr-task-sync naming worker never age-cleans tasks without safe snapshot ownership` (line 3827)
140. `herdr-task-sync presentation isolates exact colliding socket identities` (line 3868)
141. `herdr-task-sync presentation recovers stale and half-created owner claims` (line 3887)
142. `herdr-task-sync presentation resumes safely across durable crash boundaries` (line 3956)
143. `herdr-task-sync presentation self-events converge to a no-op` (line 3975)
144. `herdr-task-sync presentation fails closed without an exact socket` (line 3989)
145. `herdr-task-sync presentation restart recomputes durable pending intent without a label ledger` (line 4003)
146. `herdr-task-sync location resolves main linked nested and administrative paths with strict foreground semantics` (line 4018)
147. `herdr-task-sync dangling administrative gitdir retains stale location` (line 4061)
148. `herdr-task-sync location detached publishes a commit ref and non-Git clears are source-local with monotonic restart high-water` (line 4087)
149. `herdr-task-sync location real probe shape pays the second sha call only when detached` (line 4127)
150. `herdr-task-sync location detached sha failure retains prior identity as stale and never publishes a malformed git_ref` (line 4164)
151. `herdr-task-sync location detached sha budget failure with no prior state renders no git location and self-heals` (line 4200)
152. `herdr-task-sync location clears the retired location_label token on both publish and non-git clear paths` (line 4233)
153. `herdr-task-sync location transient modes retain identity as stale without foreground fallback` (line 4260)
154. `herdr-task-sync coordinator resolves eight pane locations concurrently within one event envelope` (line 4306)
155. `herdr-task-sync no-op location event preserves the state file` (line 4400)
156. `herdr-task-sync transient location preserves live token-only identity when retained state is unavailable` (line 4425)
157. `herdr-task-sync location authoritative worktree deletion clears retained evidence` (line 4465)
158. `herdr-task-sync formatter keeps Git refs in metadata and tab labels names-only` (line 4484)
159. `herdr-task-sync formatter renders a main checkout ref in metadata only` (line 4515)
160. `herdr-task-sync formatter renders a worktree ref in metadata only` (line 4533)
161. `herdr-task-sync formatter keeps a Git-backed all-idle tab names-only` (line 4552)
162. `herdr-task-sync Git-only location changes do not rename a names-only tab` (line 4570)
163. `herdr-task-sync formatter keeps the folder qualifier on a main checkout in a differently-named folder` (line 4593)
164. `herdr-task-sync formatter reads the workspace display name from the legacy name field when label is absent` (line 4613)
165. `herdr-task-sync formatter gives a detached HEAD inside a linked worktree the commit icon` (line 4631)
166. `herdr-task-sync formatter qualifies a divergent worktree folder in metadata only` (line 4651)
167. `herdr-task-sync formatter keeps mixed Git identities out of tabs and repairs external labels` (line 4672)
168. `herdr-task-sync formatter joins only pane labels when three panes span two repositories` (line 4703)
169. `herdr-task-sync worktree tokens use shortest unique slash suffixes for basename collisions` (line 4723)
170. `herdr-task-sync worktree tokens digest overlong roots and extend colliding digest prefixes` (line 4747)
171. `herdr-task-sync worktree token ordinal fallback is unique and stable under pane reordering` (line 4776)
172. `herdr-task-sync long branch refs stay in metadata and do not alter the tab label` (line 4804)
173. `herdr-task-sync long repository names do not alter a multi-repo tab label` (line 4822)
174. `herdr-task-sync location clears a retired location_label even when every published token already matches` (line 4842)
175. `herdr-task-sync location and formatter add only approved static icon glyphs and no forbidden ownership state` (line 4875)
176. `herdr-task-sync publishes dirty ahead and behind counts beside an unchanged git_ref` (line 4909)
177. `herdr-task-sync clean checkout carries no counts token and republishes when only the counts change` (line 4939)
178. `herdr-task-sync counts every changed path once whether it is staged, unstaged, both, or untracked` (line 4969)
179. `herdr-task-sync omits ahead and behind when the branch has no upstream` (line 4994)
180. `herdr-task-sync clears the counts token when a pane leaves a Git checkout` (line 5020)
181. `herdr-task-sync status probe over budget drops the counts and leaves git_ref intact` (line 5046)
182. `herdr-task-sync agent pane follows the directory its own statusline reports, not its launch directory` (line 5082)
183. `herdr-task-sync keeps the counts when only the identity probe misses its budget` (line 5115)
184. `herdr-task-sync counts untracked paths its way, not the user git config's way` (line 5141)
185. `herdr-task-sync writer and reader agree on the record name for an awkward session id` (line 5163)
186. `herdr-task-sync falls back to the pane cwd when the reported directory is gone` (line 5195)
187. `herdr-task-sync ignores an agent directory report that is not an absolute path` (line 5216)
188. `herdr-task-sync reads the newest agent directory report when a session moves twice before a sweep` (line 5237)
189. `herdr-task-sync plugin exposes only the approved pane, tab, and worktree invalidations` (line 5262)
190. `herdr-task-sync plugin wrappers invoke one engine mode and isolate failures` (line 5288)
191. `herdr-task-sync event requests reconciliation and ensures the daemon fail-open` (line 5320)
192. `herdr-task-sync sweep repairs an external pane rename without pane.updated` (line 5353)
193. `herdr-task-sync sweep repairs process and CWD changes through the presentation coordinator` (line 5368)
194. `herdr-task-sync stays silent outside herdr` (line 5398)
195. `herdr-task-sync publishes the engine slug and stores it (R4, R7)` (line 5409)
196. `herdr-task-sync keeps the slug on a continuation prompt (AE1)` (line 5424)
197. `herdr-task-sync publishes nothing when no engine is usable (AE3, R5)` (line 5448)
198. `herdr-task-sync resets the stored context on a new session id` (line 5471)
199. `herdr-task-sync returns before the naming engine finishes (R8)` (line 5500)
200. `herdr-task-sync normalizes a hostile engine slug (KTD8)` (line 5519)
201. `herdr-task-sync exits under the recursion guard (KTD7)` (line 5543)
202. `herdr-task-sync falls back to claude when pi fails (KTD1)` (line 5555)
203. `herdr-task-sync publishes nothing when both engines time out (KTD1)` (line 5564)
204. `herdr-task-sync creates its state directory with mode 700 (KTD3)` (line 5573)
205. `herdr-task-sync names a session from its transcript (AE5)` (line 5585)
206. `herdr-task-sync publishes nothing for an empty prompt without a transcript` (line 5604)
207. `herdr-task-sync --set publishes a normalized name with no engine call (AE6)` (line 5614)
208. `herdr-task-sync names the pane with the agent prefix` (line 5627)
209. `herdr-task-sync falls back to a letter prefix for an unknown agent` (line 5636)
210. `herdr-task-sync rebuilds the tab label from the pane labels` (line 5646)
211. `herdr-task-sync names a command pane after the process group leader` (line 5664)
212. `herdr-task-sync names an idle pane with the placeholder` (line 5684)
213. `herdr-task-sync presentation numbers an all-idle tab` (line 5703)
214. `herdr-task-sync truncates a long command name` (line 5719)
215. `herdr-task-sync --sweep relabels every tab` (line 5738)
216. `herdr-task-sync --sweep leaves an unchanged tab label alone` (line 5760)
217. `herdr-task-sync --sweep numbers all-idle tabs per workspace` (line 5779)
218. `herdr-task-sync --ensure-daemon keeps a single daemon` (line 5809)
219. `herdr-task-sync --ensure-daemon replaces a dead daemon` (line 5824)
220. `herdr-task-sync --restart-daemon replaces a live daemon` (line 5842)
221. `herdr-task-sync --restart-daemon refuses an unrelated lock owner` (line 5867)
222. `herdr-task-sync sweep daemon exits after three unreachable snapshots` (line 5883)
223. `herdr-task-sync hook stays silent and publishes nothing outside herdr` (line 5930)
224. `herdr-task-sync hook writes nothing to stdout when the engine runs` (line 5948)
225. `herdr-task-sync hook forwards the prompt, session, and transcript` (line 5958)
226. `herdr-task-sync hook calls transcript mode on session start and compact` (line 5971)
227. `herdr-task-sync hook drops subagent traffic (R3)` (line 5988)
228. `herdr-task-sync hook survives malformed stdin` (line 5998)
229. `se pipeline --setup-cmd lands in the workflow input JSON` (line 6005)
230. `se flow --dry-run lands spec path, budget, and setup-cmd in the workflow input JSON` (line 6015)
231. `se flow --validate-cmd lands the operator's command in the workflow input JSON` (line 6029)
232. `se flow without --validate-cmd sends an empty command, not a missing key` (line 6042)
233. `se flow --dry-run prints the composed flow with a cost estimate (R10)` (line 6052)
234. `se flow refuses a spec the validator rejects, before launching` (line 6071)
235. `se flow rejects a non-numeric budget` (line 6087)
236. `se show prints the pending approval's title and reasons, not just a status word` (line 6120)
237. `se approve prints what is being decided before recording the decision` (line 6135)
238. `se show on a run with no pending approval prints no decision block` (line 6148)
239. `se approve resumes a parked run that nothing is driving` (line 6161)
240. `se approve --no-resume records the decision without driving the run` (line 6178)
241. `se approve refuses to resume a run a live process already owns` (line 6193)
242. `se approve does not resume a run that already finished` (line 6212)
243. `se approve usage does not promise that approve continues the run` (line 6227)
244. `se blocks --json emits the composable block catalog` (line 6235)
245. `Claude settings modifier registers the executor MCP server over stdio` (line 6256)
246. `Claude settings modifier passes settings through untouched without 1Password` (line 6289)
247. `Pi settings modifier selects the terminal theme and exact extension packages` (line 6307)
248. `Pi settings modifier is idempotent` (line 6335)
249. `Pi terminal theme uses only terminal palette colors` (line 6361)
250. `Claude Code daltonized theme extends light ANSI with terminal colors` (line 6374)
251. `morning-cleanup trashes stale .omc state and stamps the day` (line 6389)
252. `morning-cleanup keeps a recently active .omc dir` (line 6402)
253. `morning-cleanup is a no-op on its second run of the day` (line 6413)
254. `morning-cleanup keeps fresh trash entries` (line 6428)

## 2. Bats features used, per test group

Groups are contiguous line ranges sharing identical mechanics. Test numbers refer to the list above.

### G1 — python3 floor (test 1, line 45)
- No `run`. Calls `assert_python3_available` from common.bash, which uses bats-support `fail` (prints + returns 1). Deliberately asserts instead of skipping.
- External: `python3` on PATH, version ≥ 3.9.

### G2 — lint target (test 2, line 53)
- `skip "repo-root Makefile is not available in this environment"` if `$BATS_TEST_DIRNAME/../Makefile` missing.
- `mktemp -d` stub dir with a failing `shellcheck` shim, `chmod +x`, `run env PATH="$stubdir:$PATH" make -C "$repo_root" lint`, `rm -rf`, `assert_failure`.
- Uses `$BATS_TEST_DIRNAME`. External: `make`, real repo Makefile.

### G3 — install-packages renders (tests 3–6, lines 88–132)
- `skip_if_no_chezmoi` (common.bash → `skip "chezmoi not installed"`).
- `write_test_config` / `render_install_packages` drive `chezmoi execute-template` with `PATH="$PATH_WITHOUT_OP"` and `--source "$SOURCE_ROOT"`. Env `MMS_CI_MINIMAL` set per test at call time.
- `$BATS_TEST_TMPDIR` for config files; `sed -i.bak` edits.
- `run` + `assert_success`, `assert_output --partial`, `refute_output --partial`.
- Test 6 sets the global `BATS_TEST_TMPFILE` (cleaned by file-level `teardown`), then `run bash -n`.

### G4 — macos-tunes / darwin managed (tests 7–8, lines 138–149)
- Test 7: `run bash -n "$SOURCE_ROOT/..."`, `assert_success`.
- Test 8: `is_linux || skip "Only relevant on Linux"`; `skip_if_no_chezmoi`; `PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed` (env-prefixed `run`); `refute_output --partial`. Reads the **host's live chezmoi source state** — environment-dependent, not hermetic.

### G5 — ask-in-herdr ask.sh (tests 9–20, lines 197–375)
- File-level constant `ASK_HERDR_DIR="$SOURCE_ROOT/private_dot_claude/skills/ask-in-herdr/scripts"` evaluated at load time.
- Helper `ask_live_stub`: `mktemp -d` → exported global `CHILD_STUB` containing fake `herdr-child` and `herdr` executables (heredoc scripts, `chmod +x`). Stub behavior driven by env vars: `STUB_CHILD_STATUS`, `STUB_NAME_COLLISION` (uses `$PPID` and `ps -o ppid=`), `STUB_READ_FAIL`, `STUB_AGENT_STATUS`, `STUB_PARENT_PROMPT_FAIL`, `STUB_WAITING_LABEL`.
- `run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash .../ask.sh ...`.
- `assert_failure 2` / `assert_failure 1` / `assert_failure 124` (exact status codes); `assert_line --index "$(( ${#lines[@]} - 1 ))" "..."` — reads Bats `$lines` array; `assert_output --partial`; bats-file `assert_file_contains` (regex arg), `assert_file_not_exists`; nested `run grep -E ...` over stub logs then `assert_success`/`assert_failure`; bare `[ ! -f ... ]` mid-test assertions.
- `CHILD_STUB` is removed by file-level `teardown` (`rm -rf`); some tests call `ask_live_stub` several times in one body (fresh stub per phase) — earlier stub dirs leak until process exit (only last is torn down) except where explicitly `rm -rf`'d.

### G6 — herdr-child launch/return contract (tests 21–65, lines 781–2308)
The heaviest group. Shared mechanics:
- File-level constant `HERDR_CHILD="$SOURCE_ROOT/dot_local/bin/executable_herdr-child"`.
- Stub factories `child_stub_herdr` and `child_lifecycle_stub_herdr` (`mktemp -d` → `CHILD_STUB`, exported; a fake `herdr` that logs every call to `calls.log` via `printf '%q '` and answers JSON per state files). Lifecycle stub keeps mutable state files (`child-state`, `parent-pane`, `parent-session`, `generation`, `prompt-fail-count`, …) that tests rewrite mid-flight to simulate transitions.
- Stub-internal blocking loops with `trap 'exit 143' HUP INT TERM` + `while [ ! -e release-file ]; do sleep 0.01; done` (barrier files: `release-prompt`, `release-liveness`, `wait-release`, `release-parent-prompt`, `failure-publish.ready/.release`, …).
- Launch wrappers `child_start` / `child_lifecycle_start` set: `HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 HERDR_CHILD_STATE_DIR HERDR_CHILD_TEST_WATCHER_PID_FILE HERDR_CHILD_TEST_WATCHER_RELEASE HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_TEST_SKIP_RETRY_SLEEP=1`.
- **Background processes**: `--detach` mode spawns a real watcher process; its pid lands in `$CHILD_STUB/watcher.pid`; file-level `teardown` releases and TERM-kills it with a 100×10ms poll loop. Several tests also start `bash "$HERDR_CHILD" ask ... &` / `prompt ... &` and `wait` on them; `sleep 30 &` decoys; deadline subshells `(sleep 30; : > "$deadline") &`.
- Polling helpers `child_wait_for_log` / `child_wait_for_file` / `child_wait_for_get_count` (500 × `sleep 0.01`).
- **Mid-test `teardown; setup` calls** (lines 1102–1104, 1193–1195, 1224–1226, 1376–1378, 1409–1411, 1581–1583, 1686–1688, 1727+/1745+, 1974–1976, 1995–1997): tests explicitly re-run the file-level hooks inside a test body to reset the stub between phases. bashunit has no equivalent semantics; the migration must extract the reset into an ordinary function.
- **python3 heredoc drivers** (tests at lines 947, 1001, 1066, 1915): `run env ... python3 - <<'PY'` spawning `subprocess.Popen(["bash", HERDR_CHILD, ...])`, waiting on barrier files, sending `SIGTERM/SIGHUP/SIGINT`, asserting on stdout/stderr and `calls.log`; one resets the Python-side signal disposition because "Parallel Bats workers ignore SIGINT".
- Assertions: `assert_failure <n>` exact codes (2, 1, 124), `assert_output` (exact and `--partial`), `assert_file_exists/not_exists/contains`, `assert_file_permission 700 "$1"` (line 942 — bats-file permission assertion on the run-state dir), bare `[[ ... ]]` and `[ ... ]` checks, `kill -0` liveness checks, `sed -n Np` call-order assertions, `set -- "$dir"/*` glob counting.
- Env mutated with `export` inside tests: `HERDR_CHILD_MAX_DELIVERY_RETRIES`, `HERDR_CHILD_TEST_RETRY_LOG`, `HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER`, `HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER` — un-set again by the file-level `setup` of the *next* test (this is why `setup` unsets 8 vars).
- One test (line 2416) runs `bats --count` on a sibling one-test file; contract test (line 1788) is pure `assert_file_contains` over docs.

### G7 — herdr-integrations render (test 66, line 2316)
- `skip_if_no_chezmoi`; `[[ -f ... ]] || skip "herdr-integrations script not found"`; renders template to `BATS_TEST_TMPFILE`; `run env PATH="/usr/bin:/bin" bash ...` (deliberately herdr-less PATH); `assert_output --partial`.

### G8 — Claude Code PreToolUse hooks (tests 67–73, lines 2334–2410)
- `command -v jq >/dev/null || skip "jq not available"` on most.
- `run bash "$FFF_GUARD" <<'EOF' ... EOF` (heredoc stdin to `run`); `assert_output ""` (exact empty), `--partial`.
- Test 73 renders `private_settings.json.tmpl` via chezmoi to `BATS_TEST_TMPFILE`, then `run python3 - file <<'PY'` with inline JSON assertions.

### G9 — herdr-task-sync engine + presentation + location + formatter (tests 74–219, lines 2416–5904)
All use `hts_*` helpers from `tests/helpers/herdr_task_sync.bash`. Shared mechanics:
- `hts_setup` (per-test workspace `HTS_WORK`, state dir `HTS_STATE`, stub dir `HTS_STUB`, default socket, `HTS_LOG`); `hts_teardown` runs from the file-level `teardown` for every test in the file.
- `command -v jq || skip "jq not available"` guards ~96 tests; single `command -v perl || skip` (line 4402); two `command -v bun || skip "bun not available"` (lines 3386, 3479).
- Env knobs read by the engine and set per test (often `export`ed and later `unset`): `HERDR_TASK_SYNC_TEST_NO_WORKER`, `_TEST_NO_PRESENTATION`, `_TEST_NOW_SEQ`, `_TEST_NO_DAEMON`, `_TEST_CRASH_AFTER`, `_TEST_PAUSE_BEFORE_RELEASE`, `_TEST_DIGEST_FILE`, `_TEST_LOCATION_BARRIER{,_COUNT,_RELEASE}`, `_LOCK_ATTEMPTS`, `_STATE_MAX_AGE_DAYS`, `_GIT_BUDGET`, `_ACTIVE`, `HTS_TIMEOUT`, `HTS_SWEEP_INTERVAL`, `HTS_FAIL_OPEN_*`, `HTS_BLOCKED_HERDR_POLLS`, `HTS_DESCRIPTOR_{RELEASE,PID,BLOCKED_PID}_FILE`, `LANG`/`LC_ALL` (line 4041), `HOME` overrides.
- **Nested Bats invocations**: test 75 (line 2424) drives `bats <probe file> --filter ...` from a python3 supervisor with two time budgets, pipe-drain threads, `os.kill`, forwards a measurement line to Bats FD 3 (`>&3`, line 2721); test 76 (line 2747) runs `bats "$BATS_TEST_FILENAME" --filter '^herdr-task-sync bounded Bats invocation exits after detached work$'` — **the file re-executes itself**, and asserts the inner run fails.
- **Background jobs + wait**: model stubs launched with `... | "$HTS_STUB/pi" > out &` and generation-ordered release (`hts_release_model`); reader-loop subshell in the atomicity test (line 3020) with `HTS_READER_PID` handed to teardown; `hts_worker_run &`, `hts_presentation_run &` with pid capture, `kill`, `wait`; daemons under `sweep.lock/pid` started by `--ensure-daemon`/`--restart-daemon` and killed in-test; `mkfifo` + delayed-writer subshell (line 3362).
- **python3 heredoc drivers**: pty-based fail-open guard test (line 3217, `pty.openpty`, `start_new_session`, `os.killpg`), adapter-timeout driver running `bun` (line 3434).
- Time manipulation: `touch -t 200001010000` / `202001010000` for age cleanup; `perl -e 'print((stat shift)[9])'` mtime equality; hardlink `ln` + `-ef` identity check (line 4421).
- Fixed sleeps as negative evidence: `sleep 2` (lines 5406, 5551, 5609, 5945), `sleep 6` (5570) — "nothing published after N seconds".
- `ps -o pgid=`/`-o lstart=` process-identity probes; base64-encoded owner records; `kill -0` checks; pid 999999 as a can't-exist pid.
- Assertions: heavy `assert_equal "$(jq -r ...)"`, `run jq -e` on state files and on `$output` (`<<< "$output"`), `run grep -c` + `assert_output "N"` exact counts over `$HTS_LOG`, `assert_line --partial`, `assert_line` (exact), `refute_output --partial`, `assert_dir_exists/not_exists`, `fail "..."` direct calls.
- Test at line 5527 writes to a fixed path `/tmp/htspwn$BATS_TEST_NUMBER` (uses `$BATS_TEST_NUMBER` for uniqueness across parallel jobs).

### G10 — herdr-task-sync Claude Code hook (tests 220–227, lines 5910–6003)
- `hts_hook_setup` puts a recording `herdr-task-sync` stub on PATH; `hts_hook_run` = `env PATH="$HTS_STUB:/usr/bin:/bin" bash "$HTS_HOOK" "$@"` with heredoc JSON stdin.
- `assert_output ""` silence contracts; `assert_file_not_exists` for dropped traffic; one `sleep 2` negative wait; jq skips.

### G11 — se CLI (tests 228–243, lines 6005–6250)
- `run env SE_DRY_RUN=1 "$se_bin" ...` / `--dry-run`; `assert_output --partial` on emitted JSON keys.
- `se_fake_runtime` helper: builds `$BATS_TEST_TMPDIR/se-runtime` with a stub `smithers` binary (records argv to `calls.log`) and a **sqlite3 database** seeded via heredoc SQL; tests then `run env SE_SMITHERS_DIR="$dir" "$se_bin" show|approve run-1`.
- Skips: `command -v sqlite3 || skip "sqlite3 is required"` (7), `command -v jq || skip "jq is required"` (6); `se blocks` test skips unless `$smithers_dir/node_modules/.bin/smithers` is executable (`skip "smithers deps not installed (run bun install in $smithers_dir)"`).
- `sqlite3` UPDATE statements mid-test; `pid:$$:abc` live-owner fixture uses the test shell's own pid.

### G12 — settings modifiers & themes (tests 244–250, lines 6256–6383)
- `run env PATH=... HOME=/stub/home bash "$modifier" <<< json`; op stub in `$BATS_TEST_TMPDIR`; control test uses `PATH="$PATH_WITHOUT_OP"`.
- `run jq -e '...' <<< "$output"` — chained `run` consuming the previous `$output`.
- Theme tests: plain `run jq -e ... file`.

### G13 — morning-cleanup (tests 251–254, lines 6389–6437)
- Fake `HOME="$BATS_TEST_TMPDIR/mc-*"`; `MORNING_CLEANUP_NO_NOTIFY=1`; `touch -t 202001010000`; bare `[ -d / -f / ! -d ]` assertions.

### Cross-cutting Bats feature summary
- `run`: used pervasively (~all tests). **No `run -N` status-flag form and no `run !` anywhere**; exact status is asserted with bats-assert `assert_failure <code>` (codes used: 1, 2, 97 via `assert_failure 97`, 124) and `assert_success`.
- `$output` — everywhere; `$lines` — G5 (`assert_line --index $(( ${#lines[@]} - 1 ))`); `$status` — only implicitly via assert_success/failure. **No `$stderr` / `--separate-stderr`** — stdout+stderr are merged by `run`, and several assertions rely on that merge (e.g. "read failed" from stub stderr appearing in `$output`).
- bats-assert: `assert_success`, `assert_failure [n]`, `assert_output` (exact, empty-string, `--partial`), `refute_output [--partial]`, `assert_line` (exact, `--partial`, `--index`), `assert_equal`, `fail`.
- bats-file: `assert_file_exists`, `assert_file_not_exists`, `assert_file_contains` (regex), `assert_dir_exists`, `assert_dir_not_exists`, `assert_file_permission 700` (one site, line 942).
- Bats variables: `BATS_TEST_TMPDIR` (28 sites), `BATS_TEST_DIRNAME` (probe files, helper path, repo root), `BATS_TEST_FILENAME` (self-recursive bats run, line 2747), `BATS_TEST_NUMBER` (line 5527), FD 3 console write (line 2721), custom global `BATS_TEST_TMPFILE` bridging test → teardown.
- `skip`: 116 sites; full message census: `jq not available` ×96, `sqlite3 is required` ×7, `jq is required` ×6, `bun not available` ×2, `smithers deps not installed (run bun install in $smithers_dir)` ×1, `repo-root Makefile is not available in this environment` ×1, `perl not available` ×1, `herdr-integrations script not found` ×1, `Only relevant on Linux` ×1, plus parameterless skips inside common.bash helpers (`chezmoi not installed`, disposable-home long message).
- setup/teardown: per-test `setup()`/`teardown()` only. **No `setup_file`/`teardown_file`.**
- Ordering dependencies between tests: none — every test builds its own fixtures. The only ordering-ish coupling is test 1 running first *by position* so a missing python3 names itself before later bare `python3` calls fail (comment at line 43); Bats runs file order, `--jobs` may reorder — the file tolerates that.
- Serialization requirements: mostly none (fixtures are per-test mktemp/BATS_TEST_TMPDIR). Exceptions listed under hazards: fixed `/tmp/htspwn$N` path, host-chezmoi-reading tests, self-recursive bats, real daemons/watchers, `HTS_*`/`HERDR_CHILD_*` exported env leaking within one worker process.

## 3. File-level setup/teardown, verbatim

There is no `setup_file`/`teardown_file`. The file-level hooks are:

```bash
setup() {
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_PARENT_PANE
  unset HERDR_CHILD_STATE_DIR
  unset HERDR_WORKSPACE_ID
  unset HERDR_CHILD_MAX_DELIVERY_RETRIES
  unset HERDR_CHILD_TEST_RETRY_LOG
  unset HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER
  unset HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER
}

teardown() {
  hts_teardown
  if [[ -n "${CHILD_STUB:-}" ]]; then
    [[ ! -e "$CHILD_STUB/release-watcher" ]] || true
    : > "$CHILD_STUB/release-watcher" 2>/dev/null || true
    if [[ -s "$CHILD_STUB/watcher.pid" ]]; then
      local watcher_pid
      watcher_pid="$(cat "$CHILD_STUB/watcher.pid" 2>/dev/null || true)"
      if [[ -n "$watcher_pid" ]]; then
        kill -TERM "$watcher_pid" 2>/dev/null || true
        local attempt=0
        while kill -0 "$watcher_pid" 2>/dev/null && [[ "$attempt" -lt 100 ]]; do
          attempt=$((attempt + 1))
          sleep 0.01
        done
      fi
    fi
  fi
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
}
```

Also load-time (file top-level, executed once per Bats process — effectively per test under Bats' per-test re-source model):

```bash
load 'helpers/common'
load 'helpers/herdr_task_sync'
```

plus top-level constants evaluated at source time: `ASK_HERDR_DIR`, `HERDR_CHILD`, `HERDR_INTEGRATIONS_TMPL`, `HOOKS_DIR`, `FFF_GUARD`, `WEBFETCH_HINT`, `HTS_HOOK` (all derived from `$SOURCE_ROOT`), and helper function definitions (`render_install_packages`, `ask_live_stub`, `child_stub_herdr`, `child_lifecycle_stub_herdr`, `child_start`, `child_lifecycle_start`, `child_wait_for_*`, `hts_hook_setup`, `hts_hook_run`, `se_fake_runtime`).

## 4. Migration hazards

Constructs with no direct bashunit equivalent, or whose semantics change under parallel execution:

1. **Self-recursive Bats run** (line 2747): `run bats "$BATS_TEST_FILENAME" --filter '^herdr-task-sync bounded Bats invocation exits after detached work$'` and the nested `bats --count` / `bats <probe>.bats` runs (lines 2419, 2439). These tests *are about Bats behavior* (descriptor inheritance through the Bats formatter pipeline, `ok 1` TAP output, per-test-file counting). Translating the runner to bashunit changes the property under test; the filtered self-invocation must be rewritten to target the bashunit file/filter syntax, and the vacuity-guard pair (tests 75+76) must be re-validated red/green after porting.
2. **Mid-test `teardown; setup` re-invocation** (10+ sites in G6): Bats hooks are plain functions so tests call them to reset stubs between phases. bashunit's `set_up`/`tear_down` are also callable, but the file's `teardown` depends on Bats globals (`BATS_TEST_TMPFILE`) and `hts_teardown` state; the reset must be factored into an explicit `reset_child_stub`-style function or each multi-phase test split.
3. **`run` semantics cluster**: merged stdout+stderr in `$output` (asserted-on in several tests), `$lines` indexing (`assert_line --index $(( ${#lines[@]} - 1 ))`), exact-status `assert_failure 2|1|97|124`, heredoc stdin into `run`, env-prefix forms (`FOO=1 run cmd` and `run env FOO=1 cmd`), and chained `run jq -e <<< "$output"` consuming the prior run's output. bashunit's capture API differs (separate stdout/stderr, no `$lines`); every last-line and merged-stream assertion needs an explicit re-encoding.
4. **bats-assert/bats-file vocabulary** (~964 assertion calls): `assert_output --partial`, `refute_output`, `assert_line [--partial|--index]`, `assert_file_contains <file> <regex>` (regex, not substring), `assert_file_permission 700`, `assert_dir_[not_]exists`, `fail`. bashunit lacks one-for-one equivalents for `assert_line --index`, `assert_file_contains`-as-regex, and `assert_file_permission`; shims are required, and `fail` inside helper functions (common.bash `assert_python3_available`, `require_disposable_home`) returns rather than aborts — the helpers' documented return-explicitly discipline must survive the port.
5. **`skip` semantics**: 116 conditional skips (jq/sqlite3/bun/perl/chezmoi/OS). Bats `skip` aborts the test and exits 0; a bashunit equivalent must preserve "green but not counted as coverage" reporting, and the repo's convention (docs/issues/2026-08-20-013) distinguishes skip-worthy missing tools from assert-worthy misconfiguration — that split lives in common.bash and must be kept callable.
6. **Background processes, daemons, and traps**: real detached watcher processes with pid files, sweep daemons under `sweep.lock/pid`, `&`-launched engine/worker/presentation jobs with `wait`, stub-internal `trap 'exit 143' HUP INT TERM` blocking loops, python3 drivers sending SIGTERM/HUP/INT (one explicitly resets SIGINT disposition because *parallel Bats workers ignore SIGINT* — the equivalent assumption must be re-checked under bashunit's runner). Any runner change alters process-group/signal inheritance; the teardown kill-and-poll loop is the only thing preventing orphaned watchers, and it must run even on assertion failure (Bats guarantees teardown; bashunit's tear_down must be verified to run after failures).
7. **Parallel-execution state**: fixed-path fixture `/tmp/htspwn$BATS_TEST_NUMBER` (line 5527) relies on `BATS_TEST_NUMBER` for cross-job uniqueness — bashunit has no such variable; `/tmp/chezmoi-test.yaml` (`CHEZMOI_TEST_CONFIG` in common.bash) is a single shared path; exported per-test env (`HTS_*`, `HERDR_CHILD_*`, `HERDR_TASK_SYNC_TEST_*`) leaks across tests within one worker process and is only cleaned by the `setup()` unset list and scattered in-test `unset`s — a runner that shares one shell across tests widens the blast radius.
8. **Host-environment reads (not parallel-safe, not hermetic)**: test 8 (`chezmoi managed`) reads the host's live chezmoi source; G3/G7/G8-settings render against `$SOURCE_ROOT` and the host chezmoi binary with `PATH_WITHOUT_OP`; `se blocks` runs a real installed smithers. These serialize against anything mutating the chezmoi source and fail on machines without the deployment.
9. **FD 3 console write** (line 2721): `printf ... >&3` is a Bats-specific "console" descriptor for surfacing a measurement on passing runs. bashunit has no FD-3 contract; the recalibration output channel needs a replacement (stderr or a file).
10. **Timing-sensitive negative assertions**: `sleep 2`/`sleep 6` "nothing happened" checks and 500×10ms poll loops are load-sensitive; under a different runner's scheduling/parallelism these budgets (and `HTS_INNER_BATS_PROGRESS_SECONDS=60` / `EXIT_SECONDS=30`, the 30s coordinator deadline, `HTS_WAIT_POLLS`) may need recalibration.
11. **`load` resolution**: `load 'helpers/common'` relies on Bats' `.bash`-suffix resolution and on bats-libs (`load "${HELPERS_DIR}/bats-libs/bats-support/load"` inside common.bash, guarded by a submodule check). common.bash deliberately *sources* `disposable-home.bash` so it works outside Bats; the bats-libs `load` calls do not, so common.bash itself cannot be sourced by bashunit unmodified.

## 5. External commands invoked

| Command | Where | If absent |
|---|---|---|
| `python3` (≥3.9) | test 1; G6 signal drivers (5 tests); settings-template test 73; hts fail-open pty test; adapter-timeout driver; descriptor-bound tests 75–76 | **Hard fail** by design (declared repo requirement; no skip) — tests 1, 75, 76 and every python3-driver test error out |
| `chezmoi` (`$CHEZMOI_BIN`) | G3 (4 tests), test 8, G7, test 73 | Skipped via `skip_if_no_chezmoi`; test 8 also OS-gated |
| `jq` | ~96 hts/hook tests, 6 se tests, modifier/theme tests, fff-guard tests | Skipped (`jq not available` / `jq is required`); *theme tests 249–250 and modifier tests 244–245 call jq without a guard → would hard-fail* |
| `bats` (nested) | tests 74–76 | Hard fail (`command -v bats` result executed unchecked) |
| `sqlite3` | se show/approve tests 233–239 | Skipped (`sqlite3 is required`) |
| `bun` | adapter tests at lines 3385, 3478; (indirectly) `se blocks` deps | Skipped (`bun not available`; `smithers deps not installed`) |
| `perl` | no-op location mtime test (line 4402) | Skipped |
| `make` + repo Makefile | test 2 | Skipped if Makefile missing; hard fail if `make` itself absent |
| `git`-shaped fixtures | hts location tests use *stubbed* git via `hts_git_*fixture` — real git not required | n/a |
| `ps` | G5 name-collision stub, hts owner-claim tests (`-o ppid=`, `-o pgid=`, `-o lstart=`) | Hard fail (POSIX-standard, assumed present) |
| `mktemp`, `sed`, `awk`, `grep`, `find`, `base64`, `mkfifo`, `ln`, `touch`, `sqlite3`-heredoc, `tr`, `cut`, `wc`, `sort`, `uniq`-free | throughout | Assumed present (coreutils/BSD userland) |
| `shellcheck` | test 2 stubs it — real binary not needed | n/a |
| `op` (1Password) | must be **absent** from effective PATH (`PATH_WITHOUT_OP`); modifier test provides its own stub | Presence handled by common.bash PATH filtering |
| `smithers` (installed) | `se blocks --json` (line 6235) | Skipped |
| `bash` | every script under test is invoked as `bash <script>` | Hard requirement (macOS 3.2-compatible sites exist in helpers) |

Notes:
- The engine under test (`herdr-task-sync`, `herdr-child`, `ask.sh`, hooks, `se`, modifiers, `morning-cleanup`) is always exercised from `$SOURCE_ROOT` (the repo's `home/` tree), never from the deployed `~/` copies.
- `herdr` itself is never required: every test that needs it fabricates a stub on PATH.
