import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class ExpenseReminderOverlay extends StatefulWidget {
  const ExpenseReminderOverlay({super.key, this.watchReminders, this.now});

  final Stream<List<Transaction>> Function()? watchReminders;
  final DateTime Function()? now;

  @override
  State<ExpenseReminderOverlay> createState() => _ExpenseReminderOverlayState();
}

class _ExpenseReminderOverlayState extends State<ExpenseReminderOverlay>
    with WidgetsBindingObserver {
  StreamSubscription<List<Transaction>>? _subscription;
  Timer? _nextReminder;
  List<Transaction> _transactions = [];
  final Set<String> _dismissed = {};
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final List<Transaction> _visibleTransactions = [];
  bool _foreground = true;

  String _keyFor(Transaction transaction) =>
      '${transaction.transactionPk}:${transaction.reminderDateTime!.microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (_foreground) _listen();
  }

  void _listen() {
    _subscription ??=
        (widget.watchReminders?.call() ?? database.watchExpenseReminders())
            .listen((transactions) {
      _transactions = transactions;
      _refresh();
    });
  }

  void _refresh() {
    _nextReminder?.cancel();
    if (!_foreground || !mounted) return;

    final now = widget.now?.call() ?? DateTime.now();
    final pending = _transactions.where((transaction) =>
        transaction.reminderDateTime != null &&
        !transaction.reminderDateTime!.isBefore(transaction.dateCreated) &&
        !_dismissed.contains(_keyFor(transaction)));
    final overdue = pending
        .where((transaction) => !transaction.reminderDateTime!.isAfter(now));
    _syncVisibleTransactions(overdue.take(3).toList());

    final future = pending
        .where((transaction) => transaction.reminderDateTime!.isAfter(now))
        .toList()
      ..sort((a, b) => a.reminderDateTime!.compareTo(b.reminderDateTime!));
    if (future.isNotEmpty) {
      final remaining = future.first.reminderDateTime!.difference(now);
      _nextReminder = Timer(
          remaining > const Duration(days: 1)
              ? const Duration(days: 1)
              : remaining,
          _refresh);
    }
  }

  void _syncVisibleTransactions(List<Transaction> target) {
    final targetKeys = target.map(_keyFor).toSet();
    final animatedList = _listKey.currentState;

    for (int index = _visibleTransactions.length - 1; index >= 0; index--) {
      if (!targetKeys.contains(_keyFor(_visibleTransactions[index]))) {
        final removed = _visibleTransactions.removeAt(index);
        animatedList?.removeItem(
          index,
          (context, animation) => _buildReminderEntry(
            context,
            removed,
            animation,
          ),
          duration: const Duration(milliseconds: 250),
        );
      }
    }

    for (int index = 0; index < target.length; index++) {
      final targetKey = _keyFor(target[index]);
      final existingIndex = _visibleTransactions
          .indexWhere((transaction) => _keyFor(transaction) == targetKey);

      if (existingIndex == -1) {
        _visibleTransactions.insert(index, target[index]);
        animatedList?.insertItem(
          index,
          duration: const Duration(milliseconds: 250),
        );
      } else {
        _visibleTransactions[index] = target[index];
      }
    }

    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _listen();
    } else {
      _foreground = false;
      _nextReminder?.cancel();
      _subscription?.cancel();
      _subscription = null;
      if (_visibleTransactions.isNotEmpty) {
        setState(() => _visibleTransactions.clear());
      }
    }
  }

  void _dismiss(Transaction transaction) {
    _dismissed.add(_keyFor(transaction));
    _refresh();
  }

  void _openTransaction(Transaction transaction) {
    _dismiss(transaction);
    pushRoute(
      context,
      AddTransactionPage(
        transaction: transaction,
        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nextReminder?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_visibleTransactions.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding:
              const EdgeInsetsDirectional.only(start: 16, end: 16, bottom: 80),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AnimatedList(
              key: _listKey,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              initialItemCount: _visibleTransactions.length,
              itemBuilder: (context, index, animation) => _buildReminderEntry(
                context,
                _visibleTransactions[index],
                animation,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReminderEntry(
    BuildContext context,
    Transaction transaction,
    Animation<double> animation,
  ) {
    final slide = animation.drive(
      Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero),
    );
    return SlideTransition(
      position: slide,
      child: SizeTransition(
        sizeFactor: animation,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(bottom: 8),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsetsDirectional.only(start: 16, end: 10),
                  child: Icon(Icons.notifications_active_outlined),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => _openTransaction(transaction),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('transaction-reminder'.tr(),
                              style: Theme.of(context).textTheme.labelMedium),
                          Text(transaction.name,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _dismiss(transaction),
                  icon: const Icon(Icons.close),
                  tooltip: 'close'.tr(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
