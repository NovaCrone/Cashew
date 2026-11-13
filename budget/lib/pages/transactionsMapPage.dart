import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/transactionFilters.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/categoryIcon.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/transactionsMap/nativeMap.dart';
import 'package:budget/widgets/util/showDatePicker.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Shows located transactions as pins on a native map.
/// Pins close together are grouped into clusters showing a count.
class TransactionsMapPage extends StatefulWidget {
  const TransactionsMapPage({super.key, this.initialFilters});
  final SearchFilters? initialFilters;

  @override
  State<TransactionsMapPage> createState() => _TransactionsMapPageState();
}

class _MapCluster {
  final String id;
  final List<TransactionWithCategory> items;
  final double latitude;
  final double longitude;
  _MapCluster(this.id, this.items, this.latitude, this.longitude);
  bool get isSingle => items.length == 1;
}

class _TransactionsMapPageState extends State<TransactionsMapPage> {
  late SearchFilters filters = widget.initialFilters?.copyWith() ??
      SearchFilters(
        dateTimeRange: DateTimeRange(
          start: DateTime.now().subtract(Duration(days: 30)).justDay(),
          end: DateTime.now().justDay(dayOffset: 1),
        ),
      );

  static const int _maxPins = 5000;
  // Grid cell size in logical pixels used to group nearby pins
  static const double _clusterCellSize = 60;
  // Above this zoom, pins are never grouped (except at the exact same spot)
  static const double _maxClusterZoom = 18;

  List<TransactionWithCategory> items = [];
  bool loading = true;
  NativeMapController? controller;
  double zoom = 3;
  int? _clusteredAtZoom;
  List<_MapCluster> clusters = [];
  Set<NativeMapPin> pins = {};
  _MapCluster? selected;
  bool _fittedInitially = false;
  final Map<String, Uint8List> _iconCache = {};

  @override
  void initState() {
    super.initState();
    loadTransactions();
  }

  Future<void> loadTransactions() async {
    setState(() => loading = true);
    List<TransactionWithCategory> result =
        await database.getTransactionsForMap(filters, limit: _maxPins);
    if (!mounted) return;
    items = result;
    selected = null;
    loading = false;
    _clusteredAtZoom = null;
    await rebuildClusters();
    fitToPins();
  }

