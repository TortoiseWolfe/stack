<?php
/**
 * Delete a Talk recording once its transcript exists.
 *
 * WHY. The video is an input, not the artifact. Transcription already converts it
 * to audio -- stt-prompt-proxy.py transcodes webm to 16 kHz mono with ffmpeg's -vn
 * -- and then discards that audio, while the video is kept forever. Measured on
 * production 2026-09-08: one hour of meeting is a 278 MB webm against a 43 kB
 * transcript, and the 2026-09-01 recording was still there a week later because
 * nothing in this stack has ever deleted one.
 *
 * Greg asked for exactly this on 2026-09-03: "The transcripts are helpful but I
 * don't think we need to keep videos." He also said he wants webinar recordings
 * kept, which is what KEEP_ROOMS is for.
 *
 * SAFE BY DEFAULT, TWICE OVER. This does nothing unless RECORDING_PRUNE=1 *and*
 * --apply is passed. Shipping it switched off is deliberate: it deletes a member's
 * file, so turning it on should be a decision someone makes, not a side effect of
 * deploying.
 *
 * WHAT PROTECTS A RECORDING. In order of how likely each is to matter:
 *
 *   1. A transcript must exist beside it, matching on basename.
 *   2. That transcript must be at least TRANSCRIPT_MIN_BYTES. This is not
 *      paranoia: production currently holds transcripts of 47 and 66 bytes from
 *      failed and test runs. "A transcript exists" would have deleted a real
 *      recording on the strength of one of those. A real hour produced 43 kB.
 *   3. Both files must be older than MIN_AGE, so a transcript still being written
 *      cannot be mistaken for a finished one.
 *   4. The room may not be in KEEP_ROOMS -- webinars, per Greg.
 *   5. Only files under <attachment folder>/Recording/<token>/ where <token> is a
 *      live room, exactly the scope share-recordings.php uses.
 *
 * A recording whose transcription FAILED is therefore never touched, which is the
 * failure that would otherwise be silent data loss.
 *
 * Usage: php prune-recordings.php [--apply]      (default is a dry run)
 */
require_once '/var/www/html/lib/base.php';

\OC_App::loadApp('spreed');

$apply = in_array('--apply', $argv, true);

// Off switch, and the default. Same shape as RECORDING_AUTOSHARE so there is one
// way to stop these jobs without editing a script inside a running container.
if (getenv('RECORDING_PRUNE') !== '1') {
    echo "RECORDING_PRUNE is not 1, doing nothing\n";
    exit(0);
}

// Not `?: default` anywhere below -- "0" is falsy, and an explicit zero must mean
// zero rather than silently becoming the default. Same bug share-recordings.php
// documents at its own STT_SHARE_MIN_AGE.
function envInt(string $name, int $default): int {
    $v = getenv($name);
    return ($v === false || $v === '') ? $default : (int)$v;
}

// An hour of real meeting produced 44,074 characters. 2 kB is far below anything
// genuine and far above the 47- and 66-byte failures seen on production.
$minTranscript = envInt('TRANSCRIPT_MIN_BYTES', 2048);

// A recording is only considered once both it and its transcript have been still
// for this long. Transcription of a one-hour call takes about 7 minutes, so the
// default is deliberately well past that.
$minAge = envInt('RECORDING_PRUNE_MIN_AGE', 86400);

$keepRooms = array_filter(array_map('trim', explode(',', (string)getenv('RECORDING_KEEP_ROOMS'))));

// Extensions treated as the disposable input. Everything else in the folder --
// transcripts, notes, anything a member puts there -- is out of scope by omission.
$videoExt = ['webm', 'mp4', 'mkv', 'ogv'];

$um  = \OC::$server->get(\OCP\IUserManager::class);
$rf  = \OC::$server->get(\OCP\Files\IRootFolder::class);
$log = \OC::$server->get(\Psr\Log\LoggerInterface::class);
$roomManager = \OC::$server->get(\OCA\Talk\Manager::class);

echo $apply ? "APPLY mode\n" : "DRY RUN (pass --apply to act)\n";
printf("  min transcript %d B | min age %d s | keep rooms: %s\n",
    $minTranscript, $minAge, $keepRooms ? implode(',', $keepRooms) : '(none)');

