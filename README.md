# stacks

Docker Swarm stacks for Chattanooga.Digital, deployed by Portainer from this repo.

One directory per stack under [stacks/](stacks). Each is independent: its own
Portainer stack object, its own compose path, its own git ref, its own environment,
its own image pins. Sharing a repo couples nothing about how fast they move.

| Stack | Service |
|---|---|
| [bigcapital](stacks/bigcapital) | Accounting |
| [mastodon](stacks/mastodon) | Fediverse social |
| [nextcloud](stacks/nextcloud) | Files, Talk, Office, Whiteboard, groupware |
| [track](stacks/track) | Per-stack resource metering |
| [turn](stacks/turn) | Shared TURN/STUN relay for WebRTC |

Each stack's README covers what is specific to it. Read
[docs/CONVENTIONS.md](docs/CONVENTIONS.md) before adding one, and
[docs/PORTFOLIO.md](docs/PORTFOLIO.md) for where a platform stands, including the
ones not deployed from here.

## Adding a stack

1. `stacks/<name>/` with `docker-compose.yml`, `.env.example`, `README.md`
2. `./scripts/validate.sh <name>` until it passes
3. In Portainer, add a stack from this repo with compose path
   `stacks/<name>/docker-compose.yml`, and fill the environment panel from the
   REQUIRED block of `.env.example`
4. Copy the stack's webhook URL into a repo secret named
   `PORTAINER_WEBHOOK_<NAME>`, uppercased with hyphens as underscores

## Deploys

**Turn Portainer's git polling off on every stack.** Portainer compares the commit
hash of the branch, not of your stack's subdirectory, so polling means one commit
anywhere in this repo redeploys every stack that polls it. At 30 stacks that is a
bad afternoon.

Instead, [deploy.yml](.github/workflows/deploy.yml) diffs the push, works out which
`stacks/*` directories changed, and fires only those stacks' webhooks in parallel.

To hold a stack back, point its Portainer ref at a tag or commit instead of `main`.
It then sits still no matter what lands on trunk, which is also how you gate a
staging instance ahead of prod.

`workflow_dispatch` takes a space-separated list of stack names, or `all`. Use it
to walk a cross-cutting change through one stack before the other 29.

## Validating locally

```sh
./scripts/validate.sh            # every stack
./scripts/validate.sh nextcloud  # one
```

It runs `docker compose config` against generated placeholder values, then checks
that every required variable is listed in that stack's `.env.example`. Same thing
CI runs on every PR.
