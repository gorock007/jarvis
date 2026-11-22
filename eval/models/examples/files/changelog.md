# quillctl changelog (fictional)

## 4.2.0
- `quillctl sync` retries twice on a network error.
- The default request timeout is now 30 seconds (was 10).

## 4.1.3
- Fix: `quillctl push` no longer drops the last file of a batch of 100.

## 4.1.0
- New `--dry-run` flag on `push` and `sync`.
- The `--legacy` flag prints a deprecation warning.

## 4.0.0
- The config file moves from `~/.quill` to `~/.config/quill/config.toml`.
- Python 3.9 is no longer supported.

## 3.8.2
- The `--legacy` flag was added for servers older than 2.0.

## 5.0.0 (unreleased)
- The `--legacy` flag is removed.