$now = time();
$deleted = 0; $freed = 0; $kept = 0; $examined = 0; $failed = 0;

$um->callForSeenUsers(function (\OCP\IUser $user) use (
    $rf, $roomManager, $log, $apply, $minAge, $minTranscript, $keepRooms, $videoExt, $now,
    &$deleted, &$freed, &$kept, &$examined, &$failed
) {
    $uid = $user->getUID();
    try { $userFolder = $rf->getUserFolder($uid); }
    catch (\Throwable $e) { return; }

    foreach (['Talk/Recording', 'Talk Recording'] as $base) {
        try { $recRoot = $userFolder->get($base); }
        catch (\Throwable $e) { continue; }
        if (!$recRoot instanceof \OCP\Files\Folder) { continue; }

        foreach ($recRoot->getDirectoryListing() as $roomFolder) {
            if (!$roomFolder instanceof \OCP\Files\Folder) { continue; }
            $token = $roomFolder->getName();

            // The room list is the authority on what a valid recording folder is.
            try { $room = $roomManager->getRoomByToken($token); }
            catch (\Throwable $e) { echo "  skip: '$token' is not a live room\n"; continue; }

            if (in_array($token, $keepRooms, true)) {
                echo "  keep: $token is in RECORDING_KEEP_ROOMS\n";
                continue;
            }

            // Index the folder once: basename -> transcript size.
            $transcripts = [];
            foreach ($roomFolder->getDirectoryListing() as $n) {
                if (!$n instanceof \OCP\Files\File) { continue; }
                if (strtolower(pathinfo($n->getName(), PATHINFO_EXTENSION)) !== 'md') { continue; }
                // "Recording 2026-09-01 16-17-02.md" pairs with the .webm of the
                // same basename. Versions and trash copies carry suffixes like
                // .v1788304599 and must not count as a transcript.
                $transcripts[pathinfo($n->getName(), PATHINFO_FILENAME)] = $n->getSize();
            }

            foreach ($roomFolder->getDirectoryListing() as $node) {
                if (!$node instanceof \OCP\Files\File) { continue; }
                $name = $node->getName();
                if (!in_array(strtolower(pathinfo($name, PATHINFO_EXTENSION)), $videoExt, true)) { continue; }
                $examined++;

                $stem = pathinfo($name, PATHINFO_FILENAME);
                $age  = $now - $node->getMTime();

                if ($age < $minAge) {
                    printf("  keep: %s (%ds old, < %ds)\n", $name, $age, $minAge);
                    $kept++; continue;
                }
                if (!isset($transcripts[$stem])) {
                    printf("  KEEP: %s has NO transcript -- transcription may have failed\n", $name);
                    $kept++; continue;
                }
                if ($transcripts[$stem] < $minTranscript) {
                    printf("  KEEP: %s transcript is only %d B (< %d) -- treating as failed\n",
                        $name, $transcripts[$stem], $minTranscript);
                    $kept++; continue;
                }

                printf("  %s %s (%d B, transcript %d B) in %s\n",
                    $apply ? 'DELETE' : 'would delete',
                    $name, $node->getSize(), $transcripts[$stem], $room->getName() ?: $token);

                if (!$apply) { continue; }

                $size = $node->getSize();
                try {
                    // Goes to the owner's trash, not straight out. Nextcloud's own
                    // retention empties it later, which leaves a window to undo a
                    // mistake this script cannot foresee.
                    $node->delete();
                    $deleted++; $freed += $size;
                    $log->info('prune-recordings: deleted ' . $name . ' in ' . $token
                        . ' (transcript ' . $transcripts[$stem] . ' B)', ['app' => 'prune-recordings']);
                } catch (\Throwable $e) {
                    $failed++;
                    echo '    FAILED: ' . get_class($e) . ' ' . $e->getMessage() . "\n";
                    $log->error('prune-recordings: could not delete ' . $name . ' in ' . $token,
                        ['exception' => $e, 'app' => 'prune-recordings']);
                }
            }
        }
    }
});

printf("  examined=%d deleted=%d kept=%d failed=%d freed=%s\n",
    $examined, $deleted, $kept, $failed,
    $freed > 1048576 ? round($freed / 1048576) . ' MB' : $freed . ' B');

exit($failed > 0 ? 1 : 0);
