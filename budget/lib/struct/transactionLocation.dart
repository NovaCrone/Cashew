import 'dart:io' show Platform, HttpClient;

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

class TransactionLocation {
  final double latitude;
  final double longitude;
  final String? name;
  const TransactionLocation(this.latitude, this.longitude, {this.name});

  TransactionLocation withName(String? name) =>
      TransactionLocation(latitude, longitude, name: name);

  String get coordinatesString =>
      "${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}";
}

bool get locationSupported =>
    !kIsWeb && (Platform.isIOS || Platform.isAndroid);

/// Returns true if location may be used. Requests permission only the very
/// first time; after a denial the user is never prompted again automatically.
Future<bool> _ensureLocationPermission({bool userInitiated = false}) async {
  if (!locationSupported) return false;
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) return true;
    if (permission == LocationPermission.deniedForever) return false;
    // permission == denied (or unableToDetermine)
    bool alreadyAsked = appStateSettings["locationPermissionAsked"] == true;
    if (alreadyAsked && !userInitiated) return false;
    await updateSettings("locationPermissionAsked", true,
        updateGlobalState: false);
    permission = await Geolocator.requestPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  } catch (e) {
    print("Location permission error: " + e.toString());
    return false;
  }
}

/// Gets the current GPS coordinates. GPS works without network.
/// Returns null if permission denied / unavailable.
Future<TransactionLocation?> getCurrentTransactionLocation(
    {bool userInitiated = false}) async {
  if (!await _ensureLocationPermission(userInitiated: userInitiated))
    return null;
  try {
    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (_) {
      position = await Geolocator.getLastKnownPosition();
    }
    if (position == null) return null;
    return TransactionLocation(position.latitude, position.longitude);
  } catch (e) {
    print("Location error: " + e.toString());
    return null;
  }
}

/// Reverse geocodes using the OS's built-in geocoder (Apple / Google Play
/// services). A single tiny request; returns null when offline.
Future<String?> reverseGeocodeLocation(double lat, double lng) async {
  try {
    return await _reverseGeocodeOrThrow(lat, lng);
  } catch (e) {
    print("Reverse geocode failed (likely offline): " + e.toString());
    return null;
  }
}

// Throws when the lookup fails (e.g. no connection)
Future<String?> _reverseGeocodeOrThrow(double lat, double lng) async {
  if (!locationSupported) return null;
  {
    List<Placemark> placemarks = await Geocoding().placemarkFromCoordinates(lat, lng)
        .timeout(const Duration(seconds: 8));
    if (placemarks.isEmpty) return null;
    Placemark p = placemarks.first;
    List<String> parts = [
      if ((p.name ?? "").trim().isNotEmpty &&
          p.name != p.street &&
          int.tryParse(p.name!.trim()) == null)
        p.name!.trim(),
      if ((p.subLocality ?? "").trim().isNotEmpty) p.subLocality!.trim(),
      if ((p.locality ?? "").trim().isNotEmpty) p.locality!.trim(),
    ];
    // Remove duplicates while keeping order
    List<String> unique = [];
    for (String part in parts) {
      if (!unique.contains(part)) unique.add(part);
    }
    if (unique.isEmpty && (p.country ?? "").isNotEmpty) unique.add(p.country!);
    return unique.isEmpty ? null : unique.take(3).join(", ");
  }
}


/// Opens the coordinates in the native maps app (no in-app map tiles).
Future<void> openLocationInMaps(TransactionLocation location) async {
  final String label = Uri.encodeComponent(location.name ?? "Transaction");
  final double lat = location.latitude;
  final double lng = location.longitude;
  final List<Uri> candidates = [
    if (!kIsWeb && Platform.isIOS)
      Uri.parse("https://maps.apple.com/?ll=$lat,$lng&q=$label"),
    if (!kIsWeb && Platform.isAndroid)
      Uri.parse("geo:$lat,$lng?q=$lat,$lng($label)"),
    Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lng"),
  ];
  for (Uri uri in candidates) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
  }
}

