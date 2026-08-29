#!/bin/sh
# Provisioning for a Nextcloud stack deploy. Runs as www-data so nothing it
# writes is unreadable by the server that has to serve it.
set -eu

log() { printf '[init] %s\n' "$*"; }
die() { printf '[init] %s\n' "$*" >&2; exit 1; }

cd /var/www/html
occ() { php occ "$@"; }

TALK_ENABLED="${TALK_ENABLED:-true}"
SMTP_HOST="${SMTP_HOST:-smtp.resend.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-resend}"
MAIL_FROM="${MAIL_FROM:-no-reply}"
TURN_PORT="${TURN_PORT:-3478}"
ADMIN_ACCOUNTS="${ADMIN_ACCOUNTS:-}"
MEMBER_ACCOUNTS="${MEMBER_ACCOUNTS:-}"
EXTRA_APPS="${EXTRA_APPS:-}"
case "$TALK_ENABLED" in true|false) ;; *) die "TALK_ENABLED must be true or false" ;; esac

# Nextcloud builds the sender as <from>@<domain>, so a full address here yields
# no-reply@x@x and every message is silently dropped.
case "$MAIL_FROM" in *@*) die "MAIL_FROM is the local part only, got '$MAIL_FROM'" ;; esac

[ "$ADMIN_USER" != admin ] || die "ADMIN_USER must not be the built-in 'admin'"

if [ "$TALK_ENABLED" = true ]; then
  printf '%s' "$TURN_HOST" | grep -Eq '^[A-Za-z0-9.-]+$' || die "TURN_HOST must be a hostname, got '$TURN_HOST'"
  printf '%s' "$TURN_SECRET" | grep -Eq '^[A-Za-z0-9]+$' || die "TURN_SECRET must be alphanumeric"
fi

# Object storage is optional; a partial set is not. Nextcloud reads
# OBJECTSTORE_S3_* only at first install, so whatever it picks is permanent for
# the instance and an incomplete set installs to a local volume without error.
S3_BUCKET="${S3_BUCKET:-}"
if [ -n "$S3_BUCKET" ]; then
  [ -n "${S3_HOST:-}" ]   || die "S3_BUCKET is set but S3_HOST is not"
  [ -n "${S3_KEY:-}" ]    || die "S3_BUCKET is set but S3_KEY is not"
  [ -n "${S3_SECRET:-}" ] || die "S3_BUCKET is set but S3_SECRET is not"
fi

# Swarm ignores depends_on, so the app container may still be installing.
log "waiting for Nextcloud to finish installing"
i=0
until occ status 2>/dev/null | grep -q "installed: true"; do
  i=$((i + 1))
  [ "$i" -le 90 ] || die "Nextcloud never reported installed after 15 minutes"
  sleep 10
done

# Report what the install actually chose, not what was asked for. Passing the
# variables is not proof they took, and this is the last moment the difference is
# cheap to fix.
if occ config:system:get objectstore >/dev/null 2>&1; then
  if [ -z "$S3_BUCKET" ]; then
    die "instance installed on object storage but S3_BUCKET is unset; the environment does not match the instance"
  fi
  # Which bucket, not just whether there is one. This cluster hosts both
  # `nextcloud` and `nextcloud-cd`; a presence check calls the wrong one healthy.
  got="$(occ config:system:get objectstore arguments bucket 2>/dev/null || true)"
  [ "$got" = "$S3_BUCKET" ] || die "S3_BUCKET=$S3_BUCKET was requested but the instance installed against bucket '${got:-unknown}'"
  log "primary storage: object store, bucket $S3_BUCKET"
elif [ -n "$S3_BUCKET" ]; then
  die "S3_BUCKET=$S3_BUCKET was requested but the instance installed on a local volume; rebuild from empty volumes"
else
  log "primary storage: local volume. Set S3_BUCKET/S3_HOST/S3_KEY/S3_SECRET to use object storage; honoured at first install only, so changing it later is a data migration."
fi

# The discovery prime below goes through the public hostname, so this waits on
# Traefik, DNS and the certificate as much as on Collabora.
log "waiting for Collabora discovery via https://$DOMAIN"
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/hosting/discovery")" = 200 ]; do
  i=$((i + 1))
  [ "$i" -le 60 ] || die "/hosting/discovery never answered; Office would 500 on every document open"
  sleep 10
done

log "configuring mail: $SMTP_USER@$SMTP_HOST:$SMTP_PORT, from $MAIL_FROM@$MAIL_DOMAIN"
occ config:system:set mail_smtpmode --value=smtp >/dev/null
occ config:system:set mail_smtphost --value="$SMTP_HOST" >/dev/null
occ config:system:set mail_smtpport --value="$SMTP_PORT" --type=integer >/dev/null
occ config:system:set mail_smtpsecure --value=tls >/dev/null
occ config:system:set mail_smtpauth --value=true --type=boolean >/dev/null
occ config:system:set mail_smtpname --value="$SMTP_USER" >/dev/null
occ config:system:set mail_smtppassword --value="$SMTP_PASSWORD" >/dev/null
occ config:system:set mail_from_address --value="$MAIL_FROM" >/dev/null
occ config:system:set mail_domain --value="$MAIL_DOMAIN" >/dev/null

