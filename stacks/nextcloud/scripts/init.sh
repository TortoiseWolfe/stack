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

# Audit logging that actually records something.
#
# `admin_audit` was enabled on production from 2026-08-20 and its log file was ZERO BYTES
# on 2026-09-01, having never been written to. Enabling the app is not enough, and the
# combination that makes it silent is not obvious:
#
#   Actions/Action.php calls $logger->info(). Log.php falls back to
#   getValue('loglevel', ILogger::WARN), and INFO (1) is below WARN (2), so every audit
#   entry is discarded before it reaches the file.
#
# So the app reports enabled, the file exists, and nothing is ever recorded. That is worse
# than having no audit log, because it reads as coverage. It cost us the answer to "who
# created these accounts" on 2026-09-01, which had to be reconstructed from git history.
#
# `log.condition.matches` lowers the threshold for ONE app rather than globally: Action.php
# passes ['app' => 'admin_audit'] as context and Log.php matches on exactly that key, so
# the rest of the instance stays at WARN and nextcloud.log does not fill with INFO noise.
#
# Rotation needs no setting: admin_audit's own Rotate job defaults log_rotate_size to 100MB.
occ config:system:set log_type_audit --value=file >/dev/null
occ config:system:set logfile_audit --value=/var/www/html/data/audit.log >/dev/null
occ config:system:set log.condition matches 0 apps 0 --value=admin_audit >/dev/null
occ config:system:set log.condition matches 0 loglevel --value=1 --type=integer >/dev/null

