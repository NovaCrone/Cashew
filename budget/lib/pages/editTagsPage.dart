import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addTagPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/fab.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/iconButtonScaled.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart' hide TextInput;

class EditTagsPage extends StatefulWidget {
  const EditTagsPage({Key? key}) : super(key: key);

  @override
  State<EditTagsPage> createState() => _EditTagsPageState();
}

class _EditTagsPageState extends State<EditTagsPage> {
  final TextEditingController _searchController = TextEditingController();

  String get searchValue => _searchController.text;

  void clearSearch() {
    if (searchValue.isEmpty) return;
    _searchController.clear();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (searchValue.isNotEmpty) {
          clearSearch();
          return false;
        }
        return true;
      },
      child: PageFramework(
        horizontalPaddingConstrained: true,
        dragDownToDismiss: true,
        scrollToTopButton: true,
        title: "edit-tags".tr(),
        onBackButton: () {
          if (searchValue.isNotEmpty) {
            clearSearch();
            return;
          }
          maybePopRoute(context);
        },
        floatingActionButton: AnimateFABDelayed(
          fab: AddFAB(
            tooltip: "add-tag".tr(),
            openPage: AddTagPage(
              routesToPopAfterDelete: RoutesToPopAfterDelete.None,
            ),
          ),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 8.0),
              child: TextInput(
                controller: _searchController,
                labelText: "search-tags-placeholder".tr(),
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.search_outlined
                    : Icons.search_rounded,
              ),
            ),
          ),
          StreamBuilder<List<Tag>>(
            stream: database.watchAllTags(searchFor: searchValue),
            builder: (context, snapshot) {
              if (snapshot.hasData == false) {
                return SliverToBoxAdapter(child: Container());
              }
              List<Tag> tagsToShow = snapshot.data!;
              if (tagsToShow.isEmpty) {
                return SliverToBoxAdapter(
                  child: NoResults(message: "no-tags-found".tr()),
                );
              }
              return SliverToBoxAdapter(
                child: Column(
                  children: [
                    for (Tag tag in tagsToShow) TagListEntry(tag: tag),
                  ],
                ),
              );
            },
          ),
          SliverToBoxAdapter(child: SizedBox(height: 75)),
        ],
      ),
    );
  }
}

