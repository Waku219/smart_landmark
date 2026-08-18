import 'dart:async';

import 'package:flutter/material.dart';

import 'db_helper.dart';

class ActivityScreen extends StatefulWidget {
  /// Bumped by the parent when this tab is opened, so history is re-read
  /// instead of being stuck with whatever initState loaded (IndexedStack
  /// keeps this State alive for the life of the app).
  final ValueNotifier<int>? revision;

  const ActivityScreen({super.key, this.revision});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final DBHelper _dbHelper = DBHelper();

  List<Map<String, dynamic>> _history = [];
  int _pendingJobs = 0;
  int _queuedVisits = 0;
  bool _isLoading = true;

  /// While anything is in flight we re-read the local DB on a short timer.
  ///
  /// This is the missing link in the async visit flow: the WorkManager worker
  /// writes the result from a *different isolate*, so it has no way to call
  /// setState here. Without this poll the distance only ever appears if the
  /// user happens to pull-to-refresh at the right moment.
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    widget.revision?.addListener(_onRevisionChanged);
    _loadHistory();
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_onRevisionChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onRevisionChanged() => _loadHistory();

  Future<void> _loadHistory() async {
    // Every DB call is guarded: if opening the database fails, this must
    // still clear _isLoading rather than leaving a spinner on screen forever.
    List<Map<String, dynamic>> history = const [];
    int pendingJobs = 0;
    int queuedVisits = 0;

    try {
      history = await _dbHelper.getVisitHistory();
      pendingJobs = await _dbHelper.getPendingJobCount();
      queuedVisits = await _dbHelper.getPendingVisitCount();
    } catch (e) {
      debugPrint('[ActivityScreen] could not read visit history: $e');
    }

    if (!mounted) return;
    setState(() {
      _history = history;
      _pendingJobs = pendingJobs;
      _queuedVisits = queuedVisits;
      _isLoading = false;
    });

    _syncPollTimer();
  }

  /// Runs the timer only while there is something outstanding, so an idle
  /// Activity tab isn't hitting sqlite every few seconds forever.
  void _syncPollTimer() {
    final hasOutstanding = _pendingJobs > 0 || _queuedVisits > 0;

    if (hasOutstanding && _pollTimer == null) {
      _pollTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _loadHistory(),
      );
    } else if (!hasOutstanding && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = null;
    }
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final isToday =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');

    if (isToday) return 'Today $hh:$mm';

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${t.day} ${months[t.month - 1]} ${t.year}, $hh:$mm';
  }

  Widget _buildPendingBanner() {
    final parts = <String>[
      if (_queuedVisits > 0)
        '$_queuedVisits visit${_queuedVisits == 1 ? '' : 's'} waiting for internet',
      if (_pendingJobs > 0)
        '$_pendingJobs result${_pendingJobs == 1 ? '' : 's'} being processed',
    ];

    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(parts.join(' · '))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasPending = _pendingJobs > 0 || _queuedVisits > 0;

    return Column(
      children: [
        if (hasPending) _buildPendingBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadHistory,
            child: _history.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 180),
                      Center(
                        child: Text('No visits yet. Go visit a landmark!'),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: _history.length,
                    itemBuilder: (context, index) {
                      final record = _history[index];
                      final visitTime =
                          DateTime.tryParse(
                            (record['visitTime'] ?? '').toString(),
                          ) ??
                          DateTime.now();

                      final distance = (record['distance'] as num?)?.toDouble();
                      final failed = record['status'] == 'failed';

                      return ListTile(
                        leading: Icon(
                          failed ? Icons.error_outline : Icons.check_circle,
                          color: failed ? Colors.red : Colors.green,
                        ),
                        title: Text(
                          (record['landmarkTitle'] ?? 'Landmark').toString(),
                        ),
                        subtitle: Text(
                          failed
                              ? '${_formatTime(visitTime)} • Visit failed'
                              : '${_formatTime(visitTime)} • '
                                  'Distance: ${distance?.toStringAsFixed(2) ?? '—'} m',
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
