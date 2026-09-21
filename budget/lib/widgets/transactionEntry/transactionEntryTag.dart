import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/categoryIcon.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/util/infiniteRotationAnimation.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:budget/colors.dart';
import 'package:provider/provider.dart';

class TransactionEntryTag extends StatelessWidget {
  const TransactionEntryTag({
    required this.transaction,
    this.showObjectivePercentage = true,
    this.subCategory,
    this.budget,
    this.objective,
    this.objectiveLoan,
    this.showExcludedBudgetTag,
    super.key,
  });
  final Transaction transaction;
  final bool showObjectivePercentage;
  final TransactionCategory? subCategory;
  final Budget? budget;
  final Objective? objective;
  final Objective? objectiveLoan;
  final bool Function(Transaction transaction)? showExcludedBudgetTag;

  @override
  Widget build(BuildContext context) {
    bool showObjectivePercentageCheck = showObjectivePercentage;
    if (transaction.sharedReferenceBudgetPk != null ||
        transaction.subCategoryFk != null ||
        (objective != null && getIsDifferenceOnlyLoan(objective!)))
      showObjectivePercentageCheck = false;

    bool showExcludedBudgetTagCheck = false;
    if (transaction.budgetFksExclude != null && showExcludedBudgetTag != null) {
      showExcludedBudgetTagCheck = showExcludedBudgetTag!(transaction);
    }

    return Theme(
      data: Theme.of(context)
          .copyWith(colorScheme: getColorScheme(Theme.of(context).brightness)),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(top: 4.5),
        child: LayoutBuilder(builder: (context, constraints) {
          double maxWidth = constraints.maxWidth;
          List<bool> tagsToShow = [
            appStateSettings["showAccountLabelTagInTransactionEntry"] ==
                true, //0
            transaction.subCategoryFk != null, //1
            transaction.sharedReferenceBudgetPk != null, //2
            transaction.objectiveLoanFk != null, //3
            transaction.objectiveFk != null, //4
            showExcludedBudgetTagCheck, //5
            transaction.tagFk != null, //6
          ];
          int tagCount = tagsToShow.where((element) => element == true).length;
          List<Widget> tags = [
            // 0
            TransactionTag(
              color: HexColor(
                  Provider.of<AllWallets>(context)
                      .indexedByPk[transaction.walletFk]
                      ?.colour,
                  defaultColor: Theme.of(context).colorScheme.primary),
              name: getWalletStringName(
                  Provider.of<AllWallets>(context),
                  Provider.of<AllWallets>(context)
                      .indexedByPk[transaction.walletFk]),
            ),
            // 1
            Builder(builder: (context) {
              if (subCategory != null) {
                return SubCategoryTag(category: subCategory!);
              } else {
                return StreamBuilder<TransactionCategory?>(
                  stream: database.getCategory(transaction.subCategoryFk!).$1,
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      TransactionCategory? category = snapshot.data!;
                      return SubCategoryTag(category: category);
                    }
                    return SizedBox.shrink();
                  },
                );
              }
            }),
            // 2
            Builder(builder: (context) {
              if (budget != null) {
                return TransactionTag(
                  color: HexColor(budget?.colour,
                      defaultColor: Theme.of(context).colorScheme.primary),
                  name: budget?.name ?? "",
                );
              } else {
                return StreamBuilder<Budget>(
                  stream:
                      database.getBudget(transaction.sharedReferenceBudgetPk!),
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      Budget budget = snapshot.data!;
                      return TransactionTag(
                        color: HexColor(budget.colour,
                            defaultColor:
                                Theme.of(context).colorScheme.primary),
                        name: budget.name,
                      );
                    }
                    return Container();
                  },
                );
              }
            }),
            // 3
            Builder(builder: (context) {
              if (objectiveLoan != null) {
                return ObjectivePercentTag(
                  transaction: transaction,
                  objective: objectiveLoan!,
                  showObjectivePercentageCheck: showObjectivePercentageCheck,
                );
              }
              return StreamBuilder<Objective>(
                stream: database.getObjective(transaction.objectiveLoanFk!),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    if (snapshot.data == null) return Container();
                    Objective objective = snapshot.data!;
                    return ObjectivePercentTag(
                      transaction: transaction,
                      objective: objective,
                      showObjectivePercentageCheck:
                          showObjectivePercentageCheck,
                    );
                  }
                  return Container();
                },
              );
            }),
            // 4
            Builder(builder: (context) {
              if (objective != null) {
                return ObjectivePercentTag(
                  transaction: transaction,
                  objective: objective!,
                  showObjectivePercentageCheck: showObjectivePercentageCheck,
                );
              }
              return StreamBuilder<Objective>(
                stream: database.getObjective(transaction.objectiveFk!),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    Objective objective = snapshot.data!;
                    return ObjectivePercentTag(
                      transaction: transaction,
                      objective: objective,
                      showObjectivePercentageCheck:
                          showObjectivePercentageCheck,
                    );
                  }
                  return Container();
                },
              );
            }),
            // 5
            TransactionTag(
              color: Colors.grey,
              name: "excluded".tr(),
            ),
            // 6
            Builder(builder: (context) {
              return StreamBuilder<Tag?>(
                stream: database.watchTag(transaction.tagFk!),
                builder: (context, snapshot) {
                  Tag? tag = snapshot.data;
                  if (tag == null) return SizedBox.shrink();
                  return TransactionTag(
                    color: HexColor(tag.colour,
                        defaultColor: Theme.of(context).colorScheme.primary),
                    name: tag.name,
                    tagShape: true,
                  );
                },
              );
            }),
          ];
          // work in preogress...
          // if maxwidth > maxWidth/tagCount, wrap in flexible, otherwise dont
          return Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (int i = 0; i < tags.length; i++)
                    if (tagsToShow[i]) Flexible(child: tags[i])
                ],
              ),
              if (transaction.sharedKey != null ||
                  transaction.sharedStatus == SharedStatus.waiting)
                SharedBudgetLabel(transaction: transaction),
            ],
          );
        }),
      ),
    );
  }
}

