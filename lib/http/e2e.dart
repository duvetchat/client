import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:duvet_client/errors.dart';
import 'package:duvet_client/http/methods.dart';
import 'package:duvet_client/http/send.dart';
import 'package:duvet_client/models/types.dart';

const _conversations = '/api/users/@me/conversations';

/// What [read] makes of the answer's JSON: an answer that doesn't read is a
/// [DuvetMalformedAnswerException], as the API took the request.
T _reading<T>(http.Response response, T Function(Object? json) read) {
  try {
    return read(jsonDecode(response.body));
  } on Object catch (cause) {
    throw DuvetMalformedAnswerException(
        statusCode: response.statusCode, body: response.body, cause: cause);
  }
}

/// The answer's object, as [of] reads it.
T _object<T>(http.Response response, T Function(Map<String, dynamic>) of) =>
    _reading(response, (j) => of(j as Map<String, dynamic>));

/// The answer's list of objects, as [of] reads each.
List<T> _objects<T>(
        http.Response response, T Function(Map<String, dynamic>) of) =>
    _reading(response, (j) => _list(j, of));

List<T> _list<T>(Object? j, T Function(Map<String, dynamic>) of) => [
      for (final e in j as List<dynamic>? ?? const [])
        of(e as Map<String, dynamic>),
    ];

List<String> _ids(Object? j) =>
    [for (final id in j as List<dynamic>? ?? const []) id as String];

/// The API's end-to-end encryption routes, for the session [api] sends its
/// requests with, named as the desktop's
/// `e2eApi(client)` names them so both engines read alike. Binary fields go
/// as the core makes and takes them, in standard base64; a package's parts
/// and the backup's segments go up as bytes, and come down from the signed
/// URL their routes answer ([signedFile]).
///
/// The refusals the engine tells apart are [DuvetApiException]'s subtypes:
/// [DuvetUpdateRequiredException] (426), [DuvetPausedException] (503),
/// [DuvetStaleMessageException], [DuvetEpochTakenException],
/// [DuvetIdentityChangedException] and [DuvetDeviceListChangedException]
/// (409) and [DuvetCommitRefusedException] (422). Any other keeps its status
/// and body: a queue read from below its floor is a 410 with `floor_seq`, a
/// day of the backup another segment holds a 409 with `current`. A 401 and a
/// 403 are [DuvetAuthException]s, encryption's 403s among them, which the
/// engine reads by their body's `error`: `this session has no device`, `this
/// device isn't on your device list` (a listed device's route) and `the proof
/// doesn't verify` (a registration or a bind).
///
/// A 2xx answer that doesn't read is a [DuvetMalformedAnswerException]: the
/// API took the request (a commit, a device list, a message), and only its
/// answer is lost.
class E2eApi {
  /// The session's client, whose headers, renewals and refusals its requests
  /// have.
  final RestMethods api;

  const E2eApi(this.api);

  // A. The configuration

  /// What a client needs of end-to-end encryption: a client below the lowest
  /// version reads it too.
  Future<E2eConfig> config() async => _object(
      await api.request(
          'GET', '/api/e2e', 'get end-to-end encryption\'s configuration'),
      E2eConfig.fromJson);

  // B. Devices, and the session's binding to one

  /// A new challenge for the session, in its last one's place (a login gives
  /// one: `SignIn.deviceChallenge`).
  Future<String> deviceChallenge() async => _object(
      await api.request(
          'POST', '/api/users/@me/devices/challenge', 'get a device challenge'),
      (j) => j['device_challenge'] as String);

  /// Registers the device and binds the session to it: registering the same
  /// device again with the same keys binds the session.
  Future<Device> registerDevice(DeviceRegistration device) async => _object(
      await api.request('POST', '/api/users/@me/devices', 'register device',
          json: device.toJson()),
      Device.fromJson);

  /// Binds the session to a device of the user's registered before, with its
  /// [proof] over the session's challenge.
  Future<void> bindDevice(String deviceId, String proof) async {
    await api.request(
        'POST', '/api/users/@me/devices/$deviceId/bind', 'bind device',
        json: {'proof': proof});
  }

  /// The user's devices, the session's [Device.current].
  Future<List<Device>> devices() async => _objects(
      await api.request('GET', '/api/users/@me/devices', 'get devices'),
      Device.fromJson);

  /// Only one off the device list: a listed one is a 409 (`sign a device
  /// list without it`).
  Future<void> deleteDevice(String deviceId) async {
    await api.request(
        'DELETE', '/api/users/@me/devices/$deviceId', 'delete device');
  }

  // C. The identity and its device list

