/// Base exception for all Duvet library errors.
class DuvetException implements Exception {
  final String message;
  const DuvetException(this.message);

  @override
  String toString() => 'DuvetException: $message';
}

/// Thrown when an API call returns a non-2xx response.
class DuvetApiException extends DuvetException {
  final int statusCode;
  final String? reasonPhrase;
  final String? body;

  /// How long the answer asked to wait before trying again (its
  /// `Retry-After`, as the API sends it with its 429s and 503s), null when it
  /// didn't say: see [retryAfterOf].
  final Duration? retryAfter;

  const DuvetApiException({
    required String action,
    required this.statusCode,
    this.reasonPhrase,
    this.body,
    this.retryAfter,
  }) : super('Failed to $action: $statusCode $reasonPhrase');

  @override
  String toString() =>
      'DuvetApiException[$statusCode]: $message\n${body ?? ''}';
}

/// An answer's `Retry-After` in [headers] (an `http.Response`'s, whose names
/// are lowercase), in whole seconds, or null when it's missing or doesn't read
/// as seconds: a date, which the API never sends, reads as none.
Duration? retryAfterOf(Map<String, String> headers) =>
    switch (int.tryParse(headers['retry-after'] ?? '')) {
      final int seconds when seconds >= 0 => Duration(seconds: seconds),
      _ => null,
    };

/// Thrown when authentication credentials are invalid or missing.
class DuvetAuthException extends DuvetApiException {
  const DuvetAuthException(
      {required super.action,
      required super.statusCode,
      super.body,
      super.retryAfter})
      : super(reasonPhrase: 'Unauthorized');
}

/// The API's 426: a route of end-to-end encryption, or of a conversation,
/// takes only a client that has it, and this one doesn't (its
/// `X-Duvet-Client`, `RestClient.duvetClient`, is below the API's lowest
/// version for its platform, or missing).
class DuvetUpdateRequiredException extends DuvetApiException {
  /// What the API read the client as (`android/1.0.0`), null when it read
  /// none.
  final String? client;

  /// The lowest version of the client's platform with end-to-end encryption,
  /// null when the platform has none yet.
  final String? minimum;

  const DuvetUpdateRequiredException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      super.retryAfter,
      this.client,
      this.minimum});
}

/// The API's 503 while encrypted conversations are paused: a conversation's
/// write waits [retryAfter] and goes again as it was. Any other 503 is a
/// [DuvetApiException].
class DuvetPausedException extends DuvetApiException {
  const DuvetPausedException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      required Duration super.retryAfter});

  /// The answer's `Retry-After`: 60 seconds, the API's own, when it doesn't
  /// read.
  @override
  Duration get retryAfter => super.retryAfter!;
}

/// The API's 409 `stale message`: a message, an edit or a deletion made in
/// another generation of its conversation's group, or too many epochs behind
/// it. The client drops it and encrypts it again, with another nonce, once
/// it has caught up to [generation] and [epoch], the group's now.
class DuvetStaleMessageException extends DuvetApiException {
  final int generation;
  final int epoch;

  const DuvetStaleMessageException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      super.retryAfter,
      required this.generation,
      required this.epoch});
}

/// The API's 409 `another commit took this epoch`: another member's commit
/// came first. The group is at [generation] and [epoch] now.
class DuvetEpochTakenException extends DuvetApiException {
  final int generation;
  final int epoch;

  const DuvetEpochTakenException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      super.retryAfter,
      required this.generation,
      required this.epoch});
}

/// The API's 409 `identity changed`: the user's identity isn't the one the
/// upload replaces. [identityKey] is the one they have now (standard base64),
/// null without one, which the client observes before it tries again.
class DuvetIdentityChangedException extends DuvetApiException {
  final String? identityKey;

  const DuvetIdentityChangedException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      super.retryAfter,
      this.identityKey});
}

/// The API's 409 `device list changed`: the list wasn't signed on top of the
/// current one, which [deviceList] is (standard base64), at [version]. The
/// client observes it before it signs again.
class DuvetDeviceListChangedException extends DuvetApiException {
  final String deviceList;
  final int version;

  const DuvetDeviceListChangedException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      super.retryAfter,
      required this.deviceList,
      required this.version});
}

/// The API's 422 with a [code]: a commit the API's validator refused (`commit
/// refused`), by the core's rule it broke, or `internal` for a check that got
/// no answer.
class DuvetCommitRefusedException extends DuvetApiException {
  final String code;

  const DuvetCommitRefusedException(
      {required super.action,
      required super.statusCode,
      super.reasonPhrase,
      super.body,
      super.retryAfter,
      required this.code});
}

/// Thrown when the gateway receives a malformed message.
class DuvetMalformedMessageException extends DuvetException {
  final Object cause;
  const DuvetMalformedMessageException(this.cause)
      : super('Received malformed message from gateway');

  @override
  String toString() => 'DuvetMalformedMessageException: $cause';
}
