/// Native-client authentication for KernSifter.
///
/// Implements RFC 8628 device authorization against the `kernsifter-sync`
/// Worker, then holds a KernSifter-issued per-user bearer token. Freebuff issues
/// identity; the Worker issues the machine credential. Protocol and rationale:
/// `kernsifter-sync/docs/DEVICE-AUTH.md`.
///
/// This library imports nothing but the Dart SDK on purpose. The HTTP client and
/// the token store are injected, so the flow is testable without a network or a
/// platform keystore, and the same code serves the mobile app and any other Dart
/// client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Why a device authorization failed. The server's RFC 8628 error codes, mapped
/// to something a UI can act on.
enum DeviceAuthFailure {
  /// The human pressed Deny. Nothing was shared; do not retry in a loop.
  accessDenied,

  /// The code timed out before it was approved. Offer to start again.
  expired,

  /// Unknown or already-redeemed code. Start a new authorization.
  invalidGrant,

  /// Could not reach the Worker.
  network,

  /// The Worker answered with something this client does not understand.
  malformed,
}

/// Thrown for every non-retryable outcome, so callers never have to parse
/// strings to find out what happened.
class DeviceAuthException implements Exception {
  DeviceAuthException(this.reason, this.message);

  final DeviceAuthFailure reason;
  final String message;

  @override
  String toString() => 'DeviceAuthException(${reason.name}): $message';
}

/// One device authorization, as returned by `POST /api/device/authorize`.
class DeviceAuthorization {
  const DeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });

  /// Secret. The only thing that redeems the approval; never log it.
  final String deviceCode;

  /// The short code the human reads and types on the consent page.
  final String userCode;

  /// Where the human approves, without the code prefilled.
  final Uri verificationUri;

  /// Where the human approves, with the code prefilled. Prefer opening this.
  final Uri verificationUriComplete;

  final Duration expiresIn;

  /// The minimum polling interval. The server widens it on `slow_down`.
  final Duration interval;
}

/// Where a bearer token is kept between launches.
///
/// The mobile app supplies a keystore-backed implementation; tests supply an
/// in-memory one.
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// An in-memory store. Useful for tests and for a deliberately non-persistent
/// session; not a substitute for the keystore in a shipped app.
class InMemoryTokenStore implements TokenStore {
  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}

