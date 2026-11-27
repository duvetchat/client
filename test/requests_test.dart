// What each method sends: its method, path, query and body, as the desktop
// app's API layer (desktop-electrobun/src/mainview/src/lib/api/) sends them,
// and how the client renews its session.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duvet_client/duvet.dart';
import 'package:duvet_client/http/router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _time = '2026-10-22T10:00:00.123456Z';

final _message = {
  'id': 'm1',
  'room_id': 'r1',
  'author_id': 'u1',
  'content': 'hi',
  'type': 0,
  'created_at': _time,
  'updated_at': _time,
};

final _room = {
  'id': 'r1',
  'space_id': 's1',
  'parent_id': null,
  'type': 1,
  'name': 'general',
  'description': null,
  'position': 0,
  'nsfw': false,
  'created_at': _time,
  'updated_at': _time,
};

final _role = {
  'id': 'ro1',
  'space_id': 's1',
  'name': 'mod',
  'color_from': null,
  'color_via': null,
  'color_to': null,
  'flags': 0,
  'permissions': 8,
  'hoisted': false,
  'position': 1,
  'created_at': _time,
  'updated_at': _time,
};

final _asset = {
  'id': 'e1',
  'name': 'cat',
  'space_id': 's1',
  'attachment_id': 'a1',
  'created_at': _time,
  'updated_at': _time,
};

/// A request as the mock server got it.
class Sent {
  final http.Request request;
  Sent(this.request);

  String get method => request.method;
  String get path => request.url.path;
  Map<String, List<String>> get query => request.url.queryParametersAll;
  String? get contentType => request.headers['content-type'];
  Map<String, dynamic> get json =>
      jsonDecode(request.body) as Map<String, dynamic>;
}

/// A client whose server answers [reply] (200, JSON) and records what it got.
({RestClient api, List<Sent> sent}) _client(Object? Function(Sent) reply,
    {String token = 'tok', String sessionToken = 'sess', String? duvetClient}) {
  final sent = <Sent>[];
  final mock = MockClient((request) async {
    final s = Sent(request);
    sent.add(s);
    final body = reply(s);
    if (body is http.Response) return body;
    return http.Response(body == null ? '' : jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});
  });
  return (
    api: RestClient(mock,
        token: token, sessionToken: sessionToken, duvetClient: duvetClient),
    sent: sent
  );
}

/// The parts of [s]'s multipart body, in order: each one's field, its file
/// name (null for a value) and its content.
List<({String name, String? filename, String content})> _parts(Sent s) {
  final boundary = s.contentType!.split('boundary=').last;
  final body = latin1.decode(s.request.bodyBytes);
  return [
    // Each part starts a line after its boundary; the last boundary ends in --.
    for (final raw in body.split('--$boundary'))
      if (raw.startsWith('\r\n'))
        (() {
          final end = raw.indexOf('\r\n\r\n');
          final name = RegExp(r'name="([^"]*)"(?:; filename="([^"]*)")?')
              .firstMatch(raw.substring(0, end))!;
          return (
            name: name[1]!,
            filename: name[2],
            content: raw.substring(end + 4, raw.length - 2),
          );
        })(),
  ];
}

/// The headers that carry the app's session or name it, and a cookie, which a
/// signed URL never gets.
const _appHeaders = [
  'authorization',
  'x-session-token',
  'x-duvet-client',
  'cookie'
];