class SubCategoryTag extends StatelessWidget {
  const SubCategoryTag({required this.category, super.key});
  final TransactionCategory category;

  @override
  Widget build(BuildContext context) {
    return TransactionTag(
      color: HexColor(category.colour,
          defaultColor: Theme.of(context).colorScheme.primary),
      name: (category.emojiIconName != null
              ? ((category.emojiIconName ?? "") + " ")
              : "") +
          category.name,
      leading: category.emojiIconName != null
          ? null
          : Padding(
              padding: const EdgeInsetsDirectional.only(end: 3),
              child: CategoryIcon(
                categoryPk: "-1",
                category: category,
                size: 14,
                sizePadding: 1,
                noBackground: true,
                canEditByLongPress: false,
                margin: EdgeInsetsDirectional.zero,
              ),
            ),
    );
  }
}

class ObjectivePercentTag extends StatelessWidget {
  const ObjectivePercentTag(
      {required this.transaction,
      required this.objective,
      required this.showObjectivePercentageCheck,
      super.key});
  final Transaction transaction;
  final Objective objective;
  final bool showObjectivePercentageCheck;
  @override
  Widget build(BuildContext context) {
    if (getIsDifferenceOnlyLoan(objective)) {
      return TransactionTag(
        color: HexColor(objective.colour,
            defaultColor: Theme.of(context).colorScheme.primary),
        name: objective.name,
      );
    }
    return WatchTotalAndAmountOfObjective(
      objective: objective,
      builder: (objectiveAmount, totalAmount, percentageTowardsGoal) {
        return TransactionTag(
          color: HexColor(objective.colour,
              defaultColor: Theme.of(context).colorScheme.primary),
          name: objective.name +
              ": " +
              convertToPercent(percentageTowardsGoal * 100,
                  numberDecimals: 0, useLessThanZero: true),
          progress: percentageTowardsGoal,
        );
      },
    );
  }
}

class TransactionTag extends StatelessWidget {
  final Color color;
  final String name;
  final EdgeInsetsDirectional margin;
  final EdgeInsetsDirectional? padding;
  final Widget? leading;
  final double? progress;
  final bool tagShape;
  final double? fontSize;
  final VoidCallback? onTap;
  final Color? customBackgroundColor;