  /// Publishes the user's identity, or puts a new one in the current one's
  /// place. A 409 is [DuvetIdentityChangedException].
  Future<IdentityPublished> putIdentity(IdentityUpload identity) async =>
      _object(
          await api.request('PUT', '/api/users/@me/identity', 'put identity',
              json: identity.toJson()),
          IdentityPublished.fromJson);

  /// Puts a new device list in the current one's place, by compare-and-set,
  /// and answers its version. A 409 is [DuvetDeviceListChangedException].
  Future<int> putDeviceList(DeviceListUpload list) async => _object(
      await api.request('PUT', '/api/users/@me/device-list', 'put device list',
          json: list.toJson()),
      (j) => j['version'] as int);

  /// A user's identity: a 404 (`no identity`) for one without.
  Future<Identity> identity(String userId) async => _object(
      await api.request('GET', '/api/users/$userId/identity', 'get identity'),
      Identity.fromJson);

  /// The identities of 1 to 50 users (a 400 for none, or more); those the
  /// user may not read, or without one, are left out.
  Future<List<Identity>> identities(List<String> userIds) async => _objects(
      await api.request('GET', '/api/users/identities', 'get identities',
          query: {'ids': userIds.join(',')}),
      Identity.fromJson);

  /// What the core's recover takes of the user's identity, or of [identity],
  /// one starting over replaced while its backup is kept
  /// ([IdentityBackup.replaced]).
  Future<IdentityBackup> identityBackup({String? identity}) async => _object(
      await api.request(
          'GET', '/api/users/@me/identity/backup', 'get identity backup',
          query: {'identity': identity}),
      IdentityBackup.fromJson);

  // D. Key packages

  /// The device's whole set, in place of the one it had. Answers the IDs of
  /// its single-use ones the API handed out already, which the core takes as
  /// spent.
  Future<List<String>> putKeyPackages(
          List<KeyPackageUpload> keyPackages) async =>
      _object(
          await api.request('PUT', '/api/users/@me/devices/@me/key-packages',
              'put key packages',
              json: {
                'key_packages': [for (final k in keyPackages) k.toJson()]
              }),
          (j) => _ids(j['handed_out']));

  /// A key package for each listed device of the user's that has one to give.
  Future<List<ClaimedKeyPackage>> claimKeyPackages(String userId) async =>
      _object(
          await api.request('POST', '/api/users/$userId/key-packages/claim',
              'claim key packages'),
          (j) => _list(j['key_packages'], ClaimedKeyPackage.fromJson));

  // E. A conversation's group

  /// What a member's device joins the group by: a 404 (`no group yet`)
  /// without one.
  Future<MlsGroupInfo> groupInfo(String conversationId) async => _object(
      await api.request('GET', '$_conversations/$conversationId/mls/group-info',
          'get group info'),
      MlsGroupInfo.fromJson);

  /// The same commit again gets the answer it got.
  Future<CommitTaken> commit(
          String conversationId, Commit commit) async =>
      _object(
          await api.request(
              'POST', '$_conversations/$conversationId/mls/commits', 'commit',
              json: commit.toJson()),
          CommitTaken.fromJson);

  /// The entries numbered after [after], [limit] of them (200 by default,
  /// 500 at most).
  Future<QueuePage> queue(String conversationId, int after,
          {int? limit}) async =>
      _object(
          await api.request(
              'GET', '$_conversations/$conversationId/mls/queue', 'get queue',
              query: {'after': after, 'limit': limit}),
          QueuePage.fromJson);

  // F. Members: an addition and a removal are the owner's commit of exactly
  // that user, leaving is a statement.

  Future<MemberAdded> addMember(
          String conversationId, String userId, Commit commit) async =>
      _object(
          await api.request(
              'POST', '$_conversations/$conversationId/members', 'add member',
              json: {'user_id': userId, ...commit.toJson()}),
          MemberAdded.fromJson);

  Future<CommitTaken> removeMember(
          String conversationId, String userId, Commit commit) async =>
      _object(
          await api.request(
              'DELETE',
              '$_conversations/$conversationId/members/$userId',
              'remove member',
              json: commit.toJson()),
          CommitTaken.fromJson);

  /// With the user's leave [statement] where the conversation has a group,
  /// without one where it hasn't.
  Future<void> leave(String conversationId, {String? statement}) async {
    await api.request('DELETE', '$_conversations/$conversationId/members/@me',
        'leave conversation',
        json: statement == null ? null : {'statement': statement});
  }

  // G. Messages

