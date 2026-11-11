# vikunja

[Vikunja](https://vikunja.io), a self-hosted task and project app (lists, kanban, calendar).
This stack is a staging trial of a possible companion to Nextcloud Deck, not a
decision; production gets nothing until the trial is read and approved.

## First user

Registration is off (`ENABLE_REGISTRATION` defaults to false), so the first account is
made from inside the `app` container, which has the `vikunja` binary:

```
vikunja user create -u <name> -e <email>
vikunja user set-admin <name>
```

The first command asks for the password. Turn registration on only if the trial needs
open sign-up.

## Files and permissions

The image runs as uid 1000 and will not chown its volume. The named volume
`vikunja_files` starts root-owned on first use, so if uploads fail with a permission
error, run `vikunja doctor` in the `app` container and fix the volume owner as it says.

## Upgrade

Changing `VIKUNJA_VERSION` is the whole procedure; the app migrates its database on
start. Dump the database and copy the files volume first. Trash holds deleted tasks for
30 days, so a backup is the only way back after that.

## Backup

Tasks and users are all in Postgres, attachments are in `vikunja_files`.

```
pg_dump -U vikunja vikunja
```

run inside the `db` container.

## No healthcheck on `app`

The upstream image has no shell or `wget`, so a container healthcheck cannot be
written without adding tooling. Traefik only routes once the container is up; check
`https://<VIKUNJA_DOMAIN>/api/v1/info` after a deploy.