  TransactionTag({
    required this.color,
    required this.name,
    this.margin = const EdgeInsetsDirectional.only(start: 3),
    this.padding,
    this.leading,
    this.progress,
    this.tagShape = false,
    this.fontSize,
    this.onTap,
    this.customBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    bool isRTL = Directionality.of(context) == TextDirection.rtl;
    EdgeInsetsDirectional effectivePadding = padding ??
        (tagShape
            ? const EdgeInsetsDirectional.only(
                start: 15.5,
                end: 9.5,
                top: 1.2,
                bottom: 1.2,
              )
            : const EdgeInsetsDirectional.symmetric(
                horizontal: 4.5, vertical: 1.05));

    Widget tagContent = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        leading ?? SizedBox.shrink(),
        Flexible(
          child: TextFont(
            text: name,
            fontSize: fontSize ?? 11.5,
            textColor: getColor(context, "black").withOpacity(0.7),
            maxLines: appStateSettings["fadeTransactionNameOverflows"] == false
                ? null
                : 1,
            overflow: appStateSettings["fadeTransactionNameOverflows"] == false
                ? null
                : TextOverflow.fade,
            softWrap: appStateSettings["fadeTransactionNameOverflows"] == false
                ? null
                : false,
          ),
        ),
      ],
    );

    Color resolvedBgColor = customBackgroundColor ??
        color.withOpacity(progress != null ? 0.15 : 0.25);

    Widget tagWidget;
    if (tagShape) {
      tagWidget = ClipPath(
        clipper: TagClipper(isRTL: isRTL),
        child: Container(
          color: resolvedBgColor,
          padding: effectivePadding,
          child: tagContent,
        ),
      );
    } else {
      tagWidget = Container(
        decoration: BoxDecoration(
          color: resolvedBgColor,
          borderRadius: BorderRadiusDirectional.circular(6),
        ),
        padding: effectivePadding,
        child: tagContent,
      );
    }

    if (onTap != null) {
      tagWidget = Tappable(
        color: Colors.transparent,
        onTap: onTap,
        child: tagWidget,
      );
    }

