# odoo-shadow

Production-masked Odoo dev environments on AWS: masks PII from a source Odoo DB, bakes a provenance-tagged Odoo image, and launches isolated Coder workspaces seeded from the masked dump.

## Install

```bash
bash deploy/00_setup.sh
```

Interactive wizard: installs prerequisites (AWS CLI v2, python3, Coder CLI), sets up AWS auth, and writes `config.yaml`. Use this only if the AWS stack is already deployed — it does not provision infrastructure. To stand up the stack itself, run `bash deploy/run_all.sh` instead (provisions ECR, Coder server, and publishes templates).

## Usage

```bash
./cli/odooshadow profile list
./cli/odooshadow run mask
./cli/odooshadow workspace --help
```

See `./cli/odooshadow --help` for the full command surface (profiles, mask/build runs, Coder workspaces).

## Contributing

Issues and PRs are welcome. For significant changes, please open an issue first to discuss what you'd like to change. See [CONTRIBUTING.md](CONTRIBUTING.md) — note this repo routinely handles production dumps and cloud credentials, so run a secret scanner before your first commit in a new clone.

## Reporting Issues

Found a bug or have a feature request? [Open an issue](../../issues/new) with steps to reproduce (or the use case, for feature requests). For security issues, see [SECURITY.md](SECURITY.md).

## License

Apache-2.0 © Sthala