  void fitToPins() {
    if (controller == null || items.isEmpty) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final item in items) {
      minLat = math.min(minLat, item.transaction.latitude!);
      maxLat = math.max(maxLat, item.transaction.latitude!);
      minLng = math.min(minLng, item.transaction.longitude!);
      maxLng = math.max(maxLng, item.transaction.longitude!);
    }
    _fittedInitially = true;
    if ((maxLat - minLat).abs() < 0.002 && (maxLng - minLng).abs() < 0.002) {
      controller!.moveTo((minLat + maxLat) / 2, (minLng + maxLng) / 2, 15);
    } else {
      controller!.fitBounds(minLat, minLng, maxLat, maxLng, 60);
    }
  }

  // Web Mercator projection to world pixels at the given zoom
  math.Point<double> _project(double lat, double lng, double zoom) {
    final double scale = 256 * math.pow(2, zoom).toDouble();
    final double x = (lng + 180) / 360 * scale;
    final double sinLat =
        math.sin(lat.clamp(-85.0511, 85.0511) * math.pi / 180);
    final double y =
        (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale;
    return math.Point(x, y);
  }

  /// Groups pins into a grid of [_clusterCellSize] pixels at the current zoom.
  /// Runs on the already loaded list - no database access.
  Future<void> rebuildClusters() async {
    int zoomLevel = zoom.floor();
    if (_clusteredAtZoom == zoomLevel && clusters.isNotEmpty) return;
    _clusteredAtZoom = zoomLevel;

    Map<String, List<TransactionWithCategory>> cells = {};
    for (final item in items) {
      final double lat = item.transaction.latitude!;
      final double lng = item.transaction.longitude!;
      String key;
      if (zoomLevel >= _maxClusterZoom) {
        // Only group transactions at (almost) the exact same spot
        key = "${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}";
      } else {
        final p = _project(lat, lng, zoomLevel.toDouble());
        key =
            "${(p.x / _clusterCellSize).floor()},${(p.y / _clusterCellSize).floor()}";
      }
      (cells[key] ??= []).add(item);
    }

    List<_MapCluster> newClusters = [];
    cells.forEach((key, group) {
      double lat = 0, lng = 0;
      for (final item in group) {
        lat += item.transaction.latitude!;
        lng += item.transaction.longitude!;
      }
      String id = group.length == 1
          ? "t:" + group.first.transaction.transactionPk
          : "c:" + zoomLevel.toString() + ":" + key;
      newClusters.add(_MapCluster(
          id, group, lat / group.length, lng / group.length));
    });

    final double pixelRatio = MediaQuery.of(context).devicePixelRatio;
    Set<NativeMapPin> newPins = {};
    for (final cluster in newClusters) {
      Uint8List icon = await _iconFor(cluster, pixelRatio);
      newPins.add(NativeMapPin(
        id: cluster.id,
        latitude: cluster.latitude,
        longitude: cluster.longitude,
        icon: icon,
        iconPixelRatio: pixelRatio,
        zIndex: cluster.items.length,
        // The pin's tip sits on the exact spot; clusters are centred
        anchor: cluster.isSingle ? Offset(0.5, 1.0) : Offset(0.5, 0.5),
      ));
    }
    if (!mounted) return;
    setState(() {
      clusters = newClusters;
      pins = newPins;
    });
  }

  Future<Uint8List> _iconFor(_MapCluster cluster, double pixelRatio) async {
    if (cluster.isSingle) {
      final Color color = HexColor(cluster.items.first.category.colour,
          defaultColor: Theme.of(context).colorScheme.primary);
      final String key = "single:${color.value}";
      return _iconCache[key] ??=
          await _renderTeardropPin(color: color, pixelRatio: pixelRatio);
    }
    final int count = cluster.items.length;
    final String label = count > 999 ? "999+" : count.toString();
    final double diameter = count < 10
        ? 34
        : count < 100
            ? 40
            : 48;
    final Color color = Theme.of(context).colorScheme.primary;
    final String key = "cluster:$label:${color.value}";
    return _iconCache[key] ??= await _renderPin(
        color: color, pixelRatio: pixelRatio, diameter: diameter, label: label);
  }

  /// Classic map pin: a round head that narrows to a point at the bottom.
  /// The tip (bottom centre of the image) marks the transaction location.
  Future<Uint8List> _renderTeardropPin({
    required Color color,
    required double pixelRatio,
  }) async {
    const double width = 30; // logical pixels
    const double height = 40;
    const double shadowPad = 3;
    final double w = (width + shadowPad * 2) * pixelRatio;
    final double h = (height + shadowPad) * pixelRatio;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    Path pinPath(double inset) {
      final double r = (width / 2 - inset) * pixelRatio;
      final double cx = w / 2;
      final double cy = (shadowPad + width / 2) * pixelRatio;
      final double tipY = h - (shadowPad + inset * 1.6) * pixelRatio;
      // Tangent points where the straight sides leave the circle
      final double d = tipY - cy;
      final double angle = math.asin((r / d).clamp(-1.0, 1.0));
      final double tx = r * math.cos(angle);
      final double ty = r * math.sin(angle);
      return Path()
        ..moveTo(cx, tipY)
        ..lineTo(cx - tx, cy + ty)
        ..arcToPoint(Offset(cx + tx, cy + ty),
            radius: Radius.circular(r), largeArc: true)
        ..close();
    }

    // Soft shadow
    canvas.drawPath(
      pinPath(0).shift(Offset(0, 1.5 * pixelRatio)),
      Paint()
        ..color = Colors.black.withOpacity(0.3)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * pixelRatio),
    );
    // White outline, then the category colour
    canvas.drawPath(pinPath(0), Paint()..color = Colors.white);
    canvas.drawPath(pinPath(2.5), Paint()..color = color);
    // White dot in the head
    canvas.drawCircle(
      Offset(w / 2, (shadowPad + width / 2) * pixelRatio),
      width * 0.17 * pixelRatio,
      Paint()..color = Colors.white,
    );

    final ui.Image image =
        await recorder.endRecording().toImage(w.ceil(), h.ceil());
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> _renderPin({
    required Color color,
    required double pixelRatio,
    required double diameter,
    required String? label,
  }) async {
    final double size = (diameter + 6) * pixelRatio;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Offset center = Offset(size / 2, size / 2);
    final double radius = diameter / 2 * pixelRatio;
    canvas.drawCircle(
      center.translate(0, 1 * pixelRatio),
      radius,
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * pixelRatio),
    );
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);
    canvas.drawCircle(
        center, radius - 2.5 * pixelRatio, Paint()..color = color);
    if (label != null) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: (label.length > 2 ? 12 : 14) * pixelRatio,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      painter.paint(canvas,
          center - Offset(painter.width / 2, painter.height / 2));
    } else {
      canvas.drawCircle(
          center, radius * 0.32, Paint()..color = Colors.white.withOpacity(0.9));
    }
    final ui.Image image = await recorder
        .endRecording()
        .toImage(size.ceil(), size.ceil());
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  void onPinTap(String pinId) {
    _MapCluster? cluster;
    for (final c in clusters) {
      if (c.id == pinId) {
        cluster = c;
        break;
      }
    }
    if (cluster == null) return;
    if (cluster.isSingle || zoom >= _maxClusterZoom || _allSameSpot(cluster)) {
      setState(() => selected = cluster);
      return;
    }
    // Zoom into the cluster so its pins separate
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final item in cluster.items) {
      minLat = math.min(minLat, item.transaction.latitude!);
      maxLat = math.max(maxLat, item.transaction.latitude!);
      minLng = math.min(minLng, item.transaction.longitude!);
      maxLng = math.max(maxLng, item.transaction.longitude!);
    }
    controller?.fitBounds(minLat, minLng, maxLat, maxLng, 80);
  }

  bool _allSameSpot(_MapCluster cluster) {
    final first = cluster.items.first.transaction;
    return cluster.items.every((item) =>
        (item.transaction.latitude! - first.latitude!).abs() < 0.0001 &&
        (item.transaction.longitude! - first.longitude!).abs() < 0.0001);
  }

  Future<void> selectDateRange() async {
    final DateTimeRangeOrAllTime? picked = await showCustomDateRangePicker(
      context,
      DateTimeRangeOrAllTime(
        allTime: filters.dateTimeRange == null,
        dateTimeRange: filters.dateTimeRange,
      ),
      initialEntryMode: DatePickerEntryMode.input,
      allTimeButton: true,
    );
    if (picked == null) return;
    filters.dateTimeRange = picked.dateTimeRange;
    _fittedInitially = false;
    loadTransactions();
  }

  Future<void> openTransaction(Transaction transaction) async {
    await pushRoute(
      context,
      AddTransactionPage(
        transaction: transaction,
        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
      ),
    );
    // Pick up edits / deletes
    if (mounted) loadTransactions();
  }

  String get dateRangeLabel {
    final DateTimeRange? range = filters.dateTimeRange;
    if (range == null) return "all-time".tr();
    return getWordedDateShort(range.start, includeYear: true) +
        " – " +
        getWordedDateShort(range.end, includeYear: true);
  }

  @override
  Widget build(BuildContext context) {
    final double initialLat =
        items.isNotEmpty ? items.first.transaction.latitude! : 20;
    final double initialLng =
        items.isNotEmpty ? items.first.transaction.longitude! : 0;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: NativeMap(
              pins: pins,
              initialLatitude: initialLat,
              initialLongitude: initialLng,
              initialZoom: items.isNotEmpty ? 12 : 2,
              onMapCreated: (c) {
                controller = c;
                if (!_fittedInitially) fitToPins();
              },
              onCameraIdle: (newZoom) {
                zoom = newZoom;
                rebuildClusters();
              },
              onPinTap: onPinTap,
              onMapTap: () {
                if (selected != null) setState(() => selected = null);
              },
            ),
          ),
          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    ButtonIcon(
                      onTap: () => popRoute(context),
                      icon: appStateSettings["outlinedIcons"]
                          ? Icons.arrow_back_outlined
                          : Icons.arrow_back_rounded,
                      color: Theme.of(context).colorScheme.surface,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Tappable(
                        onTap: selectDateRange,
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: 15,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.symmetric(
                              horizontal: 14, vertical: 9),
                          child: Row(
                            children: [
                              Icon(
                                appStateSettings["outlinedIcons"]
                                    ? Icons.calendar_month_outlined
                                    : Icons.calendar_month_rounded,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextFont(
                                      text: dateRangeLabel,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      maxLines: 1,
                                    ),
                                    TextFont(
                                      text: loading
                                          ? "loading".tr()
                                          : items.length.toString() +
                                              " " +
                                              (items.length == 1
                                                  ? "transaction".tr()
                                                  : "transactions".tr())
                                                  .toLowerCase() +
                                              (items.length >= _maxPins
                                                  ? " (" +
                                                      "most-recent".tr() +
                                                      ")"
                                                  : ""),
                                      fontSize: 12,
                                      textColor:
                                          getColor(context, "textLight"),
                                      maxLines: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!loading && items.isEmpty)
            Center(
              child: Container(
                margin: EdgeInsetsDirectional.symmetric(horizontal: 40),
                padding: EdgeInsetsDirectional.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: TextFont(
                  text: "no-located-transactions".tr(),
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  fontSize: 15,
                ),
              ),
            ),
          // Selected transaction(s)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: 200),
                child: selected == null
                    ? SizedBox.shrink()
                    : Padding(
                        key: ValueKey(selected!.id),
                        padding: const EdgeInsetsDirectional.all(12),
                        child: _SelectedTransactions(
                          cluster: selected!,
                          onOpen: openTransaction,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedTransactions extends StatelessWidget {
  const _SelectedTransactions({required this.cluster, required this.onOpen});
  final _MapCluster cluster;
  final void Function(Transaction transaction) onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 12,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsetsDirectional.symmetric(vertical: 6),
          children: [
            if (!cluster.isSingle)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                    start: 16, end: 16, top: 6, bottom: 2),
                child: TextFont(
                  text: cluster.items.first.transaction.locationName ??
                      (cluster.items.length.toString() +
                          " " +
                          "transactions".tr().toLowerCase()),
                  fontSize: 13,
                  textColor: getColor(context, "textLight"),
                  maxLines: 1,
                ),
              ),
            for (final item in cluster.items)
              _MapTransactionRow(item: item, onOpen: onOpen),
          ],
        ),
      ),
    );
  }
}

class _MapTransactionRow extends StatelessWidget {
  const _MapTransactionRow({required this.item, required this.onOpen});
  final TransactionWithCategory item;
  final void Function(Transaction transaction) onOpen;

  @override
  Widget build(BuildContext context) {
    final Transaction transaction = item.transaction;
    final AllWallets allWallets = Provider.of<AllWallets>(context);
    final String amount = convertToMoney(
      allWallets,
      transaction.amount.abs(),
      currencyKey: allWallets.indexedByPk[transaction.walletFk]?.currency,
    );
    final String title =
        transaction.name.trim().isNotEmpty ? transaction.name : item.category.name;
    return Tappable(
      onTap: () => onOpen(transaction),
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
            horizontal: 12, vertical: 8),
        child: Row(
          children: [
            CategoryIcon(
              categoryPk: item.category.categoryPk,
              category: item.category,
              size: 26,
              sizePadding: 14,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFont(
                    text: title,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    maxLines: 1,
                  ),
                  TextFont(
                    text: getWordedDateShort(transaction.dateCreated,
                            includeYear: true) +
                        (transaction.locationName != null
                            ? " • " + transaction.locationName!
                            : ""),
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            SizedBox(width: 8),
            TextFont(
              text: (transaction.income ? "+" : "−") + amount,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              textColor: transaction.income
                  ? getColor(context, "incomeAmount")
                  : getColor(context, "expenseAmount"),
            ),
            Icon(Icons.chevron_right_rounded,
                color: getColor(context, "textLight")),
          ],
        ),
      ),
    );
  }
}
