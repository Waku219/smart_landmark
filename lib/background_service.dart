import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'api_service.dart';
import 'db_helper.dart';

/// Single WorkManager task name used for both:
///  - polling get_job_status for any visit job(s) that are pending, and
///  - draining the offline visit queue once connectivity is back.
/// Per the assignment: these are the same underlying problem (reliable
/// background work that must survive app restarts / bad connectivity), so
/// one worker handles both instead of two separate mechanisms.
const String landmarkSyncTask = 'landmarkSyncTask';

/// Runs it once, immediately, outside of the periodic schedule — used right
/// after a visit is submitted (for a snappy result) and right after
/// connectivity comes back (so the offline queue doesn't wait for the next
/// 15-minute periodic tick).
const String landmarkSyncOneOffTask = 'landmarkSyncOneOffTask';

void _log(String message) => debugPrint('[SyncWorker] $message');

Future<void> initializeBackgroundService() async {
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  // Guaranteed periodic safety net: even if the app is killed / never
  // reopened, queued visits still get flushed and pending jobs still get
  // resolved. 15 minutes is the minimum interval Android's WorkManager
  // allows for periodic work.
  await Workmanager().registerPeriodicTask(
    landmarkSyncTask,
    landmarkSyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    // The assignment asks for retry/backoff on failure. Returning false from
    // executeTask makes WorkManager reschedule using this policy.
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(seconds: 30),
  );
  _log('periodic sync registered (every 15 min, requires network)');
}

/// Ask WorkManager to run the sync worker right now (best-effort, still
/// subject to the network constraint), without waiting for the periodic tick.
///
/// Uses one *fixed* unique name with a `replace` policy. The previous version
/// generated a fresh timestamped name on every call, which meant the
/// ExistingWorkPolicy never actually applied and tapping Visit several times
/// in a row enqueued an unbounded pile of duplicate one-off tasks.
void runLandmarkSyncNow() {
  _log('requesting immediate sync');
  // Guarded: initializeBackgroundService() now runs after the first frame, so
  // a very fast tap could land here before WorkManager is ready. The periodic
  // task will pick the work up regardless, so swallowing this is safe.
  Workmanager()
      .registerOneOffTask(
        landmarkSyncOneOffTask,
        landmarkSyncTask,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(seconds: 15),
      )
      .catchError((Object e) => _log('could not enqueue immediate sync: $e'));
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // This runs in a SEPARATE isolate with its own Dart VM entry point, so
    // the plugin registrations done by the main isolate do not exist here.
    // Without this, every sqflite / http plugin call below throws
    // MissingPluginException and the sync silently does nothing.
    DartPluginRegistrant.ensureInitialized();

    _log('task fired: $task');
    try {
      if (task == landmarkSyncTask) {
        await _runLandmarkSync();
      }
      _log('task complete: $task');
      return true;
    } catch (e, stack) {
      // Returning false tells WorkManager to retry with the backoff policy
      // configured above, rather than treating the run as successful.
      _log('task FAILED: $task -> $e\n$stack');
      return false;
    }
  });
}

Future<void> _runLandmarkSync() async {
  final db = DBHelper();
  final api = ApiService();

  // 1) Drain any visits that were queued while offline: submit them to
  // visit_landmark to get a job_id, then track that job_id for step 2.
  final pendingVisits = await db.getPendingVisits();
  _log('${pendingVisits.length} queued visit(s) to submit');

  for (final visit in pendingVisits) {
    final rowId = visit['id'] as int;
    final title = (visit['landmarkTitle'] ?? 'Landmark').toString();
    try {
      final jobId = await api.visitLandmark(
        visit['landmarkId'] as int,
        (visit['lat'] as num).toDouble(),
        (visit['lon'] as num).toDouble(),
      );

      // Preserve when the user actually made the visit, not when we managed
      // to submit it — otherwise a visit queued overnight shows tomorrow's
      // timestamp in the Activity screen.
      final visitedAt = DateTime.tryParse(
        (visit['createdAt'] ?? '').toString(),
      );

      await db.addPendingJob(jobId, title, visitedAt: visitedAt);
      await db.deletePendingVisit(rowId);
    } on ApiException catch (e) {
      if (e.isPermanent) {
        // 403 invalid key / 404 landmark gone — this can never succeed.
        // Record the failure so the user sees it instead of the visit just
        // evaporating, then drop it from the queue.
        _log('dropping queued visit #$rowId permanently: $e');
        await db.addVisitRecord(
          title,
          null,
          visitedAt: DateTime.tryParse((visit['createdAt'] ?? '').toString()),
          status: 'failed',
        );
        await db.deletePendingVisit(rowId);
      } else {
        _log('transient failure on queued visit #$rowId: $e');
        await db.bumpPendingVisitRetry(rowId);
      }
    } catch (e) {
      // Socket error / timeout / offline — keep it queued and try later.
      _log('network failure on queued visit #$rowId: $e');
      await db.bumpPendingVisitRetry(rowId);
    }
  }

  // 2) Poll every outstanding job (whether it came from an immediate online
  // visit or from step 1 above) and persist completed ones.
  final pendingJobs = await db.getPendingJobs();
  _log('${pendingJobs.length} job(s) to poll');

  for (final job in pendingJobs) {
    final jobId = job['jobId'] as int;
    final title = (job['landmarkTitle'] ?? 'Landmark').toString();
    final visitedAt = DateTime.tryParse((job['visitedAt'] ?? '').toString());

    try {
      final status = await api.getJobStatus(jobId);

      switch (status['status']) {
        case 'done':
          final distance = (status['distance'] as num?)?.toDouble();
          await db.addVisitRecord(title, distance, visitedAt: visitedAt);
          await db.deletePendingJob(jobId);
          break;
        case 'failed':
          // Surface the failure rather than deleting it silently — the spec
          // asks for a success/failure message either way.
          await db.addVisitRecord(
            title,
            null,
            visitedAt: visitedAt,
            status: 'failed',
          );
          await db.deletePendingJob(jobId);
          break;
        default:
          // Still "pending" — leave it, the next run will check again.
          _log('job #$jobId still pending');
      }
    } on ApiException catch (e) {
      if (e.isPermanent) {
        // 404 job_not_found (or 403 bad key). The old code caught this and
        // did nothing, so the row stayed and got re-polled every 15 minutes
        // forever. Drop it.
        _log('dropping job #$jobId permanently: $e');
        await db.addVisitRecord(
          title,
          null,
          visitedAt: visitedAt,
          status: 'failed',
        );
        await db.deletePendingJob(jobId);
      } else {
        _log('transient failure polling job #$jobId: $e');
        await db.bumpPendingJobRetry(jobId);
      }
    } catch (e) {
      _log('network failure polling job #$jobId: $e');
      await db.bumpPendingJobRetry(jobId);
    }
  }

  _log('sync pass finished');
}