/// Extracts coordinates from text pasted from Apple Maps / Google Maps
/// (full links, short links, or plain "lat, lng").
/// Returns null if no coordinates could be found.
Future<TransactionLocation?> parseLocationFromPastedText(String input) async {
  String text = input.trim();
  if (text.isEmpty) return null;
  TransactionLocation? found = _findCoordinates(Uri.decodeFull(text));
  if (found != null) return found;
  // Short links (maps.app.goo.gl, goo.gl/maps, maps.apple/p/...) hide the
  // coordinates behind a redirect. Follow the redirects reading only the
  // headers - the page itself is never downloaded.
  RegExpMatch? urlMatch = RegExp(r'https?://\S+').firstMatch(text);
  if (urlMatch == null) return null;
  String? resolved = await _resolveRedirects(urlMatch.group(0)!);
  if (resolved == null) return null;
  return _findCoordinates(Uri.decodeFull(resolved));
}

TransactionLocation? _findCoordinates(String text) {
  const String num = r'(-?\d{1,3}(?:\.\d+)?)';
  List<RegExp> patterns = [
    RegExp(r'!3d' + num + r'!4d' + num), // Google place data (most precise)
    RegExp(r'@' + num + r',' + num), // Google /@lat,lng,zoom
    RegExp(r'[?&](?:ll|sll|q|query|daddr|destination|coordinate|center)=' +
        num +
        r',\s*' +
        num), // Apple & Google query params
    RegExp(r'geo:' + num + r',' + num),
    RegExp(r'^\s*' + num + r'\s*,\s*' + num + r'\s*$'), // plain "lat, lng"
  ];
  for (RegExp pattern in patterns) {
    RegExpMatch? m = pattern.firstMatch(text);
    if (m == null) continue;
    double? lat = double.tryParse(m.group(1)!);
    double? lng = double.tryParse(m.group(2)!);
    if (lat == null || lng == null) continue;
    if (lat.abs() > 90 || lng.abs() > 180) continue;
    if (lat == 0 && lng == 0) continue;
    return TransactionLocation(lat, lng);
  }
  return null;
}

Future<String?> _resolveRedirects(String url) async {
  if (kIsWeb) return null;
  HttpClient client = HttpClient()..connectionTimeout = Duration(seconds: 8);
  try {
    Uri current = Uri.parse(url);
    for (int i = 0; i < 6; i++) {
      final request = await client.headUrl(current);
      request.followRedirects = false;
      final response = await request.close();
      await response.drain();
      String? next = response.headers.value("location");
      if (next == null) return current.toString();
      current = current.resolve(next);
      if (_findCoordinates(Uri.decodeFull(current.toString())) != null)
        return current.toString();
    }
    return current.toString();
  } catch (e) {
    print("Could not resolve maps link: " + e.toString());
    return null;
  } finally {
    client.close(force: true);
  }
}

bool _resolvingPendingNames = false;
bool _lifecycleListenerAdded = false;

/// Fills in place names for transactions saved offline (coordinates but no
/// name). Runs when the app opens and whenever it returns to the foreground.
/// Skipped entirely unless something was saved without a name. Stops at the
/// first failed lookup (no connection) and tries again next time.
Future<void> resolvePendingLocationNames() async {
  if (!locationSupported) return;
  if (!_lifecycleListenerAdded) {
    _lifecycleListenerAdded = true;
    WidgetsBinding.instance.addObserver(_ResumeObserver());
  }
  // Nothing saved offline - skip the database query entirely
  if (appStateSettings["pendingLocationNames"] != true) return;
  if (_resolvingPendingNames) return;
  _resolvingPendingNames = true;
  try {
    List<Transaction> pending =
        await database.getTransactionsMissingLocationName(limit: 25);
    if (pending.isEmpty) {
      await updateSettings("pendingLocationNames", false,
          updateGlobalState: false);
    }
    for (int i = 0; i < pending.length; i++) {
      Transaction t = pending[i];
      String? name;
      try {
        name = await _reverseGeocodeOrThrow(t.latitude!, t.longitude!);
      } catch (e) {
        print("Pending location lookup stopped (offline?): " + e.toString());
        break;
      }
      // Empty result: store coordinates as the name so it is not retried forever
      await database.updateTransactionLocationName(
          t.transactionPk,
          name ??
              TransactionLocation(t.latitude!, t.longitude!)
                  .coordinatesString);
      // Stay well under the OS geocoder rate limits
      if (i < pending.length - 1) await Future.delayed(Duration(seconds: 1));
    }
  } catch (e) {
    print("Error resolving pending location names: " + e.toString());
  }
  _resolvingPendingNames = false;
}

class _ResumeObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) resolvePendingLocationNames();
  }
}