    if (progress != null)
      return LayoutBuilder(builder: (context, constraints) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 3),
            child: ClipRRect(
              borderRadius: BorderRadiusDirectional.circular(6),
              child: Stack(
                children: [
                  tagWidget,
                  PositionedDirectional(
                    top: 0,
                    bottom: 0,
                    start: 0,
                    end: 0,
                    child: Stack(
                      children: [
                        FractionallySizedBox(
                          widthFactor: progress?.clamp(0, 1),
                          heightFactor: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.2),
                              borderRadius: BorderRadiusDirectional.circular(6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
        );
      });
    return Padding(padding: margin, child: tagWidget);
  }
}

class TagClipper extends CustomClipper<Path> {
  final bool isRTL;

  const TagClipper({this.isRTL = false});

  @override
  Path getClip(Size size) {
    return buildTagPath(size, isRTL);
  }

  @override
  bool shouldReclip(covariant TagClipper oldClipper) {
    return oldClipper.isRTL != isRTL;
  }
}

Path buildTagPath(Size size, bool isRTL) {
  final double w = size.width;
  final double h = size.height;
  if (w <= 0 || h <= 0) return Path();

  // Radius for the rectangular corners (opposite side of triangle)
  final double r = 5.0.clamp(1.0, h / 2);

  // Depth of the triangular tip
  // final double tipWidth = (h * 0.42).clamp(5.0, 8.5);
  // final double clampedTipWidth = tipWidth.clamp(2.0, w * 0.35);
  final double tipWidth = (h * 0.62).clamp(5.0, 10.5);
  final double clampedTipWidth = tipWidth.clamp(2.0, w * 0.35);

  // Parameters for smooth rounded apex
  final double tApex = 0.35;
  final double xApex = clampedTipWidth * tApex;
  final double yApex = (h / 2) * tApex;

  final double rCorner = 1.8;
  final double slope = (h / 2) / clampedTipWidth;

  final Path path = Path();

  if (!isRTL) {
    // Triangular point on the LEFT, rectangular on the RIGHT
    path.moveTo(clampedTipWidth + rCorner, 0);
    // Straight top edge
    path.lineTo(w - r, 0);
    // Top-right rounded corner
    path.arcToPoint(Offset(w, r), radius: Radius.circular(r));
    // Straight right edge
    path.lineTo(w, h - r);
    // Bottom-right rounded corner
    path.arcToPoint(Offset(w - r, h), radius: Radius.circular(r));
    // Bottom horizontal edge
    path.lineTo(clampedTipWidth + rCorner, h);
    // Smooth transition from horizontal bottom to diagonal slope
    path.quadraticBezierTo(
      clampedTipWidth,
      h,
      clampedTipWidth - rCorner * 0.7,
      h - rCorner * 0.7 * slope,
    );
    // Diagonal slope to apex curve start
    path.lineTo(xApex, h / 2 + yApex);
    // Smooth rounded apex at the tip (x = 0)
    path.quadraticBezierTo(0, h / 2, xApex, h / 2 - yApex);
    // Diagonal slope up to top junction
    path.lineTo(clampedTipWidth - rCorner * 0.7, rCorner * 0.7 * slope);
    // Smooth transition into horizontal top line
    path.quadraticBezierTo(clampedTipWidth, 0, clampedTipWidth + rCorner, 0);
    path.close();
  } else {
    // RTL: Triangular point on the RIGHT, rectangular on the LEFT
    path.moveTo(w - clampedTipWidth - rCorner, 0);
    path.lineTo(r, 0);
    path.arcToPoint(Offset(0, r), radius: Radius.circular(r), clockwise: false);
    path.lineTo(0, h - r);
    path.arcToPoint(Offset(r, h), radius: Radius.circular(r), clockwise: false);
    path.lineTo(w - clampedTipWidth - rCorner, h);
    path.quadraticBezierTo(
      w - clampedTipWidth,
      h,
      w - clampedTipWidth + rCorner * 0.7,
      h - rCorner * 0.7 * slope,
    );
    path.lineTo(w - xApex, h / 2 + yApex);
    path.quadraticBezierTo(w, h / 2, w - xApex, h / 2 - yApex);
    path.lineTo(w - clampedTipWidth + rCorner * 0.7, rCorner * 0.7 * slope);
    path.quadraticBezierTo(
        w - clampedTipWidth, 0, w - clampedTipWidth - rCorner, 0);
    path.close();
  }

  return path;
}

class SharedBudgetLabel extends StatelessWidget {
  const SharedBudgetLabel({required this.transaction, super.key});
  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 1.0),
      child: Row(
        children: [
          transaction.sharedStatus == SharedStatus.waiting
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(top: 2.0),
                  child: InfiniteRotationAnimation(
                    duration: Duration(milliseconds: 5000),
                    child: Icon(
                      transaction.sharedStatus == SharedStatus.waiting
                          ? appStateSettings["outlinedIcons"]
                              ? Icons.sync_outlined
                              : Icons.sync_rounded
                          : transaction.transactionOwnerEmail !=
                                  appStateSettings["currentUserEmail"]
                              ? appStateSettings["outlinedIcons"]
                                  ? Icons.arrow_circle_down_outlined
                                  : Icons.arrow_circle_down_rounded
                              : appStateSettings["outlinedIcons"]
                                  ? Icons.arrow_circle_up_outlined
                                  : Icons.arrow_circle_up_rounded,
                      size: 14,
                      color: getColor(context, "black").withOpacity(0.7),
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsetsDirectional.only(top: 2),
                  child: Icon(
                    transaction.transactionOwnerEmail !=
                            appStateSettings["currentUserEmail"]
                        ? appStateSettings["outlinedIcons"]
                            ? Icons.arrow_circle_down_outlined
                            : Icons.arrow_circle_down_rounded
                        : appStateSettings["outlinedIcons"]
                            ? Icons.arrow_circle_up_outlined
                            : Icons.arrow_circle_up_rounded,
                    size: 14,
                    color: getColor(context, "black").withOpacity(0.7),
                  ),
                ),
          SizedBox(width: 2),
          Expanded(
            child: Row(
              children: [
                transaction.sharedReferenceBudgetPk == null
                    ? SizedBox.shrink()
                    : Expanded(
                        child: StreamBuilder<Budget>(
                          stream: database
                              .getBudget(transaction.sharedReferenceBudgetPk!),
                          builder: (context, snapshot) {
                            if (snapshot.hasData) {
                              return TextFont(
                                overflow: TextOverflow.ellipsis,
                                text: (transaction.transactionOwnerEmail
                                                .toString() ==
                                            appStateSettings["currentUserEmail"]
                                        ? getMemberNickname(appStateSettings[
                                            "currentUserEmail"])
                                        : transaction.sharedStatus ==
                                                    SharedStatus.waiting &&
                                                (transaction.transactionOwnerEmail ==
                                                        appStateSettings[
                                                            "currentUserEmail"] ||
                                                    transaction
                                                            .transactionOwnerEmail ==
                                                        null)
                                            ? getMemberNickname(
                                                appStateSettings[
                                                    "currentUserEmail"])
                                            : getMemberNickname(transaction
                                                .transactionOwnerEmail
                                                .toString())) +
                                    " for " +
                                    snapshot.data!.name,
                                fontSize: 12.5,
                                textColor:
                                    getColor(context, "black").withOpacity(0.7),
                              );
                            }
                            return Container();
                          },
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
