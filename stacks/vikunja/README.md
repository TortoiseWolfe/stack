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

The image defaults to uid 1000 and cannot chown its volume. Docker creates the named
volume `vikunja_files` root-owned, and on 2.8.0 the app then exits at start with
"permission denied" (reproduced in a test swarm), so the `app` service sets
`user: "0:0"`. The image has no shell, so there is no way to fix the owner from inside
it. If William would rather not run it as root, the volume's owner has to be set to
1000 on the host first.

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

## Healthcheck on `app`

The upstream image has no shell, `curl` or `wget`, so the check runs the binary's own
`vikunja healthcheck` command. After a deploy, `https://<VIKUNJA_DOMAIN>/api/v1/info`
should answer.
