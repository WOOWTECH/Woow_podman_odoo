# tests/fixtures

`*.env` files are per-host variants of `config/odoo18.env.example` that `tests/dryrun.sh` renders and
checks (moved port and custom addons dir, and all interfaces with the database manager hidden).

Backup archives, including the malicious ones, are generated in temporary directories by
`tests/test_backup_validator.py`; no binary or unsafe fixture is tracked.
