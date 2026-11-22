kind: writing
title: release note for a small feature
---
Write a release note of at most 120 words for this change in a command-line
tool called quillctl: `quillctl sync` now resumes an interrupted sync from the
last file it finished instead of starting over. It keeps its progress in a
small state file next to the config. Users on a shared network drive may want
to know that the state file is per machine.

Write for users, not developers. No headings, no bullet points.
