kind: review
title: backup script with two planted bugs
context: files/backup.sh
# Unquoted $SRC breaks on spaces, and with no .log files cp gets the literal glob under set -e.
bug: B1 files/backup.sh:13
# head after an ascending sort selects the oldest KEEP backups and deletes them, keeping the rest.
bug: B2 files/backup.sh:18-19
tolerance: 1
---
Review this Bash script for bugs. Ignore style and portability to other shells.