class TagListEntry extends StatelessWidget {
  const TagListEntry({required this.tag, super.key});
  final Tag tag;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsetsDirectional.symmetric(horizontal: 13, vertical: 4),
      child: Tappable(
        borderRadius: 15,
        color: getColor(context, "lightDarkAccent"),
        onTap: () {
          pushRoute(
            context,
            AddTagPage(
              tag: tag,
              routesToPopAfterDelete: RoutesToPopAfterDelete.One,
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: HexColor(
                    tag.colour,
                    defaultColor: Theme.of(context).colorScheme.primary,
                  ),
                  borderRadius: BorderRadiusDirectional.circular(4),
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFont(
                      text: tag.name,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                    SizedBox(height: 5),
                    StreamBuilder<int?>(
                      stream: database
                          .watchTotalCountOfTransactionsWithTag(tag.tagPk),
                      builder: (context, snapshot) {
                        int count = snapshot.data ?? 0;
                        return TextFont(
                          text: count.toString() +
                              " " +
                              (count == 1
                                  ? "transaction".tr().toLowerCase()
                                  : "transactions".tr().toLowerCase()),
                          fontSize: 14,
                          textColor:
                              getColor(context, "black").withOpacity(0.65),
                        );
                      },
                    ),
                  ],
                ),
              ),
              TextFont(
                text: getTimeAgo(tag.dateCreated),
                fontSize: 13,
                textColor: getColor(context, "textLight"),
              ),
              IconButtonScaled(
                iconData: appStateSettings["outlinedIcons"]
                    ? Icons.delete_outlined
                    : Icons.delete_rounded,
                iconSize: 20,
                scale: 1.4,
                onTap: () async {
                  await deleteTagPopup(
                    context,
                    tag: tag,
                    routesToPopAfterDelete: RoutesToPopAfterDelete.None,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<DeletePopupAction?> deleteTagPopup(
  BuildContext context, {
  required Tag tag,
  required RoutesToPopAfterDelete routesToPopAfterDelete,
}) async {
  DeletePopupAction? action = await openDeletePopup(
    context,
    title: "delete-tag-question".tr(),
    subtitle: tag.name,
    description: "delete-tag-question-description".tr(),
  );
  if (action == DeletePopupAction.Delete) {
    if (routesToPopAfterDelete == RoutesToPopAfterDelete.All) {
      popAllRoutes(context);
    } else if (routesToPopAfterDelete == RoutesToPopAfterDelete.One) {
      popRoute(context);
    }
    openLoadingPopupTryCatch(() async {
      await database.deleteTag(tag.tagPk);
      openSnackbar(
        SnackbarMessage(
          title: "deleted-tag".tr(),
          icon: Icons.delete,
          description: tag.name,
        ),
      );
    });
  }
  return action;
}

void mergeTagPopup(
  BuildContext context, {
  required Tag tagOriginal,
  required RoutesToPopAfterDelete routesToPopAfterDelete,
}) async {
  Tag? selectedTagResult = await selectTagPopup(
    context,
    excludeTagPks: [tagOriginal.tagPk],
    subtitle: "tag-to-transfer-all-transactions-to".tr(),
  );
  if (selectedTagResult != null) {
    final result = await openPopup(
      context,
      title: "merge-into".tr() + " " + selectedTagResult.name + "?",
      description: "merge-into-description-tags".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.merge_outlined
          : Icons.merge_rounded,
      onSubmit: () async {
        popRoute(context, true);
      },
      onSubmitLabel: "merge".tr(),
      onCancelLabel: "cancel".tr(),
      onCancel: () {
        popRoute(context);
      },
    );
    if (result == true) {
      if (routesToPopAfterDelete == RoutesToPopAfterDelete.All) {
        popAllRoutes(context);
      } else if (routesToPopAfterDelete == RoutesToPopAfterDelete.One) {
        popRoute(context);
      }
      openLoadingPopupTryCatch(() async {
        await database.mergeAndDeleteTag(tagOriginal, selectedTagResult);
        openSnackbar(
          SnackbarMessage(
            title: "merged-tag".tr(),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.merge_outlined
                : Icons.merge_rounded,
            description: tagOriginal.name + " → " + selectedTagResult.name,
          ),
        );
      });
    }
  }
}

Future<Tag?> selectTagPopup(
  BuildContext context, {
  List<String> excludeTagPks = const [],
  String? subtitle,
  Tag? selectedTag,
}) async {
  dynamic tag = await openBottomSheet(
    context,
    PopupFramework(
      title: "select-tag".tr(),
      subtitle: subtitle,
      child: StreamBuilder<List<Tag>>(
        stream: database.watchAllTags(),
        builder: (context, snapshot) {
          if (snapshot.hasData == false) return SizedBox.shrink();
          List<Tag> tagsToShow = [...snapshot.data!]
            ..removeWhere((tag) => excludeTagPks.contains(tag.tagPk));
          if (tagsToShow.isEmpty) {
            return Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 15),
              child: NoResults(message: "no-tags-found".tr()),
            );
          }
          return Column(
            children: [
              for (Tag tag in tagsToShow)
                Padding(
                  padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
                  child: MergeTagOption(
                    tag: tag,
                    selected: selectedTag?.tagPk == tag.tagPk,
                    onTap: () {
                      popRoute(context, tag);
                    },
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
  if (tag is Tag) return tag;
  return null;
}

class MergeTagOption extends StatelessWidget {
  const MergeTagOption({
    required this.tag,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final Tag tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Color tagColor = HexColor(
      tag.colour,
      defaultColor: Theme.of(context).colorScheme.primary,
    );
    return Tappable(
      color: Colors.transparent,
      borderRadius: getPlatform() == PlatformOS.isIOS ? 10 : 15,
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsetsDirectional.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            Radio<bool>(
              value: true,
              groupValue: selected,
              onChanged: (_) => onTap(),
              activeColor: Theme.of(context).colorScheme.primary,
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: dynamicPastel(context, tagColor, amount: 0.35),
                  borderRadius: BorderRadiusDirectional.circular(10),
                ),
                child: TextFont(
                  text: tag.name,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
