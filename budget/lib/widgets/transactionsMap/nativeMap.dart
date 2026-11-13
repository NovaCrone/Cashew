import 'dart:async';
import 'dart:io' show Platform;

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as apple;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as google;

/// A pin to show on the map. [icon] is a PNG rendered at [iconPixelRatio].
class NativeMapPin {
  final String id;
  final double latitude;
  final double longitude;
  final Uint8List icon;
  final double iconPixelRatio;
  final int zIndex;
  // Point of the icon placed on the coordinates (0.5, 1.0 = bottom centre)
  final Offset anchor;
  const NativeMapPin({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.icon,
    required this.iconPixelRatio,
    this.zIndex = 0,
    this.anchor = const Offset(0.5, 0.5),
  });
}

/// Platform independent controller for the map.
abstract class NativeMapController {
  Future<void> fitBounds(double minLat, double minLng, double maxLat,
      double maxLng, double padding);
  Future<void> moveTo(double latitude, double longitude, double zoom);
}

bool get nativeMapSupported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

/// iPhone: Apple MapKit (part of iOS - no extra app size, no API key)
/// Android: Google Maps (via Google Play services)
class NativeMap extends StatelessWidget {
  const NativeMap({
    super.key,
    required this.pins,
    required this.initialLatitude,
    required this.initialLongitude,
    required this.initialZoom,
    required this.onPinTap,
    required this.onCameraIdle,
    required this.onMapCreated,
    this.onMapTap,
  });

  final Set<NativeMapPin> pins;
  final double initialLatitude;
  final double initialLongitude;
  final double initialZoom;
  final void Function(String pinId) onPinTap;
  final void Function(double zoom) onCameraIdle;
  final void Function(NativeMapController controller) onMapCreated;
  final VoidCallback? onMapTap;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && Platform.isIOS) return _AppleNativeMap(widget: this);
    if (!kIsWeb && Platform.isAndroid) return _GoogleNativeMap(widget: this);
    return SizedBox.shrink();
  }
}

// ---------------------------------------------------------------------------
// iOS - Apple MapKit
// ---------------------------------------------------------------------------

class _AppleNativeMap extends StatefulWidget {
  const _AppleNativeMap({required this.widget});
  final NativeMap widget;
  @override
  State<_AppleNativeMap> createState() => _AppleNativeMapState();
}

class _AppleNativeMapState extends State<_AppleNativeMap>
    implements NativeMapController {
  apple.AppleMapController? _controller;
  late double _zoom = widget.widget.initialZoom;

  @override
  Future<void> fitBounds(double minLat, double minLng, double maxLat,
      double maxLng, double padding) async {
    await _controller?.animateCamera(apple.CameraUpdate.newLatLngBounds(
      apple.LatLngBounds(
        southwest: apple.LatLng(minLat, minLng),
        northeast: apple.LatLng(maxLat, maxLng),
      ),
      padding,
    ));
  }

  @override
  Future<void> moveTo(double latitude, double longitude, double zoom) async {
    await _controller?.animateCamera(apple.CameraUpdate.newLatLngZoom(
        apple.LatLng(latitude, longitude), zoom));
  }

  @override
  Widget build(BuildContext context) {
    final NativeMap w = widget.widget;
    return apple.AppleMap(
      initialCameraPosition: apple.CameraPosition(
        target: apple.LatLng(w.initialLatitude, w.initialLongitude),
        zoom: w.initialZoom,
      ),
      compassEnabled: true,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      rotateGesturesEnabled: false,
      pitchGesturesEnabled: false,
      annotations: w.pins
          .map((pin) => apple.Annotation(
                annotationId: apple.AnnotationId(pin.id),
                position: apple.LatLng(pin.latitude, pin.longitude),
                icon: apple.BitmapDescriptor.fromBytes(pin.icon),
                anchor: pin.anchor,
                zIndex: pin.zIndex.toDouble(),
                onTap: () => w.onPinTap(pin.id),
              ))
          .toSet(),
      onMapCreated: (controller) {
        _controller = controller;
        w.onMapCreated(this);
      },
      onCameraMove: (position) => _zoom = position.zoom,
      onCameraIdle: () => w.onCameraIdle(_zoom),
      onTap: (_) => w.onMapTap?.call(),
    );
  }
}

// ---------------------------------------------------------------------------
// Android - Google Maps (Android implementation only, so nothing from
// Google's map SDK is bundled into the iOS app)
// ---------------------------------------------------------------------------

int _nextGoogleMapId = 0;