# Nextcloud drops a sample contact ("Leon Green, Manager at Company") and a sample event
# into every NEW account. Fine for a demo, noise on a co-op instance where the first thing
# a member sees should be their own data. Existing accounts keep whatever they already have;
# this only stops it being created again.
occ config:app:set dav createExampleContact --value=no >/dev/null
occ config:app:set dav createExampleEvent --value=no >/dev/null

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

  # Call recording, and the transcript that is the point of it.
  #
  # Talk turns a finished recording into a transcript BY ITSELF once any
  # transcription provider is registered -- see RecordingService, which reads
  # call_recording_transcription === 'yes'. So there is no transcription logic
  # here: make the two backends reachable, register the provider, set the flag.
  #
  # isRecordingEnabled() also wants signaling mode != internal, which the block
  # above has just satisfied.
  if [ "${RECORDING_ENABLED:-true}" = true ] && [ -n "$RECORDING_SECRET" ]; then
    occ config:app:set spreed recording_servers --value \
      "{\"servers\":[{\"server\":\"${RECORDING_URL:-http://talk-recording:1234}\",\"verify\":false}],\"secret\":\"$RECORDING_SECRET\"}" >/dev/null
    occ config:app:set spreed call_recording --value yes >/dev/null
    occ config:app:set spreed call_recording_transcription --value yes >/dev/null
    log "talk: recording ${RECORDING_URL:-http://talk-recording:1234}, auto-transcribe on"

    # The speech-to-text provider, registered through a manual-install daemon.
    # NOT docker-install: that hands a container the Docker socket on a host that
    # is not ours, and AppAPI's own help calls it deprecated and scheduled for
    # removal in Nextcloud 35.
    #
    # Any docker-install daemon here is debris -- one was registered by hand on
    # production 2026-08-29 pointing at a container that never existed, which
    # logged an error on every admin visit to /settings/apps and would have made
    # this registration fail for an unrelated reason.
    # OUTSIDE the STT_SECRET guard on purpose. Nested inside it, this never ran
    # once stt_whisper2 defaulted to 0 replicas, so the stale daemon survived a
    # deploy that was supposed to remove it (measured on production 2026-08-30).
    for d in $(occ app_api:daemon:list 2>/dev/null | awk -F'|' '$5 ~ /docker-install/ {gsub(/ /,"",$3); print $3}'); do
      occ app_api:daemon:unregister "$d" >/dev/null 2>&1 \
        && log "removed stale docker-install daemon '$d'" || true
    done

    if [ -n "$STT_SECRET" ]; then
      if ! occ app_api:daemon:list 2>/dev/null | grep -q manual_install; then
        occ app_api:daemon:register manual_install "Manual Install" manual-install \
          http "${STT_HOST:-stt-whisper2}:${STT_PORT:-9030}" "https://$DOMAIN" >/dev/null \
          && log "registered manual_install deploy daemon"
      fi
      if occ app_api:app:list 2>/dev/null | grep -q stt_whisper2; then
        log "stt_whisper2 already registered"
      else
        # Not unregister-then-register: that would drop the downloaded models.
        occ app_api:app:register stt_whisper2 manual_install --json-info \
          "{\"id\":\"stt_whisper2\",\"name\":\"Local Whisper Speech To Text\",\"daemon_config_name\":\"manual_install\",\"version\":\"${STT_VERSION:-2.5.0}\",\"secret\":\"$STT_SECRET\",\"host\":\"${STT_HOST:-stt-whisper2}\",\"port\":${STT_PORT:-9030},\"scopes\":[\"AI_PROVIDERS\"],\"system\":true}" \
          --wait-finish >/dev/null 2>&1 \
          && log "registered stt_whisper2 speech-to-text provider" \
          || log "WARN stt_whisper2 registration failed -- is it up on ${STT_HOST:-stt-whisper2}:${STT_PORT:-9030}?"
      fi
      occ app:enable stt_whisper2 >/dev/null 2>&1 || true
    fi

    # LocalAI (whisper.cpp) as the transcription provider, reached through
    # integration_openai. Measured on staging 2026-08-29 against one 8.33s
    # sample, same node, same 2-core cap:
    #
    #   stt_whisper2 large-v3        460.8s  55x real time  OOM-killed at 5G
    #   stt_whisper2 large-v3-turbo  233.9s  28x
    #   LocalAI small-en-q5_1        261.3s  31x
    #   LocalAI base-en-q5_1          64.3s  7.7x
    #
    # At MATCHED accuracy the two engines are within ~10% of each other, so this
    # is not a speed win. It is a footprint win: 0.3 GB image and ~0.2 GB idle,
    # against 16.3 GB of CUDA libraries and a 3.87 GB peak on a host with no GPU.
    # Both stay registered; the preference below is one config value, so swapping
    # engines is a config change rather than a redeploy.
    if [ "${LOCALAI_ENABLED:-true}" = true ]; then
      # `|| true` is load-bearing under `set -eu`: app:install is NOT idempotent
      # and errors when the app is already present, which aborted the whole
      # script on production 2026-08-30 -- silently, because the failure was
      # redirected to /dev/null. Same guard the app loop above uses.
      occ app:install integration_openai >/dev/null 2>&1 || true
      occ app:enable integration_openai >/dev/null 2>&1 || true
      occ config:app:set integration_openai url --value="${LOCALAI_URL:-http://localai:8080/v1}" >/dev/null
      # Point STT at the prompt-injecting proxy, not LocalAI directly. Without
      # the prompt, base-en garbled the co-op's own name on three runs of four.
      occ config:app:set integration_openai stt_url --value="${LOCALAI_STT_URL:-http://stt-proxy:9040/v1}" >/dev/null
      occ config:app:set integration_openai default_stt_model_id --value="${LOCALAI_STT_MODEL:-whisper-base-en-q5_1}" >/dev/null
      occ config:app:set integration_openai stt_provider_enabled --value=1 >/dev/null
      occ config:app:set integration_openai service_name --value="LocalAI (self-hosted)" >/dev/null
      log "transcription provider: LocalAI ${LOCALAI_STT_MODEL:-whisper-base-en-q5_1} at ${LOCALAI_URL:-http://localai:8080/v1}"

      # Without an explicit preference Nextcloud picks the first registered
      # provider, which was stt_whisper2's LARGEST model AND its "enhanced"
      # variant -- the slowest possible pairing, and the enhanced one 412s on
      # every run because it wants a text-generation provider we do not run.
      occ config:app:set core ai.taskprocessing_provider_preferences \
        --value='{"core:audio2text":"integration_openai-audio2text"}' >/dev/null
      log "audio2text preference pinned to integration_openai-audio2text"

      # Install the model INTO LocalAI. Without this Nextcloud is pointed at a
      # model that does not exist, which looks configured and fails on first
      # use. Idempotent: LocalAI no-ops if it is already present.
      _lm=${LOCALAI_STT_MODEL:-whisper-base-en-q5_1}
      _lb=$(printf '%s' "${LOCALAI_URL:-http://localai:8080/v1}" | sed 's#/v1$##')
      if curl -sf -m 20 "$_lb/v1/models" 2>/dev/null | grep -q "$_lm"; then
        log "LocalAI model $_lm already installed"
      elif curl -sf -m 30 -X POST "$_lb/models/apply" \
             -H 'Content-Type: application/json' -d "{\"id\":\"$_lm\"}" >/dev/null 2>&1; then
        log "LocalAI model $_lm install requested (downloads in the background)"
      else
        log "WARN could not reach LocalAI at $_lb to install $_lm"
      fi
    fi
  fi

  # recording_consent is deliberately NOT set. Whether members are asked before
  # being recorded is the co-op's decision, not a default to pick for them.
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
