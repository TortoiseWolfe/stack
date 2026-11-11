# forgejo

[Forgejo](https://forgejo.org), a self-hosted git server with issues and pull requests.
This stack is a staging trial, not a decision; production gets nothing until the trial
is read and approved.

## No SSH

`FORGEJO__server__DISABLE_SSH` is true and the stack publishes no host ports, so git
works over HTTPS only (clone with a personal access token). Turning SSH on needs a host
port, which is a firewall change and William's call.

## First user

Registration is off and `INSTALL_LOCK` skips the web installer, so the first account is
made from inside the `app` container, as the `git` user:

```
forgejo admin user create --admin --username <name> --email <email> --random-password
```

It prints the generated password once. Turn registration on only if the trial needs
open sign-up.

## Config is env-driven

Every `FORGEJO__section__KEY` variable is rewritten into `app.ini` on each start, so
a setting changed in the admin UI that is also set here reverts on restart. The
secret key is read from the environment too, so it is never written to a file we track.

## Upgrade

Changing `FORGEJO_VERSION` is the whole procedure; Forgejo migrates its database on
start. Read the release notes for the major first, and take the backup below before
a major bump, since it will not run on a database a newer version has written.

## Backup

Repositories, attachments and avatars are in `forgejo_data`; users, issues and pull
requests are in Postgres.

```
pg_dump -U forgejo forgejo
```

run inside the `db` container, plus a copy of the `forgejo_data` volume.
