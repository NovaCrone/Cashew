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

/// Extracts a location from text pasted from Apple Maps / Google Maps
/// (full links, short links, shared text, or plain "lat, lng").
/// Returns null if no location could be found.
///
/// Steps, cheapest first:
/// 1. Coordinates written in the pasted text/link (no network)
/// 2. Short links: follow redirects reading only headers, then look again
/// 3. Google place links without coordinates (place name + internal id):
///    look up the place name with the phone's built-in geocoder
/// 4. Last resort: read the start of the page (max 64 KB) for coordinates
Future<TransactionLocation?> parseLocationFromPastedText(String input) async {
  String text = input.trim();
  if (text.isEmpty) return null;
  TransactionLocation? found = _findCoordinates(_normalize(text));
  if (found != null) return found;

  RegExpMatch? urlMatch = RegExp(r'https?://\S+').firstMatch(text);
  String? finalUrl;
  if (urlMatch != null) {
    finalUrl = await _resolveRedirects(urlMatch.group(0)!);
    if (finalUrl != null) {
      found = _findCoordinates(_normalize(finalUrl));
      if (found != null) return found;
    }
  }

  // Place name from the link, or the text shared along with the link
  // (Google Maps "Share" often sends "Name, Address https://maps.app...")
  List<String> placeQueries = [
    if (finalUrl != null) ..._placeNamesFromUrl(finalUrl),
    if (urlMatch != null)
      text.replaceAll(urlMatch.group(0)!, " ").replaceAll(RegExp(r'\s+'), " ").trim(),
  ].where((q) => q.length >= 3).toList();
  for (String query in placeQueries) {
    TransactionLocation? byName = await _geocodePlaceName(query);
    if (byName != null) return byName;
  }

  if (finalUrl != null) {
    String? page = await _readPageStart(finalUrl);
    if (page != null) {
      found = _findCoordinates(_normalize(page));
      if (found != null) return found;
    }
  }
  return null;
}

String _normalize(String text) {
  String decoded = text;
  try {
    decoded = Uri.decodeFull(text);
  } catch (_) {}
  // Google writes spaces as "+" (e.g. /search/13.08,+80.27)
  return decoded.replaceAll("+", " ");
}

TransactionLocation? _findCoordinates(String text) {
  const String num = r'(-?\d{1,3}(?:\.\d+)?)';
  const String sep = r'\s*,\s*';
  List<RegExp> patterns = [
    RegExp(r'!3d' + num + r'!4d' + num), // Google place data (most precise)
    RegExp(r'@' + num + sep + num), // Google /@lat,lng,zoom
    RegExp(r'/(?:search|place|dir)/' + num + sep + num), // Google dropped pin
    RegExp(r'[?&](?:ll|sll|q|query|daddr|destination|coordinate|center)=' +
        num +
        sep +
        num), // Apple & Google query params
    RegExp(r'geo:' + num + sep + num),
    RegExp(r'^\s*' + num + sep + num + r'\s*$'), // plain "lat, lng"
    // Coordinates embedded in a Google page, e.g. "center=13.08%2C80.27"
    RegExp(r'\[\s*null\s*,\s*null\s*,\s*' + num + sep + num + r'\s*\]'),
  ];
  for (RegExp pattern in patterns) {
    for (RegExpMatch m in pattern.allMatches(text)) {
      double? lat = double.tryParse(m.group(1)!);
      double? lng = double.tryParse(m.group(2)!);
      if (lat == null || lng == null) continue;
      if (lat.abs() > 90 || lng.abs() > 180) continue;
      if (lat == 0 && lng == 0) continue;
      // Require some precision so "1,2" in random text is not a location
      if (!m.group(1)!.contains(".") || !m.group(2)!.contains(".")) continue;
      return TransactionLocation(lat, lng);
    }
  }
  return null;
}

/// Place names in Google links: /maps/place/<name>/... or ?q=<name>
List<String> _placeNamesFromUrl(String url) {
  List<String> out = [];
  Uri? uri = Uri.tryParse(url);
  if (uri == null) return out;
  int placeIndex = uri.pathSegments.indexOf("place");
  if (placeIndex != -1 && placeIndex + 1 < uri.pathSegments.length) {
    out.add(uri.pathSegments[placeIndex + 1]);
  }
  for (String key in ["q", "query", "daddr", "destination"]) {
    String? value = uri.queryParameters[key];
    if (value != null) out.add(value);
  }
  return out
      .map((q) => q.replaceAll("+", " ").trim())
      .where((q) => q.isNotEmpty)
      .toList();
}

Future<TransactionLocation?> _geocodePlaceName(String query) async {
  if (!locationSupported) return null;
  try {
    List<Location> results = await Geocoding()
        .locationFromAddress(query)
        .timeout(const Duration(seconds: 8));
    if (results.isEmpty) return null;
    String name = query.split(",").first.trim();
    return TransactionLocation(results.first.latitude, results.first.longitude,
        name: name.isEmpty ? null : name);
  } catch (e) {
    print("Could not geocode place name: " + e.toString());
    return null;
  }
}

const String _browserUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

/// Follows redirects reading only response headers (no page download).
Future<String?> _resolveRedirects(String url) async {
  if (kIsWeb) return null;
  HttpClient client = HttpClient()
    ..connectionTimeout = Duration(seconds: 8)
    ..userAgent = _browserUserAgent;
  try {
    Uri current = Uri.parse(url);
    for (int i = 0; i < 8; i++) {
      String? next;
      // Some servers reject HEAD - fall back to GET, still reading headers only
      for (String method in ["HEAD", "GET"]) {
        final request = await client.openUrl(method, current);
        request.followRedirects = false;
        final response = await request.close();
        final int status = response.statusCode;
        next = response.headers.value("location");
        // Discard any body without downloading it
        if (method == "HEAD") {
          await response.drain();
        } else {
          await response.listen(null).cancel();
        }
        if (next != null || (status >= 200 && status < 300)) break;
      }
      if (next == null) return current.toString();
      current = current.resolve(next);
      if (_findCoordinates(_normalize(current.toString())) != null)
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

/// Reads at most [maxBytes] of a page, used only when nothing else worked.
Future<String?> _readPageStart(String url, {int maxBytes = 64 * 1024}) async {
  if (kIsWeb) return null;
  HttpClient client = HttpClient()
    ..connectionTimeout = Duration(seconds: 8)
    ..userAgent = _browserUserAgent;
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    List<int> bytes = [];
    await for (List<int> chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) break;
    }
    return String.fromCharCodes(bytes.take(maxBytes));
  } catch (e) {
    print("Could not read maps page: " + e.toString());
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
