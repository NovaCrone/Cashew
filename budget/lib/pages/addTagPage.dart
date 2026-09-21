import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/editTagsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/saveBottomButton.dart';
import 'package:budget/widgets/selectColor.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart' hide TextInput;
import 'package:provider/provider.dart';

class AddTagPage extends StatefulWidget {
  const AddTagPage({
    Key? key,
    this.tag,
    required this.routesToPopAfterDelete,
  }) : super(key: key);

  // When a tag is passed in, we are editing that tag
  final Tag? tag;
  final RoutesToPopAfterDelete routesToPopAfterDelete;

  @override
  State<AddTagPage> createState() => _AddTagPageState();
}

class _AddTagPageState extends State<AddTagPage> {
  String? selectedTitle;
  Color? selectedColor;
  bool? canAddTag;
  Tag? tagInitial;
  final TextEditingController _titleController = TextEditingController();

  void setSelectedColor(Color? color) {
    setState(() {
      selectedColor = color;
    });
    determineBottomButton();
  }

  void setSelectedTitle(String title) {
    setState(() {
      selectedTitle = title;
    });
    determineBottomButton();
  }

  void determineBottomButton() {
    if ((selectedTitle ?? "").trim() != "") {
      if (canAddTag != true) setState(() => canAddTag = true);
    } else {
      if (canAddTag != false) setState(() => canAddTag = false);
    }
  }

  Tag createTag() {
    return Tag(
      tagPk: widget.tag?.tagPk ?? "-1",
      name: (selectedTitle ?? "").trim(),
      colour: toHexString(selectedColor),
      dateCreated:
          widget.tag != null ? widget.tag!.dateCreated : DateTime.now(),
      dateTimeModified: null,
    );
  }

  void showDiscardChangesPopupIfNotEditing() {
    // Normalize dateCreated since createTag() stamps DateTime.now() each call
    Tag tagCreated = createTag().copyWith(
      dateCreated: tagInitial?.dateCreated,
    );
    if (tagCreated != tagInitial && widget.tag == null) {
      discardChangesPopup(context, forceShow: true);
    } else {
      popRoute(context);
    }
  }

  Future<void> saveTag() async {
    if (canAddTag != true) return;
    await database.createOrUpdateTag(createTag(), insert: widget.tag == null);
    popRoute(context);
  }

  @override
  void initState() {
    super.initState();
    if (widget.tag != null) {
      selectedTitle = widget.tag!.name;
      selectedColor =
          widget.tag!.colour == null ? null : HexColor(widget.tag!.colour);
      _titleController.text = selectedTitle ?? "";
    }
    // We can't save until a change is made
    canAddTag = false;
    if (widget.tag == null) {
      Future.delayed(Duration.zero, () {
        tagInitial = createTag();
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (widget.tag != null) {
          discardChangesPopup(
            context,
            previousObject: widget.tag!,
            currentObject: createTag(),
          );
        } else {
          showDiscardChangesPopupIfNotEditing();
        }
        return false;
      },
      child: PageFramework(
        resizeToAvoidBottomInset: true,
        dragDownToDismiss: true,
        horizontalPaddingConstrained: true,
        title: widget.tag == null ? "add-tag".tr() : "edit-tag".tr(),
        onBackButton: () async {
          if (widget.tag != null) {
            discardChangesPopup(
              context,
              previousObject: widget.tag!,
              currentObject: createTag(),
            );
          } else {
            showDiscardChangesPopupIfNotEditing();
          }
        },
        onDragDownToDismiss: () async {
          if (widget.tag != null) {
            discardChangesPopup(
              context,
              previousObject: widget.tag!,
              currentObject: createTag(),
            );
          } else {
            showDiscardChangesPopupIfNotEditing();
          }
        },
        actions: [
          if (widget.tag != null &&
              widget.routesToPopAfterDelete !=
                  RoutesToPopAfterDelete.PreventDelete)
            IconButton(
              padding: EdgeInsetsDirectional.all(15),
              tooltip: "delete-tag".tr(),
              onPressed: () async {
                await deleteTagPopup(
                  context,
                  tag: widget.tag!,
                  routesToPopAfterDelete: widget.routesToPopAfterDelete,
                );
              },
              icon: Icon(appStateSettings["outlinedIcons"]
                  ? Icons.delete_outlined
                  : Icons.delete_rounded),
            ),
        ],
        staticOverlay: Align(
          alignment: AlignmentDirectional.bottomCenter,
          child: SaveBottomButton(
            label: widget.tag == null ? "add-tag".tr() : "save-changes".tr(),
            onTap: saveTag,
            disabled: !(canAddTag ?? false),
          ),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
              child: TextInput(
                autoFocus: widget.tag == null,
                labelText: "tag-name-placeholder".tr(),
                bubbly: false,
                controller: _titleController,
                onChanged: setSelectedTitle,
                padding: EdgeInsetsDirectional.only(start: 7, end: 7),
                fontSize: 30,
                fontWeight: FontWeight.bold,
                topContentPadding: 20,
              ),
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: 14)),
          SliverToBoxAdapter(
            child: Container(
              height: 65,
              child: SelectColor(
                horizontalList: true,
                selectedColor: selectedColor,
                setSelectedColor: setSelectedColor,
              ),
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: 15)),
          if (widget.tag != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 24,
                  end: 24,
                  bottom: 10,
                ),
                child: StreamBuilder<double?>(
                  stream: database.watchTotalSpentForTag(widget.tag!.tagPk),
                  builder: (context, snapshot) {
                    double total = (snapshot.data ?? 0).abs();
                    return SettingsContainer(
                      title: "total-spent-with-tag".tr(),
                      description: convertToMoney(
                        Provider.of<AllWallets>(context),
                        total,
                        finalNumber: total,
                      ),
                      icon: appStateSettings["outlinedIcons"]
                          ? Icons.receipt_long_outlined
                          : Icons.receipt_long_rounded,
                      isOutlined: true,
                      isWideOutlined: true,
                    );
                  },
                ),
              ),
            ),
          if (widget.tag != null &&
              widget.routesToPopAfterDelete !=
                  RoutesToPopAfterDelete.PreventDelete)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 24,
                  end: 24,
                  bottom: 10,
                ),
                child: SettingsContainer(
                  isOutlined: true,
                  onTap: () {
                    mergeTagPopup(
                      context,
                      tagOriginal: widget.tag!,
                      routesToPopAfterDelete: widget.routesToPopAfterDelete,
                    );
                  },
                  title: "merge-tag".tr(),
                  icon: appStateSettings["outlinedIcons"]
                      ? Icons.merge_outlined
                      : Icons.merge_rounded,
                  iconScale: 1,
                  isWideOutlined: true,
                ),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}
