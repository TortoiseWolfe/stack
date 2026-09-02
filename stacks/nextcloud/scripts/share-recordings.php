<?php
/**
 * Share finished Talk recordings into the conversation they were recorded in.
 *
 * Talk already stores a recording under <owner attachment folder>/Recording/<room
 * token>/, so it is segregated per conversation on disk. What it does NOT do is
 * publish it: it sends the person who pressed record a notification, and the file
 * stays private until they click "Share to chat". That is deliberate upstream, and
 * for a co-op ops meeting it is the wrong default -- the 2026-09-01 meeting produced
 * a recording and a transcript that only the recorder could reach, because nobody
 * knew there was a button to press.
 *
 * This presses it. Every participant of that conversation gets the recording, and
 * only that conversation does.
 *
 * It calls Talk's own RecordingService::shareToChat() rather than creating the share
 * by hand. That matters: it attributes the chat message to the file's owner instead
 * of to the CLI, tags the mime so the client renders a playable recording card
 * rather than a generic file row, and clears the owner's pending notification so
 * they are not asked to do something already done.
 *
 * Deliberately narrow:
 *   - only files under .../Recording/<token>/, and only where <token> is a live room
 *   - only to that conversation, read-only; never a user share, never a public link
 *   - skips files already shared to the room, so it is safe to run on a timer
 *   - skips files younger than STT_SHARE_MIN_AGE seconds, so it cannot publish an
 *     upload or a transcript that is still being written
 *   - never deletes, moves, or re-permissions anything
 *
 * Usage: php share-recordings.php [--apply]      (default is a dry run)
 */
require_once '/var/www/html/lib/base.php';

\OC_App::loadApp('spreed');

// Spreed's ShareCreatedEvent listener posts its OWN generic "file_shared" message
// and suppresses it only when the request route is the recording-share endpoint
// (Chat/SystemMessage/Listener.php). On CLI there is no route, so without this a
// share yields TWO chat messages: the correctly-attributed one from shareToChat(),
// and an unattributed duplicate from the listener showing actor "cli". Presenting
// the same route the real endpoint presents makes shareToChat() behave here exactly
// as it does in the web UI. If spreed ever renames that route this reverts to
// posting duplicates -- noisy, not broken. The message count was verified by hand
// against a throwaway room on 2026-09-01 (one file produced exactly one message,
// attributed to its owner); there is no automated test in this repo yet, so re-check
// it after a Talk upgrade.
$request = \OC::$server->get(\OCP\IRequest::class);
if (method_exists($request, 'setUrlParameters')) {
    $request->setUrlParameters(['_route' => 'ocs.spreed.recording.sharetochat']);
} else {
    fwrite(STDERR, "WARNING: cannot set _route, expect duplicate chat messages\n");
}

use OCP\Share\IShare;

$apply  = in_array('--apply', $argv, true);

// Off switch. This posts files into conversations, so there has to be a way to
// stop it that does not involve editing a script inside a running container.
if (getenv('RECORDING_AUTOSHARE') === '0') {
    echo "RECORDING_AUTOSHARE=0, doing nothing\n";
    exit(0);
}
$minAgeEnv = getenv('STT_SHARE_MIN_AGE');
// Not `?: 120` -- "0" is falsy, so that silently ignores an explicit zero.
$minAge = ($minAgeEnv === false || $minAgeEnv === '') ? 120 : (int)$minAgeEnv;

$sm  = \OC::$server->get(\OCP\Share\IManager::class);
$um  = \OC::$server->get(\OCP\IUserManager::class);
$rf  = \OC::$server->get(\OCP\Files\IRootFolder::class);
$log = \OC::$server->get(\Psr\Log\LoggerInterface::class);

$roomManager = \OC::$server->get(\OCA\Talk\Manager::class);
$partService = \OC::$server->get(\OCA\Talk\Service\ParticipantService::class);
$recService  = \OC::$server->get(\OCA\Talk\Service\RecordingService::class);

echo $apply ? "APPLY mode\n" : "DRY RUN (pass --apply to act)\n";

$now = time();
$shared = 0; $already = 0; $tooNew = 0; $examined = 0; $failed = 0;

$um->callForSeenUsers(function (\OCP\IUser $user) use (
    $rf, $sm, $roomManager, $partService, $recService, $log,
    $apply, $minAge, $now, &$shared, &$already, &$tooNew, &$examined, &$failed
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

            // shareToChat() reads the file out of the participant's own folder, so
            // the owner has to still be in the conversation.
            try { $participant = $partService->getParticipant($room, $uid); }
            catch (\Throwable $e) { echo "  skip: $uid is no longer in $token\n"; continue; }

            foreach ($roomFolder->getDirectoryListing() as $node) {
                if (!$node instanceof \OCP\Files\File) { continue; }
                $examined++;

                if ($now - $node->getMTime() < $minAge) {
                    echo sprintf("  wait: %s (%ds old, < %ds)\n", $node->getName(), $now - $node->getMTime(), $minAge);
                    $tooNew++;
                    continue;
                }

                $isShared = false;
                foreach ($sm->getSharesBy($uid, IShare::TYPE_ROOM, $node, false, -1, 0) as $s) {
                    if ($s->getSharedWith() === $token) { $isShared = true; break; }
                }
                if ($isShared) { $already++; continue; }

                echo sprintf("  %s %s -> %s (%s)\n",
                    $apply ? 'SHARE' : 'would share', $node->getName(), $room->getName() ?: $token, $token);
                if (!$apply) { continue; }

                try {
                    $recService->shareToChat($room, $participant, $node->getId(), $node->getMTime());
                    $shared++;
                } catch (\Throwable $e) {
                    $failed++;
                    echo '    FAILED: ' . get_class($e) . ' ' . $e->getMessage() . "\n";
                    $log->error('share-recordings: could not share ' . $node->getId() . ' to ' . $token,
                        ['exception' => $e, 'app' => 'share-recordings']);
                }
            }
        }
    }
});

echo sprintf("  examined=%d shared=%d already-shared=%d too-new=%d failed=%d\n",
    $examined, $shared, $already, $tooNew, $failed);
exit($failed > 0 ? 1 : 0);