class _GoogleNativeMap extends StatefulWidget {
  const _GoogleNativeMap({required this.widget});
  final NativeMap widget;
  @override
  State<_GoogleNativeMap> createState() => _GoogleNativeMapState();
}

class _GoogleNativeMapState extends State<_GoogleNativeMap>
    implements NativeMapController {
  final int _creationId = _nextGoogleMapId++;
  int? _mapId;
  late double _zoom = widget.widget.initialZoom;
  Set<google.Marker> _markers = {};
  // Markers sent with the platform view creation params
  Set<google.Marker> _creationMarkers = {};
  final List<StreamSubscription> _subscriptions = [];

  google.GoogleMapsFlutterPlatform get _platform =>
      google.GoogleMapsFlutterPlatform.instance;

  static const google.MapConfiguration _configuration = google.MapConfiguration(
    compassEnabled: true,
    mapToolbarEnabled: false,
    myLocationEnabled: false,
    myLocationButtonEnabled: false,
    zoomControlsEnabled: false,
    rotateGesturesEnabled: false,
    tiltGesturesEnabled: false,
    indoorViewEnabled: false,
    trafficEnabled: false,
    buildingsEnabled: true,
  );

  Set<google.Marker> _buildMarkers(Set<NativeMapPin> pins) {
    return pins
        .map((pin) => google.Marker(
              markerId: google.MarkerId(pin.id),
              position: google.LatLng(pin.latitude, pin.longitude),
              icon: google.BitmapDescriptor.bytes(pin.icon,
                  imagePixelRatio: pin.iconPixelRatio),
              anchor: pin.anchor,
              zIndexInt: pin.zIndex,
              consumeTapEvents: true,
            ))
        .toSet();
  }

  @override
  void initState() {
    super.initState();
    _markers = _buildMarkers(widget.widget.pins);
    _creationMarkers = _markers;
  }

  @override
  void didUpdateWidget(covariant _GoogleNativeMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<google.Marker> newMarkers = _buildMarkers(widget.widget.pins);
    if (_mapId != null) {
      _platform.updateMarkers(
          google.MarkerUpdates.from(_markers, newMarkers),
          mapId: _mapId!);
    }
    _markers = newMarkers;
  }

  Future<void> _onPlatformViewCreated(int id) async {
    await _platform.init(id);
    if (!mounted) return;
    _mapId = id;
    _subscriptions.addAll([
      _platform
          .onMarkerTap(mapId: id)
          .listen((event) => widget.widget.onPinTap(event.value.value)),
      _platform
          .onCameraMove(mapId: id)
          .listen((event) => _zoom = event.value.zoom),
      _platform
          .onCameraIdle(mapId: id)
          .listen((_) => widget.widget.onCameraIdle(_zoom)),
      _platform.onTap(mapId: id).listen((_) => widget.widget.onMapTap?.call()),
    ]);
    // Markers may have changed while the view was being created
    if (_creationMarkers != _markers) {
      await _platform.updateMarkers(
          google.MarkerUpdates.from(_creationMarkers, _markers),
          mapId: id);
    }
    widget.widget.onMapCreated(this);
  }

  @override
  Future<void> fitBounds(double minLat, double minLng, double maxLat,
      double maxLng, double padding) async {
    if (_mapId == null) return;
    await _platform.animateCamera(
      google.CameraUpdate.newLatLngBounds(
        google.LatLngBounds(
          southwest: google.LatLng(minLat, minLng),
          northeast: google.LatLng(maxLat, maxLng),
        ),
        padding,
      ),
      mapId: _mapId!,
    );
  }

  @override
  Future<void> moveTo(double latitude, double longitude, double zoom) async {
    if (_mapId == null) return;
    await _platform.animateCamera(
      google.CameraUpdate.newLatLngZoom(google.LatLng(latitude, longitude), zoom),
      mapId: _mapId!,
    );
  }

  @override
  void dispose() {
    for (final s in _subscriptions) s.cancel();
    if (_mapId != null) _platform.dispose(mapId: _mapId!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NativeMap w = widget.widget;
    return _platform.buildViewWithConfiguration(
      _creationId,
      _onPlatformViewCreated,
      widgetConfiguration: google.MapWidgetConfiguration(
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        initialCameraPosition: google.CameraPosition(
          target: google.LatLng(w.initialLatitude, w.initialLongitude),
          zoom: w.initialZoom,
        ),
      ),
      mapObjects: google.MapObjects(markers: _markers),
      mapConfiguration: _configuration,
    );
  }
}
