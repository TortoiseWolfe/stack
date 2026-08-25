# Track

[Track](https://github.com/Chattanooga-Digital/track), per-stack resource
metering across the swarm. One central service behind Traefik, and one agent on
every node.

## Two services, one stack

Upstream ships central and agent as separate stack files. Here they are one
stack so `INGEST_KEY` is a single variable read by both sides, and so the
agents reach the central as `track` on the stack's own overlay without touching
`traefik_net`.

The agent is `mode: global`: every node runs one, including nodes that join
later. `PLACEMENT_CONSTRAINT` and the memory limits are per service and only
the central is pinned.

## The docker socket

Only the agent mounts `/var/run/docker.sock`. The image runs as uid 5678, and
reads the socket through the group that owns it on the node, so `DOCKER_GID`
has to be that group's gid on every node. Agents that log permission errors
against the socket have the wrong gid.

## State

Central holds everything in SQLite plus the data-protection keys on
`track_data`, so it is pinned to one node and updates `stop-first`. The admin
password is a first-start seed; after that the account lives in the database.

S3 sources (MinIO buckets metered as stacks) are managed in the Storage UI and
stored in the database. A MinIO on another stack's overlay is not reachable
until the central also joins that network.

## Versions

Only `sha-<commit>` tags are published. `TRACK_VERSION` pins one; never
`latest`, since central and agents must run the same build and a floating tag
lets a node pull a newer agent than the central it pushes to.

## Notes

- No healthcheck. The image carries neither `curl` nor `wget`.
- `Track__NodeName` is a Swarm service template, resolved to the node's
  hostname at task creation. It is not a compose variable.