/// A JSON response with its status.
class _Reply {
  const _Reply(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

/// Talks to the sync Worker: device authorization, token custody, sync calls.
class DeviceAuthClient {
  DeviceAuthClient({
    required this.origin,
    required this.store,
    this.clientName = 'KernSifter',
    HttpClient? httpClient,
    Future<void> Function(Duration)? sleep,
  })  : _http = httpClient ?? HttpClient(),
        _sleep = sleep ?? Future<void>.delayed;

  /// Canonical origin of the Worker, e.g. `Uri.parse('https://sync.example')`.
  final Uri origin;

  final TokenStore store;

  /// Shown to the human on the consent page, so keep it recognisable.
  final String clientName;

  final HttpClient _http;
  final Future<void> Function(Duration) _sleep;

  Uri _endpoint(String path) => origin.replace(path: path);

  Future<_Reply> _send(String method, Uri url, {Map<String, Object?>? body, String? bearer}) async {
    try {
      final request = await _http.openUrl(method, url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (text.isEmpty) return _Reply(response.statusCode, const <String, dynamic>{});
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw DeviceAuthException(DeviceAuthFailure.malformed, 'expected a JSON object, got ${decoded.runtimeType}');
      }
      return _Reply(response.statusCode, decoded);
    } on DeviceAuthException {
      rethrow;
    } on IOException catch (error) {
      throw DeviceAuthException(DeviceAuthFailure.network, 'could not reach $origin: $error');
    } on FormatException catch (error) {
      throw DeviceAuthException(DeviceAuthFailure.malformed, 'invalid JSON: $error');
    }
  }

  /// Start an authorization. Step 1 of the flow.
  Future<DeviceAuthorization> start() async {
    final reply = await _send('POST', _endpoint('/api/device/authorize'), body: {'client_name': clientName});
    if (reply.status != 200) {
      throw DeviceAuthException(DeviceAuthFailure.malformed, 'authorize returned ${reply.status}');
    }
    final body = reply.body;
    final deviceCode = body['device_code'];
    final userCode = body['user_code'];
    final verificationUri = body['verification_uri'];
    final complete = body['verification_uri_complete'];
    if (deviceCode is! String || userCode is! String || verificationUri is! String || complete is! String) {
      throw DeviceAuthException(DeviceAuthFailure.malformed, 'authorize response was missing fields');
    }
    return DeviceAuthorization(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: Uri.parse(verificationUri),
      verificationUriComplete: Uri.parse(complete),
      expiresIn: Duration(seconds: (body['expires_in'] as num?)?.toInt() ?? 600),
      interval: Duration(seconds: (body['interval'] as num?)?.toInt() ?? 5),
    );
  }

  /// Poll until the human approves, the code expires, or the caller cancels.
  ///
  /// Returns the bearer token. Honours `slow_down` by widening the interval, and
  /// stops at the authorization's own deadline rather than polling forever.
  Future<String> poll(
    DeviceAuthorization authorization, {
    bool Function()? isCancelled,
    void Function(Duration remaining)? onTick,
  }) async {
    var interval = authorization.interval;
    final deadline = DateTime.now().add(authorization.expiresIn);

    while (true) {
      if (isCancelled?.call() ?? false) {
        throw DeviceAuthException(DeviceAuthFailure.invalidGrant, 'cancelled');
      }

      final reply = await _send(
        'POST',
        _endpoint('/api/device/token'),
        body: {'device_code': authorization.deviceCode},
      );

      if (reply.status == 200) {
        final token = reply.body['access_token'];
        if (token is! String || token.isEmpty) {
          throw DeviceAuthException(DeviceAuthFailure.malformed, 'token response carried no access_token');
        }
        return token;
      }

      switch (reply.body['error']) {
        case 'authorization_pending':
          break;
        case 'slow_down':
          // RFC 8628 §3.5: back off by five seconds and keep waiting.
          interval += const Duration(seconds: 5);
          break;
        case 'access_denied':
          throw DeviceAuthException(DeviceAuthFailure.accessDenied, 'the request was denied');
        case 'expired_token':
          throw DeviceAuthException(DeviceAuthFailure.expired, 'the code expired before it was approved');
        case 'invalid_grant':
          throw DeviceAuthException(DeviceAuthFailure.invalidGrant, 'the device code is unknown or already used');
        default:
          throw DeviceAuthException(
            DeviceAuthFailure.malformed,
            'unexpected token response: ${reply.body['error'] ?? reply.status}',
          );
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw DeviceAuthException(DeviceAuthFailure.expired, 'the code expired before it was approved');
      }
      onTick?.call(remaining);
      await _sleep(interval);
    }
  }

  /// The whole flow: start, hand the code to [onCode] for display, then poll and
  /// store what comes back. Returns the token, or rethrows [DeviceAuthException].
  Future<String> connect({
    void Function(DeviceAuthorization)? onCode,
    bool Function()? isCancelled,
  }) async {
    final authorization = await start();
    onCode?.call(authorization);
    final token = await poll(authorization, isCancelled: isCancelled);
    await store.write(token);
    return token;
  }

  /// The stored token, if any. Does not validate it — the server decides.
  Future<String?> currentToken() => store.read();

  /// Prove the stored token still works. `null` means it does not.
  Future<bool> isConnected() async {
    final token = await store.read();
    if (token == null) return false;
    final reply = await _send('GET', _endpoint('/api/sync'), bearer: token);
    if (reply.status == 401) {
      await store.clear();
      return false;
    }
    return reply.status == 200;
  }

  /// Sign out. Revokes the token on the server as well as deleting the local
  /// copy, because deleting it locally alone would leave a live credential.
  Future<void> disconnect({bool revoke = true}) async {
    final token = await store.read();
    await store.clear();
    if (!revoke || token == null) return;

    final listed = await _send('GET', _endpoint('/api/tokens'), bearer: token);
    if (listed.status != 200) return;
    final tokens = listed.body['tokens'];
    if (tokens is! List) return;
    for (final entry in tokens) {
      if (entry is Map && entry['current'] == true && entry['id'] is num) {
        await _send('POST', _endpoint('/api/tokens/revoke'), body: {'id': (entry['id'] as num).toInt()}, bearer: token);
        return;
      }
    }
  }

  /// An authenticated sync call. Every request carries the bearer token; the
  /// server scopes the data to the token's owner, not to anything sent here.
  Future<Map<String, dynamic>> syncRequest(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final token = await store.read();
    if (token == null) {
      throw DeviceAuthException(DeviceAuthFailure.invalidGrant, 'no token: connect first');
    }
    final reply = await _send(method, _endpoint(path), body: body, bearer: token);
    if (reply.status == 401) {
      // The credential is gone or expired: drop it so the UI re-runs the flow.
      await store.clear();
      throw DeviceAuthException(DeviceAuthFailure.invalidGrant, 'the access token was rejected (401)');
    }
    return reply.body;
  }

  /// Items synced by the signed-in account.
  Future<Map<String, dynamic>> listItems() => syncRequest('GET', '/api/sync');

  /// Push items. Idempotent per `clientId`.
  Future<Map<String, dynamic>> saveItems(List<Map<String, Object?>> items) =>
      syncRequest('POST', '/api/sync', body: {'items': items});

  /// Read one stored payload.
  Future<Map<String, dynamic>> readPayload(String kind, String clientId) =>
      syncRequest('GET', '/api/sync/${Uri.encodeComponent(kind)}/${Uri.encodeComponent(clientId)}');

  void close() => _http.close(force: true);
}