void main() {
  group('headers', () {
    test('sends the access and session tokens', () async {
      final c = _client((_) => null);
      await c.api.leaveSpace('s1');
      final h = c.sent.single.request.headers;
      expect(h['Authorization'], 'Bearer tok');
      expect(h['X-Session-Token'], 'sess');
    });

    test('sends no auth headers without a session', () async {
      final c = _client(
          (_) => {
                'code': 'abc',
                'space_id': 's1',
                'space_name': 'S',
                'description': '',
                'member_count': 3,
              },
          token: '',
          sessionToken: '');
      await c.api.getInvite('abc');
      final h = c.sent.single.request.headers;
      expect(h.containsKey('Authorization'), isFalse);
      expect(h.containsKey('X-Session-Token'), isFalse);
    });

    test('JSON bodies say so; bodiless requests carry no content type',
        () async {
      final c = _client((_) => null);
      await c.api.pinRoomMessage('r1', 'm1');
      await c.api.inviteToTeam('t1', 'a@b.c');
      expect(c.sent[0].contentType, isNull);
      expect(c.sent[1].contentType, startsWith('application/json'));
    });
  });

  group('auth', () {
    test('logIn keeps the tokens of the body', () async {
      final c = _client((_) => {'token': 'A', 'session_token': 'S'},
          token: '', sessionToken: '');
      final signIn = await c.api.logIn('a@b.c', 'pw');
      expect(signIn.token, 'A');
      expect(c.api.token, 'A');
      expect(c.api.sessionToken, 'S');
      expect(c.sent.single.path, '/api/auth/login');
      expect(c.sent.single.json, {'email': 'a@b.c', 'password': 'pw'});
    });

    test('a failed logIn throws DuvetAuthException without refreshing',
        () async {
      final c = _client((_) => http.Response('{"error":"bad"}', 401));
      await expectLater(
          c.api.logIn('a@b.c', 'pw'), throwsA(isA<DuvetAuthException>()));
      expect(c.sent, hasLength(1));
    });

    test('signIn sends the account', () async {
      final c = _client((_) => null);
      await c.api.signIn(username: 'u', password: 'p', email: 'e@x.y');
      expect(c.sent.single.path, '/api/auth/signin');
      expect(c.sent.single.json,
          {'username': 'u', 'alias': null, 'password': 'p', 'email': 'e@x.y'});
    });

    test('logout forgets the tokens even when it fails', () async {
      final c = _client((_) => http.Response('', 500));
      await c.api.logout();
      expect(c.api.token, isEmpty);
      expect(c.api.sessionToken, isEmpty);
    });

    test('a 401 refreshes once for concurrent requests and retries them',
        () async {
      var refreshes = 0;
      final c = _client((s) {
        if (s.path == '/api/auth/refresh') {
          refreshes++;
          return {'token': 'new', 'session_token': 'sess2'};
        }
        if (s.request.headers['Authorization'] != 'Bearer new') {
          return http.Response('{"error":"expired"}', 401);
        }
        return [_message];
      });
      final pages = await Future.wait(
          [c.api.getMessages('r1'), c.api.getMessages('r1', before: 'm9')]);
      expect(pages.map((p) => p.single.id), ['m1', 'm1']);
      expect(refreshes, 1);
      final refresh = c.sent.firstWhere((s) => s.path == '/api/auth/refresh');
      expect(refresh.request.headers['X-Session-Token'], 'sess');
      expect(c.api.sessionToken, 'sess2');
    });

    test('a request is retried only once', () async {
      final c = _client((s) => s.path == '/api/auth/refresh'
          ? {'token': 'new'}
          : http.Response('', 401));
      await expectLater(c.api.getFriends(), throwsA(isA<DuvetAuthException>()));
      expect(c.sent.map((s) => s.path), [
        '/api/users/@me/friends',
        '/api/auth/refresh',
        '/api/users/@me/friends'
      ]);
    });

    test('a rejected refresh forgets the tokens', () async {
      final c = _client((s) => http.Response('', 401));
      await expectLater(c.api.getFriends(), throwsA(isA<DuvetAuthException>()));
      expect(c.api.token, isEmpty);
      expect(c.api.sessionToken, isEmpty);
    });

    test('a rate-limited refresh waits and tries again', () async {
      var refreshes = 0;
      final c = _client((s) {
        if (s.path == '/api/auth/refresh') {
          return ++refreshes == 1
              ? http.Response('', 429, headers: {'retry-after': '1'})
              : {'token': 'new'};
        }
        return s.request.headers['Authorization'] == 'Bearer new'
            ? <Object>[]
            : http.Response('', 401);
      });
      expect(await c.api.getFriends(), isEmpty);
      expect(refreshes, 2);
      expect(c.api.sessionToken, 'sess', reason: 'kept when none comes back');
    });

    test('a refresh still limited after its tries says the API\'s wait',
        () async {
      var refreshes = 0;
      final c = _client((s) => s.path == '/api/auth/refresh'
          ? http.Response('', 429,
              headers: {'retry-after': ++refreshes > 3 ? '7' : '0'})
          : http.Response('', 401));
      await expectLater(
          c.api.refreshSession(),
          throwsA(isA<DuvetApiException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.retryAfter, 'retryAfter',
                  const Duration(seconds: 7))));
      expect(refreshes, 4);
    });

    test('without a session token a 401 just throws', () async {
      final c = _client((_) => http.Response('', 401), sessionToken: '');
      await expectLater(c.api.getFriends(), throwsA(isA<DuvetAuthException>()));
      expect(c.sent, hasLength(1));
    });

    test('other failures throw DuvetApiException with the status', () async {
      final c = _client((_) => http.Response('{"error":"nope"}', 404));
      await expectLater(
          c.api.getRoomPins('r1'),
          throwsA(isA<DuvetApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.body, 'body', contains('nope'))));
    });
  });

  group('messages', () {
    test('getMessages pages back by 100', () async {
      final c = _client((_) => [_message]);
      await c.api.getMessages('r1', before: 'm5');
      expect(c.sent.single.path, '/api/rooms/r1/messages');
      expect(c.sent.single.query, {
        'count': ['100'],
        'before': ['m5'],
      });
    });

    test('history pages take a count', () async {
      final c = _client((s) => s.path.startsWith('/api/rooms')
          ? [_message]
          : [
              {..._message, 'conversation_id': 'c1'}
            ]);
      await c.api.getMessages('r1', count: 1);
      await c.api.getDirectMessages('c1', count: 1);
      await c.api.getDirectMessages('c1', before: 'd0');
      expect(c.sent[0].query, {
        'count': ['1']
      });
      expect(c.sent[1].path, '/api/users/@me/conversations/c1/messages');
      expect(c.sent[1].query, {
        'count': ['1']
      });
      expect(c.sent[2].query, {
        'count': ['100'],
        'before': ['d0'],
      });
    });

    test('getMessagesAfter asks in ascending order', () async {
      final c = _client((_) => [_message]);
      await c.api.getMessagesAfter('r1', 'm5');
      expect(c.sent.single.query, {
        'count': ['100'],
        'after': ['m5'],
        'order': ['asc'],
      });
    });

    test('sendMessage without files sends JSON', () async {
      final c = _client((_) => _message);
      await c.api.sendMessage('r1', 'hello',
          nonce: 'n1',
          messageReference: const MessageReference(
              type: MessageReferenceType.reply, messageId: 'm0'),
          embeds: [
            const Embed(
                title: 'T',
                color: EmbedColor(colorFrom: 0xff0000),
                fields: [EmbedField(name: 'a', value: 'b', inline: true)])
          ],
          stickerAttachmentId: 'st1');
      final s = c.sent.single;
      expect(s.method, 'POST');
      expect(s.path, '/api/rooms/r1/messages');
      expect(s.json, {
        'content': 'hello',
        'nonce': 'n1',
        'message_reference': {'type': 0, 'message_id': 'm0'},
        'embeds': [
          {
            'title': 'T',
            'color': {'color_from': 0xff0000},
            'fields': [
              {'name': 'a', 'value': 'b', 'inline': true}
            ],
          }
        ],
        'sticker_attachment_id': 'st1',
      });
    });

    test('sendMessage with files sends a multipart form', () async {
      final dir = Directory.systemTemp.createTempSync('duvet_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cat.png')..writeAsBytesSync([1, 2, 3]);

      final c = _client((_) => _message);
      await c.api.sendMessage('r1', 'look',
          nonce: 'n1',
          messageReference: const MessageReference(messageId: 'm0'),
          files: [file]);
      final s = c.sent.single;
      expect(s.contentType, startsWith('multipart/form-data; boundary='));
      final body = s.request.body;
      expect(body, contains('name="content"\r\n\r\nlook'));
      expect(body, contains('name="nonce"\r\n\r\nn1'));
      expect(body,
          contains('name="message_reference"\r\n\r\n{"message_id":"m0"}'));
      expect(body, contains('name="files"; filename="cat.png"'));
      expect(body, contains('content-type: image/png'));
      expect(body, isNot(contains('name="reference"')));
    });

    test('a reply that doesn\'t mention its author: allowed_mentions',
        () async {
      final dir = Directory.systemTemp.createTempSync('duvet_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cat.png')..writeAsBytesSync([1, 2, 3]);
      const reply =
          MessageReference(type: MessageReferenceType.reply, messageId: 'm0');
      const silent = AllowedMentions(repliedUser: false);

      final c = _client((_) => _message);
      await c.api.sendMessage('r1', 'hi',
          messageReference: reply, allowedMentions: silent);
      await c.api.sendMessage('r1', 'hi',
          messageReference: reply,
          allowedMentions: const AllowedMentions(repliedUser: true));
      // In a form, a JSON string, as message_reference.
      await c.api.sendMessage('r1', 'look',
          messageReference: reply, allowedMentions: silent, files: [file]);

      expect(c.sent[0].json, {
        'content': 'hi',
        'message_reference': {'type': 0, 'message_id': 'm0'},
        'allowed_mentions': {'replied_user': false},
      });
      expect(c.sent[1].json['allowed_mentions'], {'replied_user': true});
      expect(c.sent[2].request.body,
          contains('name="allowed_mentions"\r\n\r\n{"replied_user":false}'));
    });

    test('sendVoiceNote sends a WebM file of type 1', () async {
      final c = _client((_) => {..._message, 'type': 1});
      final m = await c.api.sendVoiceNote('r1', [1, 2, 3], nonce: 'n');
      expect(m.type, MessageType.voice);
      final body = c.sent.single.request.body;
      expect(body, contains('name="type"\r\n\r\n1'));
      expect(body, contains('filename="voice-note.webm"'));
      expect(body, contains('content-type: audio/webm'));
    });

    test('voice notes name their format: Ogg/Opus or AAC in MP4', () async {
      final c = _client((_) => {..._message, 'type': 1});
      await c.api.sendVoiceNote('r1', [1], format: 'ogg');
      final m4a = await c.api.sendVoiceNote('r1', [1], format: 'm4a');
      expect(m4a.type, MessageType.voice);
      expect(c.sent[0].request.body, contains('filename="voice-note.ogg"'));
      expect(c.sent[0].request.body, contains('content-type: audio/ogg'));
      expect(c.sent[1].request.body, contains('name="type"\r\n\r\n1'));
      expect(c.sent[1].request.body, contains('filename="voice-note.m4a"'));
      expect(c.sent[1].request.body, contains('content-type: audio/mp4'));
    });

    test('a voice note in another format is refused before sending', () async {
      final c = _client((_) => _message);
      await expectLater(c.api.sendVoiceNote('r1', [1], format: 'mp3'),
          throwsA(isA<ArgumentError>()));
      expect(c.sent, isEmpty);
    });

    test('an upload reports its progress, in pieces', () async {
      final dir = Directory.systemTemp.createTempSync('duvet_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/big.bin')
        ..writeAsBytesSync(List.filled(300 * 1024, 7));

      final c = _client((_) => _message);
      final progress = <(int, int)>[];
      await c.api.sendMessage('r1', 'look',
          files: [file],
          onProgress: (sent, total) => progress.add((sent, total)));
      final total = c.sent.single.request.bodyBytes.length;
      expect(progress.length, greaterThan(4));
      expect(progress.map((p) => p.$2).toSet(), {total});
      expect(progress.last, (total, total));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThan(progress[i - 1].$1));
      }
    });

    test('a cancelled send fails with RequestAbortedException', () async {
      final never = Completer<http.Response>();
      final api = RestClient(MockClient((_) => never.future), token: 'tok');
      final cancel = Completer<void>();
      final sending = api.sendMessage('r1', 'hi', abortTrigger: cancel.future);
      cancel.complete();
      await expectLater(sending, throwsA(isA<http.RequestAbortedException>()));
    });

    test('a request that gets no answer fails with TimeoutException', () async {
      final never = Completer<http.Response>();
      final api = RestClient(MockClient((_) => never.future),
          token: 'tok', requestTimeout: const Duration(milliseconds: 100));
      await expectLater(api.getFriends(), throwsA(isA<TimeoutException>()));
    });

    test('updateMessage and deleteMessage', () async {
      final c = _client((_) => _message);
      await c.api.updateMessage('m1', 'edited', 'r1');
      await c.api.deleteMessage('m1', 'r1');
      expect(c.sent[0].method, 'PATCH');
      expect(c.sent[0].path, '/api/rooms/r1/messages/m1');
      expect(c.sent[0].json, {'content': 'edited'});
      expect(c.sent[1].method, 'DELETE');
      expect(c.sent[1].path, '/api/rooms/r1/messages/m1');
    });

    test('pins and threads', () async {
      final c = _client((s) => s.method == 'GET' ? [_message] : null);
      await c.api.getRoomPins('r1');
      await c.api.pinRoomMessage('r1', 'm1');
      await c.api.unpinRoomMessage('r1', 'm1');
      await c.api.getMessageThread('r1', 'm1');
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'GET /api/rooms/r1/pins',
        'PUT /api/rooms/r1/pins/m1',
        'DELETE /api/rooms/r1/pins/m1',
        'GET /api/rooms/r1/messages/m1/thread',
      ]);
    });

    test('search repeats each list\'s key', () async {
      final c = _client((_) => {
            'total_results': 1,
            'messages': [_message],
          });
      final r = await c.api.searchSpaceMessages(
          's1',
          MessageSearch(
            query: 'a b',
            authorIds: ['u1', 'u2'],
            has: ['link'],
            pinned: false,
            before: DateTime.utc(2026, 1, 2),
            cursor: 'm7',
          ));
      expect(r.totalResults, 1);
      expect(r.messages.single.id, 'm1');
      expect(c.sent.single.path, '/api/spaces/s1/messages/search');
      expect(c.sent.single.query, {
        'query': ['a b'],
        'author_id': ['u1', 'u2'],
        'has': ['link'],
        'pinned': ['false'],
        'before': ['2026-01-02T00:00:00.000Z'],
        'cursor': ['m7'],
      });
    });

    test('typing indicators swallow failures', () async {
      final c = _client((_) => http.Response('', 500));
      await c.api.sendTypingIndicator('r1');
      await c.api.sendRecordingIndicator('r1');
      expect(c.sent.map((s) => s.path),
          ['/api/rooms/r1/typing', '/api/rooms/r1/recording']);
    });

    test('mention counts are read, and empty on failure', () async {
      final ok = _client((_) => {'r1': 2, 'c1': 1});
      expect(await ok.api.getMentionCounts(), {'r1': 2, 'c1': 1});
      expect(ok.sent.single.path, '/api/users/@me/mentions/counts');

      final failing = _client((_) => http.Response('', 500));
      expect(await failing.api.getMentionCounts(), isEmpty);
    });

    // The API's answer, as its fixture has it.
    for (final variant in ['full', 'nulls', 'partial']) {
      test(
          'resignAttachment posts outside /api and answers the new link '
          '($variant)', () async {
        final answer = jsonDecode(
            File('test/fixtures/attachment_resign.$variant.json')
                .readAsStringSync());
        final c = _client((_) => answer);
        expect(await c.api.resignAttachment('a1'), 's-string');
        expect((c.sent.single.method, c.sent.single.path),
            ('POST', '/attachments/a1/resign'));
        expect(c.sent.single.request.url.host, 'api.duvet.chat');
      });
    }

    test('resignAttachment keeps the ID to its path segment', () async {
      final c = _client((_) => {'url': '/attachments/x'});
      await c.api.resignAttachment('../users/@me');
      expect(c.sent.single.request.url.path,
          '/attachments/..%2Fusers%2F%40me/resign');
    });

    test('resignAttachment: an attachment the user can\'t see is a 404',
        () async {
      const body = '{"error":"attachment not found"}';
      final c = _client((_) => http.Response(body, 404));
      await expectLater(
          c.api.resignAttachment('a1'),
          throwsA(isA<DuvetApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.body, 'body', body)));
    });
  });

  group('reactions', () {
    test('room reactions encode the emoji once', () async {
      final c = _client((_) => null);
      await c.api.addRoomReaction('r1', 'm1', '👍');
      await c.api.removeRoomReaction('r1', 'm1', '👍');
      await c.api.removeRoomReaction('r1', 'm1', 'a/b#c');
      expect(c.sent[0].method, 'PUT');
      expect(c.sent[0].path, '/api/rooms/r1/messages/m1/reactions');
      expect(c.sent[0].json, {'emoji_name': '👍', 'emoji_id': null});
      expect(c.sent[1].request.url.toString(),
          endsWith('/api/rooms/r1/messages/m1/reactions/%F0%9F%91%8D'));
      expect(
          c.sent[2].request.url.toString(), endsWith('/reactions/a%2Fb%23c'));
    });

    test('a custom emoji\'s reaction is taken back by its ID', () async {
      final c = _client((_) => null);
      await c.api.removeRoomReaction(
          'r1', 'm1', '01920000-0000-7000-8000-0000000e4011');
      await c.api.removeConversationReaction(
          'c1', 'm1', '01920000-0000-7000-8000-0000000e4011');
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'DELETE /api/rooms/r1/messages/m1/reactions/01920000-0000-7000-8000-0000000e4011',
        'DELETE /api/users/@me/conversations/c1/messages/m1/reactions/01920000-0000-7000-8000-0000000e4011',
      ]);
    });

    test('conversation reactions', () async {
      final c = _client((_) => null);
      await c.api.addConversationReaction('c1', 'm1', 'cat', emojiId: 'e1');
      await c.api.removeConversationReaction('c1', 'm1', 'cat');
      expect(c.sent[0].path,
          '/api/users/@me/conversations/c1/messages/m1/reactions');
      expect(c.sent[0].json, {'emoji_name': 'cat', 'emoji_id': 'e1'});
      expect(c.sent[1].path,
          '/api/users/@me/conversations/c1/messages/m1/reactions/cat');
    });
  });

  group('rooms', () {
    test('createRoom sends the parent only when there is one', () async {
      final c = _client((_) => _room);
      await c.api.createRoom('s1', 'general', RoomType.text);
      await c.api.createRoom('s1', 'voice', RoomType.voice, parentId: 'cat1');
      expect(c.sent[0].json, {'name': 'general', 'type': 1});
      expect(c.sent[1].json, {'name': 'voice', 'type': 2, 'parent_id': 'cat1'});
    });

    test('updateRoom sends only what is given', () async {
      final c = _client((_) => _room);
      await c.api.updateRoom('s1', 'r1', name: 'x');
      await c.api.updateRoom('s1', 'r1',
          clearDescription: true, clearParent: true, position: 3);
      expect(c.sent[0].method, 'PATCH');
      expect(c.sent[0].path, '/api/spaces/s1/rooms/r1');
      expect(c.sent[0].json, {'name': 'x'});
      expect(c.sent[1].json,
          {'description': null, 'parent_id': null, 'position': 3});
    });

    test('overwrites and invites', () async {
      final c = _client((s) => switch (s.path) {
            '/api/spaces/s1/rooms/r1/overwrites' => {
                'id': 'o1',
                'room_id': 'r1',
                'target_id': 'ro1',
                'target_type': 0,
                'allow_flags': 1,
                'deny_flags': 2,
                'created_at': _time,
                'updated_at': _time,
              },
            '/api/spaces/s1/rooms/r1/invites' => {'code': 'abc'},
            _ => null,
          });
      final o = await c.api.upsertRoomOverwrite('s1', 'r1', 'ro1', 0, 1, 2);
      expect(o.allowFlags, 1);
      expect(c.sent[0].method, 'PUT');
      expect(c.sent[0].json, {
        'target_id': 'ro1',
        'target_type': 0,
        'allow_flags': 1,
        'deny_flags': 2,
      });
      await c.api.deleteRoomOverwrite('s1', 'r1', 'ro1');
      expect(c.sent[1].path, '/api/spaces/s1/rooms/r1/overwrites/ro1');
      expect(await c.api.createRoomInvite('s1', 'r1', 3600), 'abc');
      expect(c.sent[2].json, {'max_age': 3600});
    });
  });

  group('roles', () {
    test('createRole sends what is given', () async {
      final c = _client((_) => _role);
      await c.api.createRole('s1', 'mod', permissions: 8, hoisted: true);
      expect(c.sent.single.json,
          {'name': 'mod', 'permissions': 8, 'hoisted': true});
    });

    test('updateRole clears colors only when asked', () async {
      final c = _client((_) => _role);
      await c.api.updateRole('s1', 'ro1', colorFrom: 5);
      await c.api.updateRole('s1', 'ro1', clearColors: true);
      expect(c.sent[0].json, {'color_from': 5});
      expect(c.sent[1].json, {
        'color_from': null,
        'color_via': null,
        'color_to': null,
        'clear_colors': true,
      });
    });

    test('member roles take (space, role, member)', () async {
      final c = _client((_) => null);
      await c.api.assignRoleToMember('s1', 'ro1', 'mem1');
      await c.api.removeRoleFromMember('s1', 'ro1', 'mem1');
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'PUT /api/spaces/s1/members/mem1/roles/ro1',
        'DELETE /api/spaces/s1/members/mem1/roles/ro1',
      ]);
    });
  });

  group('emojis and stickers', () {
    test('create sends the file as "file" with its media type', () async {
      final dir = Directory.systemTemp.createTempSync('duvet_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cat.webp')..writeAsBytesSync([1]);

      final c = _client((_) => _asset);
      final sent = <int>[];
      await c.api
          .createEmoji('s1', 'cat', file, onProgress: (s, _) => sent.add(s));
      await c.api
          .createSticker('s1', 'cat', file, onProgress: (s, _) => sent.add(s));
      expect(sent.where((s) => s > 0), hasLength(greaterThanOrEqualTo(2)));
      for (final s in c.sent) {
        expect(s.contentType, startsWith('multipart/form-data'));
        expect(s.request.body, contains('name="name"\r\n\r\ncat'));
        expect(s.request.body, contains('name="file"; filename="cat.webp"'));
        expect(s.request.body, contains('content-type: image/webp'));
      }
      expect(c.sent.map((s) => s.path),
          ['/api/spaces/s1/emojis', '/api/spaces/s1/stickers']);
    });

    test('list, update, delete', () async {
      final c = _client((s) => switch (s.method) {
            'GET' => [_asset],
            'PATCH' => _asset,
            _ => null,
          });
      expect(await c.api.listEmojis('s1'), hasLength(1));
      await c.api.updateSticker('s1', 'st1', 'dog');
      await c.api.deleteSticker('s1', 'st1');
      expect(c.sent[1].json, {'name': 'dog'});
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'GET /api/spaces/s1/emojis',
        'PATCH /api/spaces/s1/stickers/st1',
        'DELETE /api/spaces/s1/stickers/st1',
      ]);
    });

    test('listMyEmojis and listMyStickers ask for the user\'s lists', () async {
      final c = _client((_) => [_asset]);
      expect((await c.api.listMyEmojis()).single.name, 'cat');
      expect((await c.api.listMyStickers()).single.spaceId, 's1');
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'GET /api/users/@me/emojis',
        'GET /api/users/@me/stickers',
      ]);
    });

    test('emojiImageUrl is the API\'s /emojis/<id>, outside /api', () {
      final c = _client((_) => null);
      expect(c.api.emojiImageUrl('e1').toString(),
          'https://api.duvet.chat/emojis/e1');
      final local = RestClient(http.Client(),
          router: const ApiRouter(api: 'localhost:9876', secure: false));
      expect(local.emojiImageUrl('e1').toString(),
          'http://localhost:9876/emojis/e1');
      expect(c.api.emojiImageUrl('../users').path, '/emojis/..%2Fusers');
    });
  });

  group('spaces', () {
    final created = {
      'space': {
        'id': 's1',
        'name': 'S',
        'owner_id': 'u1',
        'created_at': _time,
        'updated_at': _time,
      },
      'role': _role,
      'text_room': _room,
      'voice_room': {..._room, 'id': 'r2', 'type': 2},
      'member': {
        'id': 'mem1',
        'space_id': 's1',
        'user_id': 'u1',
        'created_at': _time,
        'updated_at': _time,
      },
    };

    test('createSpace answers the space and its rooms', () async {
      final c = _client((_) => created);
      final space = await c.api.createSpace('S');
      await c.api.createSpace('S', description: 'd');
      expect(c.sent[0].method, 'POST');
      expect(c.sent[0].path, '/api/spaces');
      expect(c.sent[0].json, {'name': 'S'});
      expect(c.sent[1].json, {'name': 'S', 'description': 'd'});
      expect(space.id, 's1');
      expect(space.space.ownerId, 'u1');
      expect(space.rooms.map((r) => (r.id, r.type)),
          [('r1', RoomType.text), ('r2', RoomType.voice)]);
    });

    test('deleteSpace', () async {
      final c = _client((_) => http.Response('', 204));
      await c.api.deleteSpace('s1');
      expect(c.sent.single.method, 'DELETE');
      expect(c.sent.single.path, '/api/spaces/s1');
    });

    test('deleteSpace: refusals keep their status and body', () async {
      for (final (status, body) in [
        (403, '{"error":"only the space\'s owner can delete it"}'),
        (404, '{"error":"space not found"}'),
        // An API without the route: gin's own plain-text 404.
        (404, '404 page not found'),
      ]) {
        final c = _client((_) => http.Response(body, status));
        await expectLater(
            c.api.deleteSpace('s1'),
            throwsA(isA<DuvetApiException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having((e) => e.body, 'body', body)));
      }
    });

    test('updateSpace sends JSON, or a form for images', () async {
      final c = _client((_) => {'id': 's1'});
      await c.api.updateSpace('s1', name: 'N');
      final sent = <(int, int)>[];
      await c.api.updateSpace('s1',
          removeIcon: true, onProgress: (s, t) => sent.add((s, t)));
      final total = c.sent[1].request.bodyBytes.length;
      expect(sent.last, (total, total));
      expect(c.sent[0].json, {'name': 'N'});
      expect(c.sent[1].contentType, startsWith('multipart/form-data'));
      expect(
          c.sent[1].request.body, contains('name="remove_icon"\r\n\r\ntrue'));
    });

    test('members are paged by highest role and ID', () async {
      final c = _client((_) => <Object>[]);
      await c.api.getSpaceMembers('s1');
      await c.api.getSpaceMembers('s1', afterId: 'mem9', afterPos: 2);
      expect(c.sent[0].query, {
        'count': ['50']
      });
      expect(c.sent[1].query, {
        'count': ['50'],
        'after_id': ['mem9'],
        'after_pos': ['2'],
      });
    });
  });

  group('kicks and bans', () {
    // The ban the API answers, as its fixture has it.
    final ban =
        jsonDecode(File('test/fixtures/space_ban.full.json').readAsStringSync())
            as Map<String, dynamic>;
    http.Response answer(int status) => http.Response(jsonEncode(ban), status,
        headers: {'content-type': 'application/json'});

    test('kickMember deletes the member, by member ID, with no body', () async {
      final c = _client((_) => http.Response('', 204));
      await c.api.kickMember('s1', 'mem1');
      final s = c.sent.single;
      expect((s.method, s.path), ('DELETE', '/api/spaces/s1/members/mem1'));
      expect((s.request.body, s.contentType), ('', null));
    });

    test('kickMember: a refusal keeps its status and body', () async {
      const body = '{"error":"you can only kick or ban members whose highest '
          'role is below your highest role"}';
      final c = _client((_) => http.Response(body, 403));
      await expectLater(
          c.api.kickMember('s1', 'mem1'),
          throwsA(isA<DuvetAuthException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.body, 'body', body)));
    });

    test('banUser sends the reason as JSON, and no body without one', () async {
      final c = _client((_) => answer(201));
      await c.api.banUser('s1', 'u2', reason: 'spamming');
      await c.api.banUser('s1', 'u2');
      await c.api.banUser('s1', 'u2', reason: '');
      expect(c.sent.map((s) => '${s.method} ${s.path}'),
          List.filled(3, 'PUT /api/spaces/s1/bans/u2'));
      expect(c.sent[0].json, {'reason': 'spamming'});
      expect(c.sent[0].contentType, startsWith('application/json'));
      // No body: the API reads it as no reason.
      for (final s in c.sent.skip(1)) {
        expect((s.request.body, s.contentType), ('', null));
      }
    });

    test('banUser answers the ban, and whether it is new: a 201, not a 200',
        () async {
      var status = 201;
      final c = _client((_) => answer(status));
      final banned = await c.api.banUser('s1', 'u2', reason: 'spamming');
      expect(banned.created, isTrue);
      expect((banned.ban.userId, banned.ban.reason, banned.ban.user.username),
          (ban['user_id'], ban['reason'], 's-string'));
      // Banned already: the ban as it was, its reason included.
      status = 200;
      final again = await c.api.banUser('s1', 'u2', reason: 'again');
      expect((again.created, again.ban.reason), (false, ban['reason']));
    });

    test('unbanUser deletes the ban; one that isn\'t there is a 404', () async {
      final c = _client((_) => http.Response('', 204));
      await c.api.unbanUser('s1', 'u2');
      final s = c.sent.single;
      expect((s.method, s.path), ('DELETE', '/api/spaces/s1/bans/u2'));
      expect((s.request.body, s.contentType), ('', null));

      const body = '{"error":"ban not found"}';
      final missing = _client((_) => http.Response(body, 404));
      await expectLater(
          missing.api.unbanUser('s1', 'u2'),
          throwsA(isA<DuvetApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.body, 'body', body)));
    });

    test('getSpaceBans pages by user ID, 50 at a time unless told', () async {
      final c = _client((_) => [ban]);
      final page = await c.api.getSpaceBans('s1');
      await c.api.getSpaceBans('s1', after: 'u2', count: 100);
      expect(page.single.userId, ban['user_id']);
      expect(c.sent.map((s) => '${s.method} ${s.path}'),
          List.filled(2, 'GET /api/spaces/s1/bans'));
      expect(c.sent[0].query, {
        'count': ['50']
      });
      expect(c.sent[1].query, {
        'count': ['100'],
        'after': ['u2'],
      });
    });
  });

  group('push registration', () {
    test('setPushRegistration puts the phone\'s FID', () async {
      final c = _client((_) => http.Response('', 204));
      await c.api.setPushRegistration('f1');
      final s = c.sent.single;
      expect((s.method, s.path), ('PUT', '/api/users/@me/push-registration'));
      expect(s.json, {'fid': 'f1'});
    });

    test('deletePushRegistration deletes the session\'s, with no body',
        () async {
      final c = _client((_) => http.Response('', 204));
      await c.api.deletePushRegistration();
      final s = c.sent.single;
      expect(
          (s.method, s.path), ('DELETE', '/api/users/@me/push-registration'));
      expect((s.request.body, s.contentType), ('', null));
    });

    test('a bot\'s 403 is a DuvetAuthException', () async {
      final c = _client((_) =>
          http.Response('{"error":"bots cannot access this endpoint"}', 403));
      expect(
          c.api.setPushRegistration('f1'), throwsA(isA<DuvetAuthException>()));
    });
  });

  group('notification levels', () {
    // A level, as the API's fixture has it.
    final setting = jsonDecode(
        File('test/fixtures/notification_setting.full.json')
            .readAsStringSync()) as Map<String, dynamic>;

    test('getNotificationSettings lists the levels the user chose', () async {
      final c = _client((_) => [setting]);
      final levels = await c.api.getNotificationSettings();
      expect((c.sent.single.method, c.sent.single.path),
          ('GET', '/api/users/@me/notification-settings'));
      expect((levels.single.targetId, levels.single.level),
          (setting['target_id'], NotificationLevel.nothing));
    });

    test('setNotificationLevel puts the place\'s kind and level, by its ID',
        () async {
      final c = _client((_) => setting);
      final saved = await c.api.setNotificationLevel(
          'r1', NotificationTarget.room, NotificationLevel.nothing);
      final s = c.sent.single;
      expect((s.method, s.path),
          ('PUT', '/api/users/@me/notification-settings/r1'));
      expect(s.json, {'target_type': 1, 'level': 2});
      expect(saved.targetType, NotificationTarget.conversation);
    });

    test('clearNotificationLevel deletes the place\'s level, with no body',
        () async {
      final c = _client((_) => http.Response('', 204));
      await c.api.clearNotificationLevel('r1');
      final s = c.sent.single;
      expect((s.method, s.path),
          ('DELETE', '/api/users/@me/notification-settings/r1'));
      expect((s.request.body, s.contentType), ('', null));
    });

    test('updateSpace sends the space\'s default in JSON and in a form',
        () async {
      final c = _client((_) => {'id': 's1'});
      await c.api
          .updateSpace('s1', defaultNotifications: NotificationLevel.all);
      await c.api.updateSpace('s1',
          removeIcon: true, defaultNotifications: NotificationLevel.mentions);
      expect(c.sent[0].json, {'default_notifications': 0});
      expect(c.sent[1].request.body,
          contains('name="default_notifications"\r\n\r\n1'));
      // Nothing isn't a default: nothing is sent.
      await expectLater(
          c.api.updateSpace('s1',
              defaultNotifications: NotificationLevel.nothing),
          throwsArgumentError);
      expect(c.sent, hasLength(2));
    });
  });

  group('friends', () {
    test('paths', () async {
      final c = _client((s) => switch ((s.method, s.path)) {
            ('POST', '/api/users/@me/friends/requests') => {
                'id': 'fr1',
                'sender_id': 'u1',
                'recipient_id': 'u2',
                'created_at': _time,
                'updated_at': _time,
              },
            ('POST', _) => {
                'id': 'f1',
                'request_id': 'fr1',
                'sender_id': 'u1',
                'recipient_id': 'u2',
                'user_username': 'bob',
                'user_alias': null,
                'user_avatar': null,
              },
            ('GET', _) => <Object>[],
            _ => null,
          });
      final request = await c.api.sendFriendRequest('u2');
      expect(request.userUsername, isNull);
      await c.api.getPendingRequests();
      await c.api.getSentRequests();
      final friend = await c.api.acceptFriendRequest('fr1');
      expect(friend.userUsername, 'bob');
      await c.api.rejectFriendRequest('fr1');
      await c.api.getFriends();
      await c.api.unfriend('u2');
      expect(c.sent.first.json, {'user_id': 'u2'});
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'POST /api/users/@me/friends/requests',
        'GET /api/users/@me/friends/requests',
        'GET /api/users/@me/friends/requests/sent',
        'POST /api/users/@me/friends/requests/fr1/accept',
        'DELETE /api/users/@me/friends/requests/fr1',
        'GET /api/users/@me/friends',
        'DELETE /api/users/@me/friends/u2',
      ]);
    });
  });

  group('conversations', () {
    final conversation = {
      'id': 'c1',
      'type': 1,
      'name': null,
      'owner_id': 'u1',
      'created_at': _time,
      'updated_at': _time,
      'deleted_at': null,
      'members': <Object>[],
    };
    final dm = {
      'id': 'd1',
      'conversation_id': 'c1',
      'author_id': 'u1',
      'content': 'yo',
      'type': 0,
      'created_at': _time,
      'updated_at': _time,
    };

    test('create DMs and groups', () async {
      final c = _client((_) => conversation);
      await c.api.createDM('u2');
      await c.api.createGroup('G', ['u2', 'u3']);
      expect(c.sent[0].json, {'type': 1, 'user_id': 'u2'});
      expect(c.sent[1].json, {
        'type': 2,
        'name': 'G',
        'user_ids': ['u2', 'u3'],
      });
    });

    test('messages', () async {
      final c = _client((s) => s.method == 'GET' ? [dm] : dm);
      await c.api.getDirectMessages('c1', before: 'd0');
      await c.api.getDirectMessagesAfter('c1', 'd0');
      expect(c.sent[0].path, '/api/users/@me/conversations/c1/messages');
      expect(c.sent[0].query, {
        'count': ['100'],
        'before': ['d0'],
      });
      expect(c.sent[1].path, '/api/users/@me/conversations/c1/messages/after');
      expect(c.sent[1].query, {
        'count': ['100'],
        'after': ['d0'],
      });
    });

    test('a message\'s thread', () async {
      final c = _client((_) => [
            dm,
            {...dm, 'id': 'd2', 'ref_message_id': 'd1', 'depth': 1},
          ]);
      final thread = await c.api.getConversationMessageThread('c1', 'd1');
      expect(c.sent.single.method, 'GET');
      expect(c.sent.single.path,
          '/api/users/@me/conversations/c1/messages/d1/thread');
      expect(thread.map((m) => m.id), ['d1', 'd2']);
    });

    test('members, pins, typing', () async {
      final c = _client((_) => null);
      await c.api.leaveConversation('c1');
      await c.api.pinConversationMessage('c1', 'd1');
      await c.api.sendConversationTyping('c1');
      await c.api.sendConversationRecording('c1');
      expect(c.sent.map((s) => '${s.method} ${s.path}'), [
        'DELETE /api/users/@me/conversations/c1/members/@me',
        'PUT /api/users/@me/conversations/c1/pins/d1',
        'POST /api/users/@me/conversations/c1/typing',
        'POST /api/users/@me/conversations/c1/recording',
      ]);
    });

    test(
        'no call sends a conversation\'s text or a file in the clear, or '
        'changes its members without a commit', () {
      // Each member of a class, mixin or extension in lib/, from its first
      // line (two spaces in, as dart format sets it) to the next one's,
      // without its comments.
      final members = [
        for (final file in Directory('lib').listSync(recursive: true))
          if (file is File && file.path.endsWith('.dart'))
            for (final member in file
                .readAsStringSync()
                .replaceAll('\r\n', '\n')
                .split(RegExp(r'\n(?=  [A-Za-z_@])')))
              member
                  .split('\n')
                  .where((line) => !line.trimLeft().startsWith('//'))
                  .join('\n'),
      ];
      String name(String member) =>
          RegExp(r'(\w+)\(').firstMatch(member)?[1] ?? member;
      // A message's text, or a form's file whose fields aren't an
      // EncryptedMessage's (whose ciphertext seals the message and names its
      // sealed files).
      bool plain(String member) =>
          member.contains("'content'") ||
          (member.contains('files:') && !member.contains('EncryptedMessage'));
      // The private helpers that post either, to a path their callers give.
      final helpers = {
        for (final member in members)
          if (plain(member))
            if (RegExp(r'^  [^(\n]*?\b(_\w+)\(').firstMatch(member)
                case final helper?)
              helper[1]!,
      };
      final messages = RegExp(r'conversations/\$\{?[\w.]+\}?/messages');
      // A member's addition or removal, not leaving (@me).
      final memberChanges =
          RegExp(r'conversations/\$\{?[\w.]+\}?/members(?!/@me)');
      final toMessages = [
        for (final member in members)
          if (messages.hasMatch(member)) member
      ];
      final toMembers = [
        for (final member in members)
          if (memberChanges.hasMatch(member)) member
      ];

      expect([
        for (final member in toMessages)
          if (plain(member) || helpers.any((h) => member.contains('$h(')))
            name(member),
        for (final member in toMembers)
          if (!member.contains('Commit ')) name(member),
      ], isEmpty);
      // It reads both kinds of call: the history's and end-to-end
      // encryption's.
      expect(helpers, containsAll(['_sendMessage', '_sendVoiceNote']));
      expect(toMessages.map(name),
          containsAll(['getDirectMessages', 'sendMessage', 'editMessage']));
      expect(toMembers.map(name), containsAll(['addMember', 'removeMember']));
    });
  });

  group('interactions', () {
    test('component and command uses', () async {
      final c = _client((_) => {'type': 4});
      expect(
          await c.api.sendComponentInteraction(
              'r1', 'm1', const ComponentUse(customId: 'b', componentType: 2)),
          4);
      await c.api.sendCommandInteraction(
          'r1',
          'app1',
          const CommandUse(id: 'cmd1', name: 'roll', options: [
            UsedOption(name: 'sides', type: CommandOptionType.integer, value: 6)
          ]));
      expect(c.sent[0].path, '/api/interactions');
      expect(c.sent[0].json, {
        'type': 3,
        'room_id': 'r1',
        'message_id': 'm1',
        'data': {'custom_id': 'b', 'component_type': 2},
      });
      expect(c.sent[1].json, {
        'type': 2,
        'room_id': 'r1',
        'application_id': 'app1',
        'data': {
          'id': 'cmd1',
          'name': 'roll',
          'type': 1,
          'options': [
            {'name': 'sides', 'type': 4, 'value': 6}
          ],
        },
      });
    });

    test('a subcommand\'s use, in its group or not (duvetchat/api#163)',
        () async {
      final c = _client((_) => {'type': 4});
      await c.api.useCommand(
          'r1',
          'app1',
          const CommandUse(
              id: 'cmd1',
              name: 'permissions',
              subcommandGroup: 'user',
              subcommand: 'get',
              options: [
                UsedOption(
                    name: 'user', type: CommandOptionType.user, value: 'u1')
              ]));
      await c.api.useCommand(
          'r1',
          'app1',
          const CommandUse(
              id: 'cmd1', name: 'permissions', subcommand: 'reset'));
      expect(c.sent[0].json['data'], {
        'id': 'cmd1',
        'name': 'permissions',
        'type': 1,
        'options': [
          {
            'name': 'user',
            'type': 2,
            'options': [
              {
                'name': 'get',
                'type': 1,
                'options': [
                  {'name': 'user', 'type': 6, 'value': 'u1'}
                ],
              }
            ],
          }
        ],
      });
      expect(c.sent[1].json['data'], {
        'id': 'cmd1',
        'name': 'permissions',
        'type': 1,
        'options': [
          {'name': 'reset', 'type': 1, 'options': []}
        ],
      });
    });

    test('a group without its subcommand fails its assert (debug builds)', () {
      expect(
          () => CommandUse(
              id: 'cmd1', name: 'permissions', subcommandGroup: 'user'),
          throwsA(isA<AssertionError>()));
    });

    test('a use answers the modal the bot opened', () async {
      final modal = {
        'custom_id': 'feedback',
        'title': 'Feedback',
        'components': [
          {'type': 18, 'label': 'What happened?'}
        ],
      };
      final c = _client((s) => s.json['type'] == 3
          ? {'type': 9, 'data': modal, 'application_id': 'app1'}
          : {'type': 5});
      final opened = await c.api.useComponent(
          'r1', 'm1', const ComponentUse(customId: 'b', componentType: 2));
      expect(opened.isModal, isTrue);
      expect(opened.modal, modal);
      expect(opened.applicationId, 'app1');
      final deferred = await c.api
          .useCommand('r1', 'app1', const CommandUse(id: 'cmd1', name: 'roll'));
      expect((deferred.type, deferred.isModal), (5, false));
      expect(c.sent[0].json, {
        'type': 3,
        'room_id': 'r1',
        'message_id': 'm1',
        'data': {'custom_id': 'b', 'component_type': 2},
      });
      expect(c.sent[1].json, {
        'type': 2,
        'room_id': 'r1',
        'application_id': 'app1',
        'data': {'id': 'cmd1', 'name': 'roll', 'type': 1, 'options': []},
      });
    });

    test('submitModal sends the modal\'s answers', () async {
      final c = _client((_) => {'type': 4});
      final answers = [
        {
          'type': 18,
          'id': 1,
          'component': {'type': 4, 'custom_id': 'why', 'value': 'it broke'},
        }
      ];
      final reply = await c.api
          .submitModal('r1', 'app1', 'feedback', answers, messageId: 'm1');
      await c.api.submitModal('r1', 'app1', 'feedback', answers);
      expect(reply.type, 4);
      expect(c.sent[0].path, '/api/interactions');
      expect(c.sent[0].json, {
        'type': 5,
        'room_id': 'r1',
        'application_id': 'app1',
        'message_id': 'm1',
        'data': {'custom_id': 'feedback', 'components': answers},
      });
      expect(c.sent[1].json.containsKey('message_id'), isFalse);
    });

    test('a failed command use forgets the space commands', () async {
      var fail = false;
      final c = _client((s) => s.method == 'GET'
          ? {'applications': <Object>[], 'commands': <Object>[]}
          : fail
              ? http.Response('{"error":"unknown command"}', 404)
              : {'type': 4});
      await c.api.getSpaceCommands('s1');
      await c.api
          .useCommand('r1', 'app1', const CommandUse(id: 'c', name: 'x'));
      await c.api.getSpaceCommands('s1');
      expect(c.sent.where((s) => s.method == 'GET'), hasLength(1));
      fail = true;
      await expectLater(
          c.api.useCommand('r1', 'app1', const CommandUse(id: 'c', name: 'x')),
          throwsA(isA<DuvetApiException>()));
      await c.api.getSpaceCommands('s1');
      expect(c.sent.where((s) => s.method == 'GET'), hasLength(2));
    });

    test('space commands are cached, and a failed list is not', () async {
      var fail = true;
      final c = _client((_) => fail
          ? http.Response('', 500)
          : {'applications': <Object>[], 'commands': <Object>[]});
      await expectLater(
          c.api.getSpaceCommands('s1'), throwsA(isA<DuvetApiException>()));
      fail = false;
      await c.api.getSpaceCommands('s1');
      await c.api.getSpaceCommands('s1');
      expect(c.sent, hasLength(2));
      c.api.forgetSpaceCommands('s1');
      await c.api.getSpaceCommands('s1');
      expect(c.sent, hasLength(3));
    });
  });

  group('users', () {
    test('updateUser sends only what is given', () async {
      final c = _client((_) => {
            'id': 'u1',
            'username': 'me',
            'email': 'a@b.c',
            'email_verified': true,
            'alias': null,
            'birthdate': null,
            'phone': null,
            'avatar': null,
            'banner': null,
            'custom': '',
            'created_at': _time,
            'updated_at': _time,
          });
      await c.api.updateUser(username: 'me');
      await c.api.updateUser(clearAlias: true);
      await c.api.updateUser(alias: 'Me', custom: 'Hi 👋');
      // An empty bio clears it; left out, it stays.
      await c.api.updateUser(custom: '');
      await c.api.updateUser(clearAvatar: true);
      await c.api.updateUser(clearBanner: true);
      await c.api.updateUser(avatar: 'a.png', banner: 'b.png');
      expect(c.sent[0].json, {'username': 'me'});
      expect(c.sent[1].json, {'alias': null});
      expect(c.sent[2].json, {'alias': 'Me', 'custom': 'Hi 👋'});
      expect(c.sent[3].json, {'custom': ''});
      expect(c.sent[4].json, {'avatar': null});
      expect(c.sent[5].json, {'banner': null});
      expect(c.sent[6].json, {'avatar': 'a.png', 'banner': 'b.png'});
    });

    test('setStatus chooses online or do not disturb', () async {
      final c = _client((_) => {
            'id': 'u1',
            'username': 'me',
            'email_verified': true,
            'custom': '',
            'status': 2,
            'created_at': _time,
            'updated_at': _time,
          });
      final me = await c.api.setStatus(UserStatus.dnd);
      await c.api.setStatus(UserStatus.online);
      expect(c.sent[0].method, 'PUT');
      expect(c.sent[0].path, '/api/users/@me/status');
      expect(c.sent[0].json, {'status': 2});
      expect(c.sent[1].json, {'status': 1});
      expect(me.status, UserStatus.dnd);

      // Offline isn't a choice: nothing is sent.
      await expectLater(
          c.api.setStatus(UserStatus.offline), throwsArgumentError);
      expect(c.sent, hasLength(2));
    });

    test('setStatus: a bot\'s refusal keeps its status and body', () async {
      const body = '{"error":"bots cannot access this endpoint"}';
      final c = _client((_) => http.Response(body, 403));
      await expectLater(
          c.api.setStatus(UserStatus.dnd),
          throwsA(isA<DuvetApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.body, 'body', body)));
    });

    test('uploadProfileImage sends the image alone, with its progress',
        () async {
      final c = _client((_) => http.Response('', 500));
      final progress = <(int, int)>[];
      await expectLater(
          c.api.uploadProfileImage(ProfileImageKind.avatar, [1], 'me.jpg',
              onProgress: (sent, total) => progress.add((sent, total))),
          throwsA(isA<DuvetApiException>()));
      final body = c.sent.single.request.body;
      expect(body, isNot(contains('_crop_')));
      final total = c.sent.single.request.bodyBytes.length;
      expect(progress.last, (total, total));
      expect(body, contains('name="avatar"; filename="me.jpg"'));
      expect(body, contains('content-type: image/jpeg'));
    });
  });

  group('acks', () {
    test('at most one per room every interval, with the newest ID', () async {
      final c = _client((_) => null);
      await c.api.ackRoom('r1', '01');
      await c.api.ackRoom('r1', '03');
      await c.api.ackRoom('r1', '02');
      await c.api.ackConversation('c1', '01');
      expect(c.sent.map((s) => s.json['message_id']), ['01', '01']);
      await Future<void>.delayed(
          ackInterval + const Duration(milliseconds: 200));
      expect(c.sent.map((s) => '${s.path} ${s.json['message_id']}'), [
        '/api/rooms/r1/ack 01',
        '/api/users/@me/conversations/c1/ack 01',
        '/api/rooms/r1/ack 03',
      ]);
    });

    test('failures are swallowed', () async {
      final c = _client((_) => http.Response('', 500));
      await c.api.ackRoom('r1', '01');
      expect(c.sent, hasLength(1));
    });
  });

  group('application commands', () {
    const base = '/api/users/@me/teams/t1/applications/a1/commands';
    final command = jsonDecode(
        File('test/fixtures/application_command.full.json')
            .readAsStringSync()) as Map<String, dynamic>;
    const poll = NewCommand(
      name: 'poll',
      description: 'Start a vote',
      options: [
        CommandOption(
          type: CommandOptionType.string,
          name: 'question',
          description: 'What to ask',
          required: true,
          maxLength: 100,
        ),
        CommandOption(
          type: CommandOptionType.integer,
          name: 'hours',
          description: 'How long',
          choices: [CommandChoice(name: 'One day', value: 24)],
        ),
        CommandOption(
          type: CommandOptionType.room,
          name: 'where',
          description: 'Which room',
          roomTypes: [RoomType.text],
        ),
      ],
    );
    final pollJson = {
      'type': 1,
      'name': 'poll',
      'description': 'Start a vote',
      'options': [
        {
          'type': 3,
          'name': 'question',
          'description': 'What to ask',
          'required': true,
          'max_length': 100,
        },
        {
          'type': 4,
          'name': 'hours',
          'description': 'How long',
          'choices': [
            {'name': 'One day', 'value': 24}
          ],
        },
        {
          'type': 7,
          'name': 'where',
          'description': 'Which room',
          'room_types': [1],
        },
      ],
    };

    test('list, get and delete', () async {
      final c = _client((s) => switch (s.method) {
            'GET' when s.path == base => [command],
            'GET' => command,
            _ => null,
          });
      final list = await c.api.listCommands('t1', 'a1');
      final one = await c.api.getCommand('t1', 'a1', 'c1');
      await c.api.deleteCommand('t1', 'a1', 'c1');
      expect(list.single.name, 's-string');
      expect(one.id, command['id']);
      expect([
        for (final s in c.sent) (s.method, s.path)
      ], [
        ('GET', base),
        ('GET', '$base/c1'),
        ('DELETE', '$base/c1'),
      ]);
    });

    test('create sends the command with its options', () async {
      final c = _client((_) => command);
      await c.api.createCommand('t1', 'a1', poll);
      expect((c.sent.single.method, c.sent.single.path), ('POST', base));
      expect(c.sent.single.json, pollJson);
    });

    test('overwrite sends the whole list, an empty one too', () async {
      final c = _client((_) => [command]);
      final saved = await c.api.overwriteCommands('t1', 'a1', [poll]);
      await c.api.overwriteCommands('t1', 'a1', const []);
      expect(saved, hasLength(1));
      expect((c.sent[0].method, c.sent[0].path), ('PUT', base));
      expect(jsonDecode(c.sent[0].request.body), [pollJson]);
      expect(jsonDecode(c.sent[1].request.body), isEmpty);
    });

    test('update sends only what changes; options replace the list', () async {
      final c = _client((_) => command);
      await c.api.updateCommand('t1', 'a1', 'c1', description: 'Vote');
      await c.api.updateCommand('t1', 'a1', 'c1', options: const []);
      expect((c.sent[0].method, c.sent[0].path), ('PATCH', '$base/c1'));
      expect(c.sent[0].json, {'description': 'Vote'});
      expect(c.sent[1].json, {'options': <Object>[]});
    });

    test('a fixture\'s options go back as they came', () {
      final parsed = ApplicationCommand.fromJson(command);
      expect([for (final o in parsed.options) o.toJson()], command['options']);
    });
  });

  // What the app is, as X-Duvet-Client and the identify's client name it: the
  // API takes encryption's routes and a conversation's only from a client
  // that has it.
  group('the client\'s name', () {
    test('every request sends X-Duvet-Client, renewals included', () async {
      final c = _client((s) {
        if (s.path == '/api/auth/refresh') return {'token': 'new'};
        if (s.path == '/api/auth/login') {
          return {'token': 'A', 'session_token': 'S'};
        }
        return s.request.headers['Authorization'] == 'Bearer new'
            ? <Object>[]
            : http.Response('', 401);
      }, duvetClient: 'android/1.1.0');
      await c.api.getFriends();
      await c.api.logIn('a@b.c', 'pw');
      expect(c.sent.map((s) => s.path), [
        '/api/users/@me/friends',
        '/api/auth/refresh',
        '/api/users/@me/friends',
        '/api/auth/login',
      ]);
      for (final s in c.sent) {
        expect(s.request.headers['X-Duvet-Client'], 'android/1.1.0',
            reason: s.path);
      }
    });

    test('a client that names none sends none', () async {
      final c = _client((s) => s.path == '/api/auth/refresh'
          ? {'token': 'new'}
          : s.request.headers['Authorization'] == 'Bearer new'
              ? <Object>[]
              : http.Response('', 401));
      await c.api.getFriends();
      for (final s in c.sent) {
        expect(s.request.headers.containsKey('X-Duvet-Client'), isFalse,
            reason: s.path);
      }
    });

    test('logIn answers the session\'s device challenge', () async {
      final c = _client(
          (_) => {
                'token': 'A',
                'session_token': 'S',
                'device_challenge': 'Y2hhbGxlbmdl',
              },
          token: '',
          sessionToken: '');
      final signIn = await c.api.logIn('a@b.c', 'pw');
      expect(signIn.deviceChallenge, 'Y2hhbGxlbmdl');
      // None from an API before end-to-end encryption.
      final older = _client((_) => {'token': 'A', 'session_token': 'S'},
          token: '', sessionToken: '');
      expect((await older.api.logIn('a@b.c', 'pw')).deviceChallenge, isNull);
    });

    test('resetPassword removes the devices only when asked', () async {
      final c = _client((_) => null);
      await c.api.resetPassword('t', 'pw');
      await c.api.resetPassword('t', 'pw', removeDevices: true);
      expect(c.sent[0].json, {'token': 't', 'password': 'pw'});
      expect(c.sent[1].json,
          {'token': 't', 'password': 'pw', 'remove_devices': true});
    });
  });

  // The API's refusals that an encryption engine tells apart, each a
  // DuvetApiException with its status and body, as every other is.
  group('refusals', () {
    Future<Object> refusal(int status, Object body,
        {Map<String, String> headers = const {}}) async {
      final text = body is String ? body : jsonEncode(body);
      final c = _client((_) => http.Response(text, status, headers: headers),
          duvetClient: 'android/1.0.0');
      try {
        await E2eApi(c.api).devices();
      } catch (e) {
        expect(e, isA<DuvetApiException>());
        final api = e as DuvetApiException;
        expect((api.statusCode, api.body), (status, text));
        return e;
      }
      fail('no refusal');
    }

    test('a 426 says the client and its platform\'s lowest version', () async {
      final e = await refusal(426, {
        'error': 'update Duvet',
        'client': 'android/1.0.0',
        'minimum': '1.1.0',
      }) as DuvetUpdateRequiredException;
      expect((e.client, e.minimum), ('android/1.0.0', '1.1.0'));
      // A client the API couldn't read, of a platform with no encryption yet.
      final none = await refusal(
              426, {'error': 'update Duvet', 'client': null, 'minimum': null})
          as DuvetUpdateRequiredException;
      expect((none.client, none.minimum), (null, null));
    });

    test('a 503 while encryption is paused says when to try again', () async {
      const paused = {'error': 'encrypted conversations are paused'};
      final e = await refusal(503, paused, headers: {'retry-after': '60'})
          as DuvetPausedException;
      expect(e.retryAfter, const Duration(seconds: 60));
      final soon = await refusal(503, paused, headers: {'retry-after': '5'})
          as DuvetPausedException;
      expect(soon.retryAfter, const Duration(seconds: 5));
      // The API's own minute, when the header doesn't read.
      final unsaid = await refusal(503, paused) as DuvetPausedException;
      expect(unsaid.retryAfter, const Duration(seconds: 60));
    });

    test('any other 503 reads as before', () async {
      final e = await refusal(
          503, {'error': 'too many writes are waiting for their conversations'},
          headers: {'retry-after': '1'});
      expect(e.runtimeType, DuvetApiException);
      expect((e as DuvetApiException).retryAfter, const Duration(seconds: 1));
    });

    test('a refusal says how long the API asks to wait, when it does',
        () async {
      const limited = {'error': 'too many requests'};
      final e = await refusal(429, limited, headers: {'retry-after': '37'})
          as DuvetApiException;
      expect(e.retryAfter, const Duration(seconds: 37));
      // A refusal the engine tells apart carries it too.
      final stale = await refusal(
          409, {'error': 'stale message', 'generation': 1, 'epoch': 9},
          headers: {'retry-after': '2'}) as DuvetStaleMessageException;
      expect(stale.retryAfter, const Duration(seconds: 2));
      // None said, or none that reads as seconds: null.
      for (final headers in [
        <String, String>{},
        {'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'},
        {'retry-after': '-1'},
        {'retry-after': 'soon'},
      ]) {
        final unsaid =
            await refusal(429, limited, headers: headers) as DuvetApiException;
        expect(unsaid.retryAfter, isNull, reason: '$headers');
      }
    });

    test('the 409s the engine tells apart, with what each carries', () async {
      final stale = await refusal(
              409, {'error': 'stale message', 'generation': 1, 'epoch': 9})
          as DuvetStaleMessageException;
      expect((stale.generation, stale.epoch), (1, 9));
      final taken = await refusal(409, {
        'error': 'another commit took this epoch',
        'generation': 0,
        'epoch': 4
      }) as DuvetEpochTakenException;
      expect((taken.generation, taken.epoch), (0, 4));
      final identity = await refusal(
              409, {'error': 'identity changed', 'identity_key': 'a2V5'})
          as DuvetIdentityChangedException;
      expect(identity.identityKey, 'a2V5');
      // A user who has none any more.
      final gone = await refusal(
              409, {'error': 'identity changed', 'identity_key': null})
          as DuvetIdentityChangedException;
      expect(gone.identityKey, isNull);
      final list = await refusal(409, {
        'error': 'device list changed',
        'device_list': 'bGlzdA==',
        'version': 3
      }) as DuvetDeviceListChangedException;
      expect((list.deviceList, list.version), ('bGlzdA==', 3));
    });

    test('a 422 names its code', () async {
      final e = await refusal(
              422, {'error': 'commit refused', 'code': 'removes_last_member'})
          as DuvetCommitRefusedException;
      expect(e.code, 'removes_last_member');
    });

    test('any other 409 or 422 reads as before', () async {
      for (final (status, body) in [
        (409, {'error': 'inbox full'}),
        (409, {'error': 'another segment holds this day', 'current': 'g1'}),
        (409, 'not json'),
        (422, {'error': 'this space has no storage bucket'}),
        (422, {'error': 'another refusal', 'code': 'removes_last_member'}),
      ]) {
        final e = await refusal(status, body);
        expect(e.runtimeType, DuvetApiException, reason: '$body');
      }
    });
  });

  // Every end-to-end encryption route, as the API takes and answers it.
  group('end-to-end encryption', () {
    const conv = '/api/users/@me/conversations/c1';
    ({E2eApi e2e, List<Sent> sent}) e2e(Object? Function(Sent) reply) {
      final c = _client(reply, duvetClient: 'android/1.1.0');
      return (e2e: E2eApi(c.api), sent: c.sent);
    }

    String route(Sent s) => '${s.method} ${s.path}';
    final entry = {
      'seq': 5,
      'kind': 'edit',
      'data': 'AQID',
      'sent_at': 1764000000000,
      'generation': 0,
      'epoch': 2,
      'message_id': 'm1',
      'sender_user': 'u1',
      'sender_device': 'd1',
    };
    final device = {
      'id': 'd1',
      'name': 'Pixel 8 Pro',
      'client': 'android/1.1.0',
      'listed': false,
      'created_at': _time,
      'last_seen_at': _time,
      'current': true,
    };
    const commit = Commit(
        generation: 0,
        epoch: 3,
        commit: 'Y29tbWl0',
        groupInfo: 'aW5mbw==',
        welcome: 'd2VsY29tZQ==');
    final taken = {'seq': 8, 'generation': 0, 'epoch': 4, 'welcome_seq': 9};

    test('the configuration', () async {
      final limits = {
        'ciphertext_bytes': 32768,
        'key_packages': 100,
        'last_resort_key_packages': 1,
        'key_package_bytes': 4096,
        'inbox_message_bytes': 65536,
        'history_share_parts': 64,
        'history_share_part_bytes': 1048592,
        'group_members': 20,
        'listed_devices': 20,
        'commit_bytes': 262144,
        'welcome_bytes': 1048576,
        'group_info_bytes': 1048576,
        'encrypted_identity_bytes': 1024,
        'wrapped_backup_key_bytes': 1024,
        'wrapped_previous_backup_keys_bytes': 65536,
        'certificate_bytes': 1024,
        'device_list_bytes': 4096,
        'epochs_behind': 5,
      };
      final c = e2e((_) => {
            'external_sender': 'c2VuZGVy',
            'cutover_at': '2026-12-01T00:00:00Z',
            'paused': true,
            'min_clients': {'android': '1.1.0', 'web': '1.2.0'},
            'limits': limits,
          });
      final config = await c.e2e.config();
      expect(route(c.sent.single), 'GET /api/e2e');
      expect((config.externalSender, config.cutoverAt, config.paused),
          ('c2VuZGVy', DateTime.utc(2026, 12), true));
      expect(config.minClients, {'android': '1.1.0', 'web': '1.2.0'});
      final l = config.limits;
      expect([
        l.ciphertextBytes,
        l.keyPackages,
        l.lastResortKeyPackages,
        l.keyPackageBytes,
        l.inboxMessageBytes,
        l.historyShareParts,
        l.historySharePartBytes,
        l.groupMembers,
        l.listedDevices,
        l.commitBytes,
        l.welcomeBytes,
        l.groupInfoBytes,
        l.encryptedIdentityBytes,
        l.wrappedBackupKeyBytes,
        l.wrappedPreviousBackupKeysBytes,
        l.certificateBytes,
        l.deviceListBytes,
        l.epochsBehind,
      ], limits.values.toList());
      // No cutover yet.
      final before = e2e((_) => {
            'external_sender': 'c2VuZGVy',
            'cutover_at': null,
            'paused': false,
            'min_clients': <String, String>{},
            'limits': limits,
          });
      expect((await before.e2e.config()).cutoverAt, isNull);
      // An API without its external sender's key, which makes no group.
      final none = e2e((_) => {
            'external_sender': null,
            'cutover_at': null,
            'paused': false,
            'min_clients': <String, String>{},
            'limits': limits,
          });
      expect((await none.e2e.config()).externalSender, isNull);
    });

    test('devices, and the session\'s binding to one', () async {
      final c = e2e((s) => switch (route(s)) {
            'POST /api/users/@me/devices/challenge' => {
                'device_challenge': 'Y2hhbGxlbmdl'
              },
            'POST /api/users/@me/devices' => device,
            'GET /api/users/@me/devices' => [
                device,
                {...device, 'id': 'd2', 'listed': true, 'current': false}
              ],
            _ => null,
          });
      expect(await c.e2e.deviceChallenge(), 'Y2hhbGxlbmdl');
      final registered = await c.e2e.registerDevice(const DeviceRegistration(
          deviceId: 'd1',
          name: 'Pixel 8 Pro',
          signatureKey: 'c2ln',
          hpkeKey: 'aHBrZQ==',
          proof: 'cHJvb2Y='));
      await c.e2e.bindDevice('d1', 'cHJvb2Y=');
      final devices = await c.e2e.devices();
      await c.e2e.deleteDevice('d2');
      expect(c.sent.map(route), [
        'POST /api/users/@me/devices/challenge',
        'POST /api/users/@me/devices',
        'POST /api/users/@me/devices/d1/bind',
        'GET /api/users/@me/devices',
        'DELETE /api/users/@me/devices/d2',
      ]);
      expect(c.sent[1].json, {
        'device_id': 'd1',
        'name': 'Pixel 8 Pro',
        'signature_key': 'c2ln',
        'hpke_key': 'aHBrZQ==',
        'proof': 'cHJvb2Y=',
      });
      expect(c.sent[2].json, {'proof': 'cHJvb2Y='});
      expect((
        registered.id,
        registered.name,
        registered.client,
        registered.listed,
        registered.current,
        registered.createdAt,
        registered.lastSeenAt
      ), (
        'd1',
        'Pixel 8 Pro',
        'android/1.1.0',
        false,
        true,
        DateTime.parse(_time),
        DateTime.parse(_time)
      ));
      expect(devices.map((d) => (d.id, d.listed, d.current)),
          [('d1', false, true), ('d2', true, false)]);
    });

    test('the identity and its device list', () async {
      final identity = {
        'user_id': 'u2',
        'identity_key': 'aWQ=',
        'device_list': 'bGlzdA==',
        'device_list_version': 3,
        'certificates': ['Y2VydA==', 'Y2VydDI='],
        'active': false,
        'changed_at': _time,
      };
      final c = e2e((s) => switch (route(s)) {
            'PUT /api/users/@me/identity' => {
                'identity_id': 'i1',
                'device_list_version': 1
              },
            'PUT /api/users/@me/device-list' => {'version': 4},
            'GET /api/users/u2/identity' => identity,
            'GET /api/users/identities' => [identity],
            _ => {
                'identity_key': 'aWQ=',
                'device_list': 'bGlzdA==',
                'encrypted_identity': 'ZW5j',
                'wrapped_backup_key': 'd3JhcA==',
                'wrapped_previous_backup_keys': null,
                'replaced': s.query.isEmpty
                    ? [
                        {'identity_id': 'i0', 'replaced_at': _time}
                      ]
                    : null,
              },
          });
      // The first identity, then a rotation with a transfer.
      final published = await c.e2e.putIdentity(const IdentityUpload(
          identityKey: 'aWQ=',
          deviceList: 'bGlzdA==',
          certificate: 'Y2VydA==',
          encryptedIdentity: 'ZW5j',
          wrappedBackupKey: 'd3JhcA=='));
      await c.e2e.putIdentity(const IdentityUpload(
          identityKey: 'aWQy',
          deviceList: 'bGlzdDI=',
          certificate: 'Y2VydDM=',
          encryptedIdentity: 'ZW5jMg==',
          wrappedBackupKey: 'd3JhcDI=',
          wrappedPreviousBackupKeys: 'cHJldg==',
          replaces: 'aWQ=',
          transfers: [
            IdentityTransfer(
                deviceId: 'd2', certificate: 'Y2VydDQ=', message: 'dHJhbnM=')
          ]));
      await c.e2e.putIdentity(const IdentityUpload(
          identityKey: 'aWQz',
          deviceList: 'bGlzdDM=',
          certificate: 'Y2VydDU=',
          encryptedIdentity: 'ZW5jMw==',
          wrappedBackupKey: 'd3JhcDM=',
          replaces: 'aWQy',
          reset: true));
      final version = await c.e2e.putDeviceList(
          const DeviceListUpload(deviceList: 'bGlzdDQ=', baseVersion: 3));
      await c.e2e.putDeviceList(const DeviceListUpload(
          deviceList: 'bGlzdDU=', baseVersion: 4, certificate: 'Y2VydDY='));
      final one = await c.e2e.identity('u2');
      final many = await c.e2e.identities(['u2', 'u3']);
      final backup = await c.e2e.identityBackup();
      final replaced = await c.e2e.identityBackup(identity: 'i0');

      expect(c.sent[0].json, {
        'identity_key': 'aWQ=',
        'device_list': 'bGlzdA==',
        'certificate': 'Y2VydA==',
        'encrypted_identity': 'ZW5j',
        'wrapped_backup_key': 'd3JhcA==',
        'replaces': null,
      });
      expect(c.sent[1].json, {
        'identity_key': 'aWQy',
        'device_list': 'bGlzdDI=',
        'certificate': 'Y2VydDM=',
        'encrypted_identity': 'ZW5jMg==',
        'wrapped_backup_key': 'd3JhcDI=',
        'wrapped_previous_backup_keys': 'cHJldg==',
        'replaces': 'aWQ=',
        'transfers': [
          {'device_id': 'd2', 'certificate': 'Y2VydDQ=', 'message': 'dHJhbnM='}
        ],
      });
      expect(c.sent[2].json['reset'], isTrue);
      expect((published.identityId, published.deviceListVersion), ('i1', 1));
      expect(route(c.sent[3]), 'PUT /api/users/@me/device-list');
      expect(c.sent[3].json, {'device_list': 'bGlzdDQ=', 'base_version': 3});
      expect(c.sent[4].json, {
        'device_list': 'bGlzdDU=',
        'base_version': 4,
        'certificate': 'Y2VydDY='
      });
      expect(version, 4);
      expect((
        one.userId,
        one.identityKey,
        one.deviceList,
        one.deviceListVersion,
        one.active,
        one.changedAt
      ), (
        'u2',
        'aWQ=',
        'bGlzdA==',
        3,
        false,
        DateTime.parse(_time)
      ));
      expect(one.certificates, ['Y2VydA==', 'Y2VydDI=']);
      expect(c.sent[6].query, {
        'ids': ['u2,u3']
      });
      expect(many.single.userId, 'u2');
      expect(route(c.sent[7]), 'GET /api/users/@me/identity/backup');
      expect(c.sent[7].query, isEmpty);
      expect((
        backup.identityKey,
        backup.deviceList,
        backup.encryptedIdentity,
        backup.wrappedBackupKey,
        backup.wrappedPreviousBackupKeys
      ), (
        'aWQ=',
        'bGlzdA==',
        'ZW5j',
        'd3JhcA==',
        null
      ));
      expect(backup.replaced.map((r) => (r.identityId, r.replacedAt)),
          [('i0', DateTime.parse(_time))]);
      // One starting over replaced, whose backup is still kept.
      expect(c.sent[8].query, {
        'identity': ['i0']
      });
      expect(replaced.replaced, isEmpty);
    });

    test('key packages', () async {
      final c = e2e((s) => s.method == 'PUT'
          ? {
              'handed_out': ['a3Ax']
            }
          : {
              'key_packages': [
                {'device_id': 'd2', 'data': 'a3A='},
                {'device_id': 'd3', 'data': 'a3Ay'},
              ]
            });
      final handedOut = await c.e2e.putKeyPackages(const [
        KeyPackageUpload(id: 'a3Ax', data: 'a3A=', expiresAt: 1767000000000),
        KeyPackageUpload(
            id: 'bGFzdA==',
            data: 'bGFzdA==',
            expiresAt: 1767000000000,
            lastResort: true),
      ]);
      final claimed = await c.e2e.claimKeyPackages('u2');
      expect(c.sent.map(route), [
        'PUT /api/users/@me/devices/@me/key-packages',
        'POST /api/users/u2/key-packages/claim',
      ]);
      expect(c.sent[0].json, {
        'key_packages': [
          {
            'id': 'a3Ax',
            'data': 'a3A=',
            'expires_at': 1767000000000,
            'last_resort': false
          },
          {
            'id': 'bGFzdA==',
            'data': 'bGFzdA==',
            'expires_at': 1767000000000,
            'last_resort': true
          },
        ]
      });
      expect(handedOut, ['a3Ax']);
      expect(claimed.map((k) => (k.deviceId, k.data)),
          [('d2', 'a3A='), ('d3', 'a3Ay')]);
      // None handed out yet.
      final none = e2e((_) => {'handed_out': <String>[]});
      expect(await none.e2e.putKeyPackages(const []), isEmpty);
    });

    test('a conversation\'s group: its group info, a commit and its queue',
        () async {
      final c = e2e((s) => switch (route(s)) {
            'GET $conv/mls/group-info' => {
                'generation': 1,
                'epoch': 6,
                'group_info': 'aW5mbw=='
              },
            'POST $conv/mls/commits' => taken,
            _ => {
                'entries': [entry],
                'last_seq': 5,
                'floor_seq': 1,
                'generation': 0,
                'epoch': 2
              },
          });
      final info = await c.e2e.groupInfo('c1');
      final created = await c.e2e.commit(
          'c1',
          const Commit(
              generation: 0,
              epoch: 0,
              commit: 'Y29tbWl0',
              groupInfo: 'aW5mbw==',
              initialGroupInfo: 'aW5pdA==',
              welcome: 'd2VsY29tZQ=='));
      await c.e2e.commit(
          'c1',
          const Commit(
              generation: 0, epoch: 1, commit: 'Yw==', groupInfo: 'aQ=='));
      final page = await c.e2e.queue('c1', 4, limit: 50);
      await c.e2e.queue('c1', 0);
      expect(c.sent.map(route), [
        'GET $conv/mls/group-info',
        'POST $conv/mls/commits',
        'POST $conv/mls/commits',
        'GET $conv/mls/queue',
        'GET $conv/mls/queue',
      ]);
      expect((info.generation, info.epoch, info.groupInfo), (1, 6, 'aW5mbw=='));
      expect(c.sent[1].json, {
        'generation': 0,
        'epoch': 0,
        'commit': 'Y29tbWl0',
        'group_info': 'aW5mbw==',
        'initial_group_info': 'aW5pdA==',
        'welcome': 'd2VsY29tZQ==',
      });
      expect(c.sent[2].json, {
        'generation': 0,
        'epoch': 1,
        'commit': 'Yw==',
        'group_info': 'aQ=='
      });
      expect(
          (created.seq, created.generation, created.epoch, created.welcomeSeq),
          (8, 0, 4, 9));
      expect(c.sent[3].query, {
        'after': ['4'],
        'limit': ['50']
      });
      expect(c.sent[4].query, {
        'after': ['0']
      });
      expect((page.lastSeq, page.floorSeq, page.generation, page.epoch),
          (5, 1, 0, 2));
      final e = page.entries.single;
      expect((
        e.seq,
        e.kind,
        e.data,
        e.sentAt,
        e.messageId,
        e.senderUser,
        e.senderDevice,
        e.deleted
      ), (
        5,
        'edit',
        'AQID',
        1764000000000,
        'm1',
        'u1',
        'd1',
        false
      ));
    });

    test('members: an addition and a removal are commits, leaving a statement',
        () async {
      final c = e2e((s) => switch (route(s)) {
            'POST $conv/members' => {
                'id': 'cm3',
                'conversation_id': 'c1',
                'user_id': 'u3',
                'created_at': _time,
                'updated_at': _time,
                'status_id': 1,
                'commit': taken,
              },
            'DELETE $conv/members/u3' => {
                'seq': 10,
                'generation': 0,
                'epoch': 5
              },
            _ => null,
          });
      final added = await c.e2e.addMember('c1', 'u3', commit);
      final removed = await c.e2e.removeMember(
          'c1',
          'u3',
          const Commit(
              generation: 0, epoch: 4, commit: 'Yw==', groupInfo: 'aQ=='));
      await c.e2e.leave('c1', statement: 'c3Q=');
      await c.e2e.leave('c1');
      expect(c.sent.map(route), [
        'POST $conv/members',
        'DELETE $conv/members/u3',
        'DELETE $conv/members/@me',
        'DELETE $conv/members/@me',
      ]);
      expect(c.sent[0].json, {
        'user_id': 'u3',
        'generation': 0,
        'epoch': 3,
        'commit': 'Y29tbWl0',
        'group_info': 'aW5mbw==',
        'welcome': 'd2VsY29tZQ==',
      });
      expect((
        added.userId,
        added.statusId,
        added.commit.seq,
        added.commit.welcomeSeq
      ), (
        'u3',
        UserStatus.online,
        8,
        9
      ));
      expect(c.sent[1].json, {
        'generation': 0,
        'epoch': 4,
        'commit': 'Yw==',
        'group_info': 'aQ=='
      });
      expect((removed.seq, removed.epoch, removed.welcomeSeq), (10, 5, null));
      expect(c.sent[2].json, {'statement': 'c3Q='});
      // A conversation without a group: no statement, no body.
      expect((c.sent[3].request.body, c.sent[3].contentType), ('', null));
    });

    final sentMessage = {
      'id': 'm1',
      'conversation_id': 'c1',
      'author_id': 'u1',
      'content': null,
      'type': 0,
      'created_at': _time,
      'updated_at': _time,
      'nonce': 'n1',
      'ciphertext': 'Y2lwaGVy',
      'seq': 12,
      'sent_at': 1764000000123,
      'generation': 0,
      'epoch': 2,
      'sender_device_id': 'd1',
      'mentions': ['u2'],
      'attachments': <Object>[],
      'reactions': <Object>[],
    };

    test('messages: sent, edited, deleted, and the deleted ones listed',
        () async {
      final c = e2e((s) => switch (route(s)) {
            'POST $conv/messages' => sentMessage,
            'PATCH $conv/messages/m1' => {
                'id': 'm1',
                'edited_at': _time,
                'entry': entry
              },
            'DELETE $conv/messages/m1' => {
                'id': 'm1',
                'entry': {...entry, 'kind': 'delete', 'seq': 6}
              },
            _ => {
                'ids': ['m0', 'm1']
              },
          });
      final message = await c.e2e.sendMessage(
          'c1',
          const EncryptedMessage(
              ciphertext: 'Y2lwaGVy',
              nonce: 'n1',
              mentions: ['u2'],
              messageReference: MessageReference(
                  type: MessageReferenceType.reply, messageId: 'm0'),
              allowedMentions: AllowedMentions(repliedUser: false),
              stickerAttachmentId: 'st1'));
      final edited = await c.e2e.editMessage('c1', 'm1', 'ZWRpdA==');
      final deleted = await c.e2e.deleteMessage('c1', 'm1', 'dG9tYg==');
      final gone = await c.e2e.deletedMessages('c1', after: 'm', limit: 10);
      await c.e2e.deletedMessages('c1');
      expect(c.sent.map(route), [
        'POST $conv/messages',
        'PATCH $conv/messages/m1',
        'DELETE $conv/messages/m1',
        'GET $conv/messages/deleted',
        'GET $conv/messages/deleted',
      ]);
      // No content: conversations are end-to-end encrypted.
      expect(c.sent[0].json, {
        'ciphertext': 'Y2lwaGVy',
        'nonce': 'n1',
        'mentions': ['u2'],
        'message_reference': {'type': 0, 'message_id': 'm0'},
        'allowed_mentions': {'replied_user': false},
        'sticker_attachment_id': 'st1',
      });
      expect((message.id, message.ciphertext, message.seq, message.nonce),
          ('m1', 'Y2lwaGVy', 12, 'n1'));
      expect(c.sent[1].json, {'ciphertext': 'ZWRpdA=='});
      expect((edited.id, edited.editedAt, edited.entry.seq),
          ('m1', DateTime.parse(_time), 5));
      expect(c.sent[2].json, {'ciphertext': 'dG9tYg=='});
      expect((deleted.id, deleted.entry.kind, deleted.entry.seq),
          ('m1', 'delete', 6));
      expect(c.sent[3].query, {
        'after': ['m'],
        'limit': ['10']
      });
      expect(c.sent[4].query, isEmpty);
      expect(gone, ['m0', 'm1']);
    });

    test('a message\'s sealed files go up in a form, each after its ID',
        () async {
      final c = e2e((_) => sentMessage);
      final progress = <(int, int)>[];
      await c.e2e.sendMessage(
          'c1',
          const EncryptedMessage(
              ciphertext: 'Y2lwaGVy',
              nonce: 'n1',
              mentions: ['u2', 'u3'],
              messageReference: MessageReference(messageId: 'm0'),
              attachmentIds: ['a1', 'a2']),
          files: [
            [1, 2, 3],
            [4, 5]
          ],
          onProgress: (sent, total) => progress.add((sent, total)));
      final s = c.sent.single;
      expect(route(s), 'POST $conv/messages');
      expect(s.contentType, startsWith('multipart/form-data; boundary='));
      expect(s.request.headers['X-Duvet-Client'], 'android/1.1.0');
      // A list repeats its field, as a value: no file name.
      expect(_parts(s).map((p) => (p.name, p.filename, p.content)), [
        ('ciphertext', null, 'Y2lwaGVy'),
        ('nonce', null, 'n1'),
        ('message_reference', null, '{"message_id":"m0"}'),
        ('mentions', null, 'u2'),
        ('mentions', null, 'u3'),
        ('attachment_ids', null, 'a1'),
        ('attachment_ids', null, 'a2'),
        ('files', 'file', '\x01\x02\x03'),
        ('files', 'file', '\x04\x05'),
      ]);
      expect(
          s.request.body,
          contains('content-type: application/octet-stream\r\n'
              'content-disposition: form-data; name="files"; filename="file"'));
      expect(progress.last.$1, s.request.bodyBytes.length);
    });

    test('the inbox between devices', () async {
      final c = e2e((s) => switch (route(s)) {
            'POST /api/devices/d2/inbox' => {'id': 'i1'},
            'GET /api/users/@me/devices/@me/inbox' => [
                {
                  'id': 'i1',
                  'from_user_id': 'u2',
                  'from_device_id': 'd2',
                  'message': 'bWVzc2FnZQ==',
                  'created_at': _time,
                }
              ],
            _ => null,
          });
      expect(await c.e2e.sendToDevice('d2', 'bWVzc2FnZQ=='), 'i1');
      final inbox = await c.e2e.inbox(after: 'i0', limit: 50);
      await c.e2e.inbox();
      await c.e2e.clearInbox('i1');
      expect(c.sent.map(route), [
        'POST /api/devices/d2/inbox',
        'GET /api/users/@me/devices/@me/inbox',
        'GET /api/users/@me/devices/@me/inbox',
        'DELETE /api/users/@me/devices/@me/inbox',
      ]);
      expect(c.sent[0].json, {'message': 'bWVzc2FnZQ=='});
      expect(c.sent[1].query, {
        'after': ['i0'],
        'limit': ['50']
      });
      expect(c.sent[2].query, isEmpty);
      expect(c.sent[3].query, {
        'through': ['i1']
      });
      final m = inbox.single;
      expect((m.id, m.fromUserId, m.fromDeviceId, m.message, m.createdAt),
          ('i1', 'u2', 'd2', 'bWVzc2FnZQ==', DateTime.parse(_time)));
    });

    final share = {
      'id': 's1',
      'conversation_id': 'c1',
      'from_user_id': 'u1',
      'kind': 'share',
      'range': 'week',
      'starts_at': '2026-11-18T00:00:00Z',
      'size': 1048609,
      'parts': 2,
    };

    test('shared history: a package, its parts, its completion and its ack',
        () async {
      final c = e2e((s) => switch (route(s)) {
            'PUT $conv/history-shares/s1' => share,
            'GET /api/users/@me/history-shares' => [
                share,
                {...share, 'id': 's2', 'kind': 'catch_up', 'range': null}
              ],
            _ => null,
          });
      final made = await c.e2e.putShare(
          'c1',
          's1',
          HistoryShareUpload(
              toUserId: 'u2',
              kind: 'share',
              range: 'week',
              startsAt: DateTime.utc(2026, 11, 18),
              size: 1048609,
              parts: 2));
      await c.e2e.putShare(
          'c1',
          's1',
          HistoryShareUpload(
              toUserId: 'u2',
              kind: 'catch_up',
              startsAt: DateTime.utc(2026, 11, 18),
              size: 17,
              parts: 1));
      final progress = <(int, int)>[];
      await c.e2e.putSharePart('c1', 's1', 0, List.filled(100 * 1024, 9),
          onProgress: (sent, total) => progress.add((sent, total)));
      await c.e2e.completeShare('c1', 's1');
      final shares = await c.e2e.shares();
      await c.e2e.ackShare('s1');
      expect(c.sent.map(route), [
        'PUT $conv/history-shares/s1',
        'PUT $conv/history-shares/s1',
        'PUT $conv/history-shares/s1/parts/0',
        'POST $conv/history-shares/s1/complete',
        'GET /api/users/@me/history-shares',
        'POST /api/history-shares/s1/ack',
      ]);
      expect(c.sent[0].json, {
        'to_user_id': 'u2',
        'kind': 'share',
        'range': 'week',
        'starts_at': '2026-11-18T00:00:00.000Z',
        'size': 1048609,
        'parts': 2,
      });
      // A catch-up has no range.
      expect(c.sent[1].json.containsKey('range'), isFalse);
      expect((
        made.id,
        made.conversationId,
        made.fromUserId,
        made.kind,
        made.range,
        made.startsAt,
        made.size,
        made.parts
      ), (
        's1',
        'c1',
        'u1',
        'share',
        'week',
        DateTime.utc(2026, 11, 18),
        1048609,
        2
      ));
      // The part goes as it is, with the session's headers.
      final part = c.sent[2];
      expect(part.contentType, 'application/octet-stream');
      expect(part.request.bodyBytes, List.filled(100 * 1024, 9));
      expect(part.request.headers['Authorization'], 'Bearer tok');
      expect(part.request.headers['X-Duvet-Client'], 'android/1.1.0');
      expect(progress.last, (100 * 1024, 100 * 1024));
      expect(progress.length, greaterThan(1));
      expect(shares.map((s) => (s.id, s.kind, s.range)),
          [('s1', 'share', 'week'), ('s2', 'catch_up', null)]);
    });

    test('the backup: its segments listed, one put in its day\'s place',
        () async {
      final segment = {
        'id': 'g1',
        'conversation_id': 'c1',
        'day': '2026-11-24',
        'complete': true,
        'key_id': 'a2V5aWQ=',
        'size': 2048,
        'created_at': _time,
      };
      final c = e2e((s) => s.method == 'PUT' ? {'id': 'g2'} : [segment]);
      final segments = await c.e2e
          .segments(conversationId: 'c1', after: 'g0', identity: 'i0');
      await c.e2e.segments();
      final id =
          await c.e2e.putSegment('c1', '2026-11-24', [1, 2, 3], replaces: 'g1');
      await c.e2e.putSegment('c1', '2026-11-25', [4]);
      expect(c.sent.map(route), [
        'GET /api/users/@me/backup/segments',
        'GET /api/users/@me/backup/segments',
        'PUT /api/users/@me/backup/segments/c1/2026-11-24',
        'PUT /api/users/@me/backup/segments/c1/2026-11-25',
      ]);
      expect(c.sent[0].query, {
        'conversation_id': ['c1'],
        'after': ['g0'],
        'identity': ['i0'],
      });
      expect(c.sent[1].query, isEmpty);
      final s = segments.single;
      expect((
        s.id,
        s.conversationId,
        s.day,
        s.complete,
        s.keyId,
        s.size,
        s.createdAt
      ), (
        'g1',
        'c1',
        '2026-11-24',
        true,
        'a2V5aWQ=',
        2048,
        DateTime.parse(_time)
      ));
      expect(id, 'g2');
      expect(c.sent[2].query, {
        'replaces': ['g1']
      });
      expect(c.sent[2].contentType, 'application/octet-stream');
      expect(c.sent[2].request.bodyBytes, [1, 2, 3]);
      // It saw none of that day.
      expect(c.sent[3].query, {
        'replaces': ['none']
      });
    });

    test('decryption failures: a kind and how many, and staff\'s counts',
        () async {
      final c = e2e((s) => s.method == 'GET'
          ? [
              {
                'day': '2026-11-24',
                'kind': 'message',
                'client': 'android',
                'version': '1.1.0',
                'count': 3
              }
            ]
          : null);
      await c.e2e.reportDecryptFailure('message');
      await c.e2e.reportDecryptFailure('welcome', count: 4);
      final counts =
          await c.e2e.decryptFailures(from: '2026-11-01', to: '2026-11-24');
      await c.e2e.decryptFailures();
      expect(c.sent.map(route), [
        'POST /api/e2e/decrypt-failures',
        'POST /api/e2e/decrypt-failures',
        'GET /api/internal/e2e/decrypt-failures',
        'GET /api/internal/e2e/decrypt-failures',
      ]);
      expect(c.sent[0].json, {'kind': 'message'});
      expect(c.sent[1].json, {'kind': 'welcome', 'count': 4});
      expect(c.sent[2].query, {
        'from': ['2026-11-01'],
        'to': ['2026-11-24']
      });
      expect(c.sent[3].query, isEmpty);
      final count = counts.single;
      expect((count.day, count.kind, count.client, count.version, count.count),
          ('2026-11-24', 'message', 'android', '1.1.0', 3));
    });
  });

  // A part's, a segment's or an encrypted attachment's file, at the URL the
  // API signed for it: fetched with none of the app's headers, which a
  // redirect would carry to the storage.
  group('signed downloads', () {
    test(
        'a part and a segment come from the URL their route answers, '
        'with none of the app\'s headers', () async {
      final c = _client((s) {
        if (s.path.startsWith('/attachments/')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        final file = s.path.contains('history-shares') ? 'a1' : 'a2';
        return {'url': '/attachments/$file?sig=ab%2Bc/d&exp=9'};
      }, duvetClient: 'android/1.1.0');
      final e2e = E2eApi(c.api);
      expect(await e2e.sharePart('s1', 1), [1, 2, 3]);
      expect(await e2e.segment('g1'), [1, 2, 3]);
      expect(c.sent.map((s) => '${s.method} ${s.request.url}'), [
        'GET https://api.duvet.chat/api/history-shares/s1/parts/1',
        // The query as the API signed it, untouched.
        'GET https://api.duvet.chat/attachments/a1?sig=ab%2Bc/d&exp=9',
        'GET https://api.duvet.chat/api/users/@me/backup/segments/g1',
        'GET https://api.duvet.chat/attachments/a2?sig=ab%2Bc/d&exp=9',
      ]);
      // The routes go with the session; the files with nothing of the app's.
      for (final s in [c.sent[0], c.sent[2]]) {
        expect(s.request.headers['Authorization'], 'Bearer tok');
      }
      for (final s in [c.sent[1], c.sent[3]]) {
        expect(s.request.headers.keys.map((k) => k.toLowerCase()),
            isNot(anyElement(isIn(_appHeaders))));
      }
    });

    test('an attachment\'s signed URL: its bytes, with progress as they come',
        () async {
      final requests = <http.BaseRequest>[];
      final api = RestClient(MockClient.streaming((request, _) async {
        requests.add(request);
        return http.StreamedResponse(
            Stream.fromIterable([
              [1, 2, 3],
              [4, 5, 6, 7]
            ]),
            200,
            contentLength: 7);
      }), token: 'tok', sessionToken: 'sess', duvetClient: 'android/1.1.0');
      final progress = <(int, int)>[];
      final bytes = await E2eApi(api).signedFile(
          'https://api.duvet.chat/attachments/a1?sig=x&exp=9',
          onProgress: (received, total) => progress.add((received, total)));
      expect(bytes, [1, 2, 3, 4, 5, 6, 7]);
      expect(progress, [(3, 7), (7, 7)]);
      expect(requests.single.url.toString(),
          'https://api.duvet.chat/attachments/a1?sig=x&exp=9');
      expect(requests.single.headers.keys.map((k) => k.toLowerCase()),
          isNot(anyElement(isIn(_appHeaders))));
    });

    test('a length the answer doesn\'t say is -1', () async {
      final api = RestClient(MockClient.streaming((request, _) async {
        return http.StreamedResponse(Stream.value([1, 2]), 200);
      }));
      final progress = <(int, int)>[];
      await E2eApi(api).signedFile('/attachments/a1?sig=x&exp=9',
          onProgress: (received, total) => progress.add((received, total)));
      expect(progress, [(2, -1)]);
    });

    test('a refused download is the storage\'s, not the session\'s', () async {
      final c = _client((_) => http.Response('expired', 403));
      await expectLater(
          E2eApi(c.api).signedFile('/attachments/a1?sig=x&exp=1'),
          throwsA(isA<DuvetApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e, 'type', isNot(isA<DuvetAuthException>()))));
      // No renewal: the session has nothing to do with it.
      expect(c.sent, hasLength(1));
    });

    test('a limited download says the wait it was given', () async {
      final c = _client((_) =>
          http.Response('slow down', 429, headers: {'retry-after': '12'}));
      await expectLater(
          E2eApi(c.api).signedFile('/attachments/a1?sig=x&exp=9'),
          throwsA(isA<DuvetApiException>().having(
              (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 12))));
    });

    test('a download that stops arriving fails with TimeoutException',
        () async {
      final api = RestClient(
          MockClient.streaming((request, _) async => http.StreamedResponse(
              Stream.fromFuture(Completer<List<int>>().future), 200)),
          requestTimeout: const Duration(milliseconds: 100));
      await expectLater(E2eApi(api).signedFile('/attachments/a1?sig=x&exp=9'),
          throwsA(isA<TimeoutException>()));
    });
  });
}
