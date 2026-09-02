# Nextcloud

Files, Office, Whiteboard and Talk. Declarative rather than
[All-in-One](https://github.com/nextcloud/all-in-one), whose mastercontainer mounts
the Docker socket, so on a shared host anyone who can admin AIO reaches every other
tenant's containers.

Installs unattended from `ADMIN_USER` and `ADMIN_PASSWORD`, with no wizard step. The
`init` service then provisions the instance, so a deploy onto empty volumes produces
the app set, Office, Whiteboard, mail and the named admins with no hand steps.

## Routing

Three routers share `DOMAIN`, separated by priority because the app's rule matches the
whole host. Office and Whiteboard are path-routed rather than given subdomains, so
neither needs a DNS record. Talk is the exception and needs its own.

| Router | Rule | Priority | Port |
|---|---|---|---|
| `${INSTANCE_NAME}-office` | `Host(DOMAIN) && PathPrefix(/browser,/hosting,/cool)` | 100 | 9980 |
| `${INSTANCE_NAME}-board` | `Host(DOMAIN) && PathPrefix(/whiteboard)` | 100 | 3002 |
| `${INSTANCE_NAME}-app` | `Host(DOMAIN)` | 10 | 80 |
| `${INSTANCE_NAME}-talk` | `Host(TALK_HOST)` | | 8081 |

## Talk relays through the turn stack

This stack runs signaling and the HPB. Relaying belongs to [turn](../turn), which has
to be deployed and reachable first. `init` writes Nextcloud's STUN, TURN and signaling
config, so there is no `occ` step to run by hand.

`TURN_HOST`, `TURN_PORT` and `TURN_SECRET` are that stack's values and have to match it
exactly. A wrong secret still passes STUN, then fails every allocation with a 401 and
logs nothing.

The talk container ships its own eturnal, which goes unused because nothing points at
it and no port is published for it.

## Decide before the first deploy

Primary storage is the `nextcloud_html` volume. `S3_*` is honoured at first install
only, so adopting object storage later is a data migration rather than a config change.

## Recordings are shared to their conversation

Talk stores a recording under the recorder's own `<attachment folder>/Recording/<room
token>/` and notifies *them* to decide whether to publish it. Until somebody clicks
"Share to chat" the file is private to whoever pressed record — including the
transcript. For an ops meeting that is the wrong owner: the record of the meeting
belongs to the people who were in it.

The `recording-share` service closes that gap. Every couple of minutes it shares
finished recordings, read-only, to the one conversation they came from — never to a
user, never to a public link, never to another room. It calls Talk's own
`RecordingService::shareToChat()`, so the chat message is attributed to the file's
owner and rendered as a recording rather than a generic file, and the owner's pending
"share this?" notification is cleared.

Set `RECORDING_AUTOSHARE=0` to turn it off and get Talk's stock behaviour back.
