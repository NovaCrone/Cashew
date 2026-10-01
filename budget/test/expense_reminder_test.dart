import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/widgets/expenseReminderOverlay.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only opted-in one-off expenses are watched', () async {
    final database = FinanceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final transactionDate = DateTime(2026, 10, 1, 9);
    final reminderDate = DateTime(2026, 10, 2, 9);

    Future<void> insertTransaction(String transactionPk,
        {bool income = false,
        TransactionSpecialType? type,
        String categoryPk = 'expense',
        DateTime? reminder}) async {
      await database.into(database.transactions).insert(
            TransactionsCompanion.insert(
              transactionPk: Value(transactionPk),
              name: transactionPk,
              amount: -10,
              note: '',
              categoryFk: categoryPk,
              income: Value(income),
              type: Value(type),
              dateCreated: Value(transactionDate),
              reminderDateTime: Value(reminder),
            ),
          );
    }

    await insertTransaction('expense', reminder: reminderDate);
    await insertTransaction('off');
    await insertTransaction('income', income: true, reminder: reminderDate);
    await insertTransaction('upcoming',
        type: TransactionSpecialType.upcoming, reminder: reminderDate);
    await insertTransaction('correction',
        categoryPk: '0', reminder: reminderDate);

    final reminders = await database.watchExpenseReminders().first;
    expect(
        reminders.map((transaction) => transaction.transactionPk), ['expense']);

    await (database.update(database.transactions)
          ..where((transaction) => transaction.transactionPk.equals('expense')))
        .write(const TransactionsCompanion(reminderDateTime: Value(null)));
    expect(await database.watchExpenseReminders().first, isEmpty);
  });

  testWidgets('dismissal lasts until relaunch, not foreground resume',
      (tester) async {
    final reminders = StreamController<List<Transaction>>.broadcast();
    addTearDown(reminders.close);
    final transaction = Transaction(
      transactionPk: 'expense',
      name: 'Groceries',
      amount: -10,
      note: '',
      categoryFk: 'expense',
      walletFk: '0',
      dateCreated: DateTime.now().subtract(const Duration(days: 2)),
      income: false,
      paid: true,
      skipPaid: true,
      reminderDateTime: DateTime.now().subtract(const Duration(days: 1)),
    );
    Widget app() => MaterialApp(
          home: Stack(children: [
            ExpenseReminderOverlay(watchReminders: () => reminders.stream),
          ]),
        );

    await tester.pumpWidget(app());
    reminders.add([transaction]);
    await tester.pump();
    expect(find.text('Groceries'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Groceries'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    reminders.add([transaction]);
    await tester.pump();
    expect(find.text('Groceries'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    final secondTransaction = transaction.copyWith(
      transactionPk: 'rent',
      name: 'Rent',
      reminderDateTime:
          Value(DateTime.now().subtract(const Duration(hours: 1))),
    );
    reminders.add([transaction, secondTransaction]);
    await tester.pump();
    expect(find.text('Groceries'), findsOneWidget);

    final groceriesCard = find.ancestor(
      of: find.text('Groceries'),
      matching: find.byType(Material),
    );
    await tester.tap(
      find.descendant(
        of: groceriesCard,
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pump();
    expect(find.text('Rent'), findsOneWidget);
    final rentCard = find.ancestor(
      of: find.text('Rent'),
      matching: find.byType(Material),
    );
    await tester.tap(
      find.descendant(
        of: rentCard,
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pump();
    reminders.add([
      transaction.copyWith(
        reminderDateTime:
            Value(DateTime.now().subtract(const Duration(hours: 2))),
      ),
      secondTransaction,
    ]);
    await tester.pump();
    expect(find.text('Groceries'), findsOneWidget);
  });

  testWidgets('a future reminder appears while the app remains open',
      (tester) async {
    final reminders = StreamController<List<Transaction>>.broadcast();
    addTearDown(reminders.close);
    var now = DateTime(2026, 10, 1, 12);
    final transaction = Transaction(
      transactionPk: 'expense',
      name: 'Utilities',
      amount: -10,
      note: '',
      categoryFk: 'expense',
      walletFk: '0',
      dateCreated: now.subtract(const Duration(days: 1)),
      income: false,
      paid: true,
      skipPaid: true,
      reminderDateTime: now.add(const Duration(seconds: 10)),
    );
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        ExpenseReminderOverlay(
            watchReminders: () => reminders.stream, now: () => now),
      ]),
    ));
    reminders.add([transaction]);
    await tester.pump();
    expect(find.text('Utilities'), findsNothing);
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('Utilities'), findsOneWidget);
  });
}
