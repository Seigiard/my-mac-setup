## Read in full, side by side

The diff touches test doubles (helpers, fakes, stubs), or tests that drive one. For each, read the double and what it stands for in full, side by side:

- the generated `herdr` stand-in and the model stub in `tests/helpers/herdr_task_sync.bash`, which stand for the installed `herdr` CLI (`herdr pane report-metadata --help`, `herdr pane --help`) and the model command; side by side with their caller `home/dot_local/bin/executable_herdr-task-sync`.