  /// Sends an encrypted message. Its sealed [files] go in a form after its
  /// fields, in the order its [EncryptedMessage.attachmentIds] name them;
  /// [onProgress] and [abortTrigger] work as `RestMethods.sendMessage`'s.
  /// The same nonce again answers the message it sent.
  Future<DirectMessage> sendMessage(
    String conversationId,
    EncryptedMessage message, {
    List<List<int>> files = const [],
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final path = '$_conversations/$conversationId/messages';
    final response = files.isEmpty
        ? await api.request('POST', path, 'send encrypted message',
            json: message.toJson(),
            onProgress: onProgress,
            abortTrigger: abortTrigger)
        : await api.request('POST', path, 'send encrypted message',
            // A reference and allowed mentions as JSON strings, lists
            // repeated.
            fields: {
              for (final MapEntry(:key, :value) in message.toJson().entries)
                key: value is Map ? jsonEncode(value) : value as Object,
            },
            files: [
              for (final file in files)
                (field: 'files', bytes: file, filename: 'file'),
            ],
            onProgress: onProgress,
            abortTrigger: abortTrigger);
    return _object(response, DirectMessage.fromJson);
  }

  /// The same edit again answers with its entry.
  Future<MessageEdited> editMessage(
          String conversationId, String messageId, String ciphertext) async =>
      _object(
          await api.request(
              'PATCH',
              '$_conversations/$conversationId/messages/$messageId',
              'edit encrypted message',
              json: {'ciphertext': ciphertext}),
          MessageEdited.fromJson);

  /// Deletes an encrypted message with its tombstone ([ciphertext]); the same
  /// deletion again answers with its entry.
  Future<MessageDeleted> deleteMessage(
          String conversationId, String messageId, String ciphertext) async =>
      _object(
          await api.request(
              'DELETE',
              '$_conversations/$conversationId/messages/$messageId',
              'delete encrypted message',
              json: {'ciphertext': ciphertext}),
          MessageDeleted.fromJson);

  /// The conversation's deleted encrypted messages, by ID, oldest first,
  /// after [after]: [limit] of them, 1000 at most.
  Future<List<String>> deletedMessages(String conversationId,
          {String? after, int? limit}) async =>
      _object(
          await api.request(
              'GET',
              '$_conversations/$conversationId/messages/deleted',
              'get deleted messages',
              query: {'after': after, 'limit': limit}),
          (j) => _ids(j['ids']));

  // H. The inbox between devices

  /// Leaves [message] in a device's inbox; answers its ID. A full inbox is a
  /// 409 (`inbox full`).
  Future<String> sendToDevice(String deviceId, String message) async => _object(
      await api.request(
          'POST', '/api/devices/$deviceId/inbox', 'send to device',
          json: {'message': message}),
      (j) => j['id'] as String);

  /// This device's inbox after [after], oldest first, 100 at most.
  Future<List<InboxMessage>> inbox({String? after, int? limit}) async =>
      _objects(
          await api.request(
              'GET', '/api/users/@me/devices/@me/inbox', 'get inbox',
              query: {'after': after, 'limit': limit}),
          InboxMessage.fromJson);

  /// Deletes this device's inbox through [through], the last message it
  /// handled.
  Future<void> clearInbox(String through) async {
    await api.request(
        'DELETE', '/api/users/@me/devices/@me/inbox', 'clear inbox',
        query: {'through': through});
  }

  // I. Shared history

  /// Makes a package; the same one again answers it as it is.
  Future<HistoryShare> putShare(String conversationId, String shareId,
          HistoryShareUpload share) async =>
      _object(
          await api.request(
              'PUT',
              '$_conversations/$conversationId/history-shares/$shareId',
              'put history share',
              json: share.toJson()),
          HistoryShare.fromJson);

  /// Uploads part [n] (from 0) as it is: 1 MiB and its tag at most.
  Future<void> putSharePart(
      String conversationId, String shareId, int n, List<int> part,
      {void Function(int sent, int total)? onProgress,
      Future<void>? abortTrigger}) async {
    await api.request(
        'PUT',
        '$_conversations/$conversationId/history-shares/$shareId/parts/$n',
        'put history share part',
        bytes: part,
        onProgress: onProgress,
        abortTrigger: abortTrigger);
  }

  /// Completes a package once all its parts are up.
  Future<void> completeShare(String conversationId, String shareId) async {
    await api.request(
        'POST',
        '$_conversations/$conversationId/history-shares/$shareId/complete',
        'complete history share');
  }

  /// The complete packages for the user that this device hasn't
  /// acknowledged.
  Future<List<HistoryShare>> shares() async => _objects(
      await api.request(
          'GET', '/api/users/@me/history-shares', 'get history shares'),
      HistoryShare.fromJson);

  /// Part [n]'s bytes, from the signed URL its route answers.
  Future<Uint8List> sharePart(String shareId, int n,
          {void Function(int received, int total)? onProgress,
          Future<void>? abortTrigger}) async =>
      signedFile(
          _object(
              await api.request('GET', '/api/history-shares/$shareId/parts/$n',
                  'get history share part'),
              (j) => j['url'] as String),
          onProgress: onProgress,
          abortTrigger: abortTrigger);

  Future<void> ackShare(String shareId) async {
    await api.request(
        'POST', '/api/history-shares/$shareId/ack', 'ack history share');
  }

  // J. The encrypted backup

  /// The segments shown now, oldest first, 1000 at most: of a conversation
  /// or of all, after [after], of the user's identity or of [identity], one
  /// starting over replaced while its backup is kept.
  Future<List<BackupSegment>> segments(
          {String? conversationId, String? after, String? identity}) async =>
      _objects(
          await api.request(
              'GET', '/api/users/@me/backup/segments', 'get backup segments',
              query: {
                'conversation_id': conversationId,
                'after': after,
                'identity': identity,
              }),
          BackupSegment.fromJson);

  /// Puts the conversation's [day] (YYYY-MM-DD, in UTC) in the place of the
  /// segment [replaces] names, null when the device saw none of that day;
  /// answers its ID. Another segment there is a 409 with its ID (`current`).
  Future<String> putSegment(
          String conversationId, String day, List<int> segment,
          {String? replaces,
          void Function(int sent, int total)? onProgress,
          Future<void>? abortTrigger}) async =>
      _object(
          await api.request(
              'PUT',
              '/api/users/@me/backup/segments/$conversationId/$day',
              'put backup segment',
              query: {'replaces': replaces ?? 'none'},
              bytes: segment,
              onProgress: onProgress,
              abortTrigger: abortTrigger),
          (j) => j['id'] as String);

  /// A segment's bytes, from the signed URL its route answers.
  Future<Uint8List> segment(String segmentId,
          {void Function(int received, int total)? onProgress,
          Future<void>? abortTrigger}) async =>
      signedFile(
          _object(
              await api.request(
                  'GET',
                  '/api/users/@me/backup/segments/$segmentId',
                  'get backup segment'),
              (j) => j['url'] as String),
          onProgress: onProgress,
          abortTrigger: abortTrigger);

  // K. Decryption failures

  /// Counts a failure to decrypt by its [kind]: `message`, `envelope`,
  /// `too_large`, `commit`, `welcome`, `segment`, `attachment` or `direct`,
  /// anything else as `other`; [count] of them, one by default. No ID and no
  /// content.
  Future<void> reportDecryptFailure(String kind, {int? count}) async {
    await api.request(
        'POST', '/api/e2e/decrypt-failures', 'report decryption failure',
        json: {'kind': kind, if (count != null) 'count': count});
  }

  /// The counts from [from] through [to] (YYYY-MM-DD), the last 30 days
  /// without them. Staff only.
  Future<List<DecryptFailureCount>> decryptFailures(
          {String? from, String? to}) async =>
      _objects(
          await api.request('GET', '/api/internal/e2e/decrypt-failures',
              'get decryption failures',
              query: {'from': from, 'to': to}),
          DecryptFailureCount.fromJson);

  // Downloads from a signed URL

  /// The file at [url], a URL the API signed: a part's or a segment's, as
  /// their routes answer it, or an encrypted attachment's (`Attachment.url`).
  /// One without a host is the API's.
  ///
  /// It goes with none of the app's headers, no `Authorization`,
  /// `X-Session-Token`, `X-Duvet-Client` or cookie: a redirect would carry
  /// them to the storage's host. [onProgress] gets the bytes received so far
  /// and their total, -1 when the answer doesn't say; it fails with a
  /// [TimeoutException] when `requestTimeout` passes without progress.
  /// A refusal (a signature expired) is a [DuvetApiException], never a
  /// [DuvetAuthException]: it says nothing of the session.
  Future<Uint8List> signedFile(String url,
      {void Function(int received, int total)? onProgress,
      Future<void>? abortTrigger}) async {
    final router = api.router;
    final target = Uri.parse('${router.secure ? 'https' : 'http'}://'
            '${router.api}/')
        .resolve(url);
    final response = await sendWithin(api.client, http.Request('GET', target),
        timeout: api.requestTimeout,
        abortTrigger: abortTrigger,
        onReceiveProgress: onProgress);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DuvetApiException(
          action: 'download a signed file',
          statusCode: response.statusCode,
          reasonPhrase: response.reasonPhrase,
          body: response.body,
          retryAfter: retryAfterOf(response.headers));
    }
    return response.bodyBytes;
  }
}