apps="richdocuments whiteboard deck calendar contacts mail quota_warning admin_audit suspicious_login admincockpit firstrunwizard twofactor_totp twofactor_backupcodes $EXTRA_APPS"
if [ "$TALK_ENABLED" = true ]; then apps="spreed $apps"; fi
for app in $apps; do
  occ app:install "$app" >/dev/null 2>&1 || true
  occ app:enable "$app" >/dev/null || die "could not enable $app"
done
log "enabled: $apps"

# Preliminary upstream, so admins only.
occ app:enable admincockpit --groups admin >/dev/null

# Runs Collabora as PHP inside this container, which the collabora service
# replaces. Leaving both enabled costs memory and serves nothing.
occ app:disable richdocumentscode >/dev/null 2>&1 || true

occ config:app:set richdocuments wopi_url --value="https://$DOMAIN" >/dev/null
occ config:app:set richdocuments public_wopi_url --value="https://$DOMAIN" >/dev/null
occ config:app:set richdocuments disable_certificate_verification --value="" >/dev/null

# Without this the cache is only filled by a background job and every document
# open returns 500 until it runs.
php -r '
require_once "/var/www/html/lib/base.php";
OC_App::loadApp("richdocuments");
$s = OC::$server->get(OCA\Richdocuments\Service\DiscoveryService::class);
$s->resetCache();
$r = $s->fetch();
if (!simplexml_load_string($r)) { fwrite(STDERR, "discovery did not parse\n"); exit(1); }
fwrite(STDERR, sprintf("[init] discovery primed, %d bytes\n", strlen($r)));
'

occ config:app:set whiteboard collabBackendUrl --value="https://$DOMAIN/whiteboard" >/dev/null
occ config:app:set whiteboard jwt_secret_key --value="$JWT_SECRET" >/dev/null

if [ "$TALK_ENABLED" = true ]; then
  occ config:app:set spreed stun_servers --value "[\"$TURN_HOST:$TURN_PORT\"]" >/dev/null
  occ config:app:set spreed turn_servers --value \
    "[{\"schemes\":\"turn\",\"server\":\"$TURN_HOST:$TURN_PORT\",\"secret\":\"$TURN_SECRET\",\"protocols\":\"udp,tcp\"}]" >/dev/null
  occ config:app:set spreed signaling_servers --value \
    "{\"servers\":[{\"server\":\"https://$TALK_HOST\",\"verify\":true}],\"secret\":\"$SIGNALING_SECRET\"}" >/dev/null
  log "talk: relay $TURN_HOST:$TURN_PORT, signaling https://$TALK_HOST"
fi

# user:list --output=json is a uid to display-name map, so grepping it matches
# display names too. user:info keys on the uid alone.
if occ user:info "$ADMIN_USER" >/dev/null 2>&1; then
  log "admin '$ADMIN_USER' exists"
else
  OC_PASS="$ADMIN_PASSWORD" occ user:add --password-from-env --group=admin \
    --display-name="Service Admin" "$ADMIN_USER" >/dev/null
  log "created admin '$ADMIN_USER'"
fi

# uid:Display Name:email, comma separated. Empty means a rebuild comes back with
# the service account alone and every real person has to be recreated by hand.
# $1 = uid:name:email,... list   $2 = group to put them in
provision_accounts() {
  _list="$1"; _group="$2"
  [ -n "$_list" ] || return 0
  # Trailing newline matters: `read` drops a final entry with no line ending, which
  # silently skipped the last account in the list.
  printf '%s\n' "$_list" | tr ',' '\n' | while IFS=: read -r uid name email; do
    [ -n "$uid" ] || continue
    if occ user:info "$uid" >/dev/null 2>&1; then
      # Existing accounts are left alone. Re-sending the welcome mail on every
      # start mailed dormant accounts repeatedly; password reset is the recovery path.
      log "account '$uid' exists"
      continue
    fi
    pw="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)"
    OC_PASS="$pw" occ user:add --password-from-env --group="$_group" --display-name="$name" "$uid" >/dev/null
    if [ -n "${email:-}" ]; then occ user:setting "$uid" settings email "$email" >/dev/null; fi
    occ user:welcome --reset-password "$uid" >/dev/null
    log "created '$uid' in group '$_group'"
  done
}

# Members are ordinary users, NOT admins. Until now the only provisioning path put
# every account in the admin group, so adding a pilot member meant making them an
# administrator of the whole instance. That is the wrong shape for someone who is
# there to use the thing.
occ group:add members >/dev/null 2>&1 || true

provision_accounts "$ADMIN_ACCOUNTS" admin
provision_accounts "$MEMBER_ACCOUNTS" members

# NEXTCLOUD_ADMIN_USER installs as the named account, so on a fresh instance there
# is no built-in admin to disable and the command would abort the run.
if occ user:info admin >/dev/null 2>&1; then
  if occ user:info "$ADMIN_USER" >/dev/null 2>&1; then
    occ user:disable admin >/dev/null
    log "built-in 'admin' disabled"
  fi
fi

log "provisioning complete"
