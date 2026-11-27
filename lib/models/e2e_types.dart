part of 'types.dart';

// ---------------------------------------------------------------------------
// End-to-end encryption: the objects E2eApi's routes send and answer, and the
// gateway's encryption events. Binary fields are standard base64,
// padded, as the API sends them and the core takes them.
// ---------------------------------------------------------------------------

List<String> _strings(Object? j) =>
    [for (final e in j as List<dynamic>? ?? const []) e as String];

/// What a client needs of end-to-end encryption before it reads or writes a
/// conversation (`GET /api/e2e`).
class E2eConfig {
  /// The public key the API signs its proposals to remove a device from a
  /// group with: the engine keeps the first it sees. Null on an API without
  /// one, which makes no group.
  final String? externalSender;

  /// When the conversations from before end-to-end encryption lost their
  /// messages; null before the cutover.
  final DateTime? cutoverAt;

  /// Whether the conversations' writes are paused (`DuvetPausedException`).
  final bool paused;

  /// The lowest version with end-to-end encryption, by platform
  /// (`android`: `1.1.0`): a platform it doesn't name has none yet.
  final Map<String, String> minClients;
  final E2eLimits limits;

  const E2eConfig({
    this.externalSender,
    this.cutoverAt,
    required this.paused,
    required this.minClients,
    required this.limits,
  });

  E2eConfig.fromJson(Map<String, dynamic> j)
      : externalSender = j['external_sender'] as String?,
        cutoverAt = _parseDate(j['cutover_at']),
        paused = j['paused'] as bool,
        minClients = {
          for (final MapEntry(:key, :value)
              in (j['min_clients'] as Map<String, dynamic>? ?? const {})
                  .entries)
            key: value as String,
        },
        limits = E2eLimits.fromJson(j['limits'] as Map<String, dynamic>);
}

/// The limits a client builds what it sends to: sizes in bytes, and counts.
class E2eLimits {
  final int ciphertextBytes;
  final int keyPackages;
  final int lastResortKeyPackages;
  final int keyPackageBytes;
  final int inboxMessageBytes;
  final int historyShareParts;
  final int historySharePartBytes;
  final int groupMembers;
  final int listedDevices;
  final int commitBytes;
  final int welcomeBytes;
  final int groupInfoBytes;
  final int encryptedIdentityBytes;
  final int wrappedBackupKeyBytes;
  final int wrappedPreviousBackupKeysBytes;
  final int certificateBytes;
  final int deviceListBytes;

  /// How many epochs behind its group a message may be made.
  final int epochsBehind;

  const E2eLimits({
    required this.ciphertextBytes,
    required this.keyPackages,
    required this.lastResortKeyPackages,
    required this.keyPackageBytes,
    required this.inboxMessageBytes,
    required this.historyShareParts,
    required this.historySharePartBytes,
    required this.groupMembers,
    required this.listedDevices,
    required this.commitBytes,
    required this.welcomeBytes,
    required this.groupInfoBytes,
    required this.encryptedIdentityBytes,
    required this.wrappedBackupKeyBytes,
    required this.wrappedPreviousBackupKeysBytes,
    required this.certificateBytes,
    required this.deviceListBytes,
    required this.epochsBehind,
  });

  E2eLimits.fromJson(Map<String, dynamic> j)
      : ciphertextBytes = j['ciphertext_bytes'] as int,
        keyPackages = j['key_packages'] as int,
        lastResortKeyPackages = j['last_resort_key_packages'] as int,
        keyPackageBytes = j['key_package_bytes'] as int,
        inboxMessageBytes = j['inbox_message_bytes'] as int,
        historyShareParts = j['history_share_parts'] as int,
        historySharePartBytes = j['history_share_part_bytes'] as int,
        groupMembers = j['group_members'] as int,
        listedDevices = j['listed_devices'] as int,
        commitBytes = j['commit_bytes'] as int,
        welcomeBytes = j['welcome_bytes'] as int,
        groupInfoBytes = j['group_info_bytes'] as int,
        encryptedIdentityBytes = j['encrypted_identity_bytes'] as int,
        wrappedBackupKeyBytes = j['wrapped_backup_key_bytes'] as int,
        wrappedPreviousBackupKeysBytes =
            j['wrapped_previous_backup_keys_bytes'] as int,
        certificateBytes = j['certificate_bytes'] as int,
        deviceListBytes = j['device_list_bytes'] as int,
        epochsBehind = j['epochs_behind'] as int;
}

// Devices

/// A device of the user's, as DEVICE_ADD gives it to every session of theirs.
class UserDevice {
  final String id;
  final String name;

  /// What registered it, as its `X-Duvet-Client` said (`android/1.1.0`).
  final String client;

  /// On the user's signed device list.
  final bool listed;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  const UserDevice({
    required this.id,
    required this.name,
    required this.client,
    required this.listed,
    required this.createdAt,
    required this.lastSeenAt,
  });

  UserDevice.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        client = j['client'] as String,
        listed = j['listed'] as bool,
        createdAt = DateTime.parse(j['created_at'] as String),
        lastSeenAt = DateTime.parse(j['last_seen_at'] as String);
}

/// A device of the user's as the list of them gives it: [current] when it's
/// the one the request's session is bound to.
class Device extends UserDevice {
  final bool current;

  const Device({
    required super.id,
    required super.name,
    required super.client,
    required super.listed,
    required super.createdAt,
    required super.lastSeenAt,
    required this.current,
  });

  Device.fromJson(super.j)
      : current = j['current'] as bool? ?? false,
        super.fromJson();
}

/// A device's registration: its ID (the core's), its name (64 characters at
/// most), its keys and its proof, which its signature key signs over the
/// session's challenge.
class DeviceRegistration {
  final String deviceId;
  final String name;
  final String signatureKey;
  final String hpkeKey;
  final String proof;

  const DeviceRegistration({
    required this.deviceId,
    required this.name,
    required this.signatureKey,
    required this.hpkeKey,
    required this.proof,
  });

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'name': name,
        'signature_key': signatureKey,
        'hpke_key': hpkeKey,
        'proof': proof,
      };
}

// The identity and its device list

/// What `PUT …/identity` publishes: the identity, its device list and this
/// device's certificate, both signed by it, and what the API keeps for the
/// user's recovery. [replaces] is the identity key it replaces, null for the
/// first; a rotation brings a [transfers] for each other device that stays,
/// and starting over sets [reset].
class IdentityUpload {
  final String identityKey;
  final String deviceList;
  final String certificate;
  final String encryptedIdentity;
  final String wrappedBackupKey;
  final String? wrappedPreviousBackupKeys;
  final String? replaces;
  final bool reset;
  final List<IdentityTransfer> transfers;

  const IdentityUpload({
    required this.identityKey,
    required this.deviceList,
    required this.certificate,
    required this.encryptedIdentity,
    required this.wrappedBackupKey,
    this.wrappedPreviousBackupKeys,
    this.replaces,
    this.reset = false,
    this.transfers = const [],
  });

  Map<String, dynamic> toJson() => {
        'identity_key': identityKey,
        'device_list': deviceList,
        'certificate': certificate,
        'encrypted_identity': encryptedIdentity,
        'wrapped_backup_key': wrappedBackupKey,
        if (wrappedPreviousBackupKeys != null)
          'wrapped_previous_backup_keys': wrappedPreviousBackupKeys,
        'replaces': replaces,
        if (reset) 'reset': true,
        if (transfers.isNotEmpty)
          'transfers': [for (final t in transfers) t.toJson()],
      };
}

/// A rotation's for a device that stays: its certificate from the new
/// identity, and the transfer sealed to it, which goes to its inbox.
class IdentityTransfer {
  final String deviceId;
  final String certificate;
  final String message;

  const IdentityTransfer(
      {required this.deviceId,
      required this.certificate,
      required this.message});

  Map<String, dynamic> toJson() =>
      {'device_id': deviceId, 'certificate': certificate, 'message': message};
}

/// What publishing an identity answers. Its 409 is
/// `DuvetIdentityChangedException`.
class IdentityPublished {
  final String identityId;
  final int deviceListVersion;

  const IdentityPublished(
      {required this.identityId, required this.deviceListVersion});

  IdentityPublished.fromJson(Map<String, dynamic> j)
      : identityId = j['identity_id'] as String,
        deviceListVersion = j['device_list_version'] as int;
}

/// `PUT …/device-list`: the list, the version it was signed on top of, and
/// this device's certificate when the list brings it. Its 409 is
/// `DuvetDeviceListChangedException`.
class DeviceListUpload {
  final String deviceList;
  final int baseVersion;
  final String? certificate;

  const DeviceListUpload(
      {required this.deviceList, required this.baseVersion, this.certificate});

  Map<String, dynamic> toJson() => {
        'device_list': deviceList,
        'base_version': baseVersion,
        if (certificate != null) 'certificate': certificate,
      };
}

/// A user's identity, as the core's observe_user takes it: its key, their
/// device list and its version, and the listed devices' certificates.
class Identity {
  final String userId;
  final String identityKey;
  final String deviceList;
  final int deviceListVersion;
  final List<String> certificates;

  /// False when no listed device of theirs connected lately.
  final bool active;

  /// When this identity took the place of the one before.
  final DateTime changedAt;

  const Identity({
    required this.userId,
    required this.identityKey,
    required this.deviceList,
    required this.deviceListVersion,
    required this.certificates,
    required this.active,
    required this.changedAt,
  });

  Identity.fromJson(Map<String, dynamic> j)
      : userId = j['user_id'] as String,
        identityKey = j['identity_key'] as String,
        deviceList = j['device_list'] as String,
        deviceListVersion = j['device_list_version'] as int,
        certificates = _strings(j['certificates']),
        active = j['active'] as bool,
        changedAt = DateTime.parse(j['changed_at'] as String);
}

/// What the core's recover takes of an identity of the user's, and the
/// identities starting over replaced whose backups are still kept.
class IdentityBackup {
  final String identityKey;
  final String deviceList;
  final String encryptedIdentity;
  final String wrappedBackupKey;

  /// The backup keys from before a rotation; null until one.
  final String? wrappedPreviousBackupKeys;

  /// The identities starting over replaced whose backups are still kept,
  /// the latest first: `E2eApi.identityBackup(identity:)` reads one's.
  final List<ReplacedIdentity> replaced;

  const IdentityBackup({
    required this.identityKey,
    required this.deviceList,
    required this.encryptedIdentity,
    required this.wrappedBackupKey,
    this.wrappedPreviousBackupKeys,
    this.replaced = const [],
  });

  IdentityBackup.fromJson(Map<String, dynamic> j)
      : identityKey = j['identity_key'] as String,
        deviceList = j['device_list'] as String,
        encryptedIdentity = j['encrypted_identity'] as String,
        wrappedBackupKey = j['wrapped_backup_key'] as String,
        wrappedPreviousBackupKeys =
            j['wrapped_previous_backup_keys'] as String?,
        replaced = [
          for (final r in j['replaced'] as List<dynamic>? ?? const [])
            ReplacedIdentity.fromJson(r as Map<String, dynamic>),
        ];
}

/// An identity starting over replaced, whose backup is still kept.
class ReplacedIdentity {
  final String identityId;
  final DateTime? replacedAt;

  const ReplacedIdentity({required this.identityId, this.replacedAt});

  ReplacedIdentity.fromJson(Map<String, dynamic> j)
      : identityId = j['identity_id'] as String,
        replacedAt = _parseDate(j['replaced_at']);
}

// Key packages

/// A key package as the core's key_packages makes it: its ID, the key
/// package, when it expires (Unix milliseconds), and whether it's the one of
/// last resort.
class KeyPackageUpload {
  final String id;
  final String data;
  final int expiresAt;
  final bool lastResort;

  const KeyPackageUpload({
    required this.id,
    required this.data,
    required this.expiresAt,
    this.lastResort = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'data': data,
        'expires_at': expiresAt,
        'last_resort': lastResort,
      };
}

/// A key package a claim hands out, for one listed device of the user.
class ClaimedKeyPackage {
  final String deviceId;
  final String data;

  const ClaimedKeyPackage({required this.deviceId, required this.data});

  ClaimedKeyPackage.fromJson(Map<String, dynamic> j)
      : deviceId = j['device_id'] as String,
        data = j['data'] as String;
}

// A conversation's group

/// A conversation's MLS group as its object shows it: its generation and
/// epoch, its queue's last number and the number it's whole from, and the
/// number from which this session's device has had a leaf in it, null
/// without one.
class ConversationGroup {
  final int generation;
  final int epoch;
  final int lastSeq;
  final int floorSeq;
  final int? joinedSeq;

  const ConversationGroup({
    required this.generation,
    required this.epoch,
    required this.lastSeq,
    required this.floorSeq,
    this.joinedSeq,
  });

  ConversationGroup.fromJson(Map<String, dynamic> j)
      : generation = j['generation'] as int,
        epoch = j['epoch'] as int,
        lastSeq = j['last_seq'] as int,
        floorSeq = j['floor_seq'] as int,
        joinedSeq = j['joined_seq'] as int?;
}

/// What a member's device joins a conversation's group by, with an external
/// commit.
class MlsGroupInfo {
  final int generation;
  final int epoch;
  final String groupInfo;

  const MlsGroupInfo(
      {required this.generation, required this.epoch, required this.groupInfo});

  MlsGroupInfo.fromJson(Map<String, dynamic> j)
      : generation = j['generation'] as int,
        epoch = j['epoch'] as int,
        groupInfo = j['group_info'] as String;
}

/// A commit as the core makes it, with the group info of the epoch it makes;
/// a group's creation adds epoch 0's group info and its welcome.
class Commit {
  final int generation;
  final int epoch;
  final String commit;
  final String groupInfo;
  final String? initialGroupInfo;
  final String? welcome;

  const Commit({
    required this.generation,
    required this.epoch,
    required this.commit,
    required this.groupInfo,
    this.initialGroupInfo,
    this.welcome,
  });

  Map<String, dynamic> toJson() => {
        'generation': generation,
        'epoch': epoch,
        'commit': commit,
        'group_info': groupInfo,
        if (initialGroupInfo != null) 'initial_group_info': initialGroupInfo,
        if (welcome != null) 'welcome': welcome,
      };
}

/// A commit the API took: its number, the group's generation and epoch after
/// it, and its welcome's number. A commit another took the epoch of is a
/// `DuvetEpochTakenException`; one the validator refused, a
/// `DuvetCommitRefusedException`.
class CommitTaken {
  final int seq;
  final int generation;
  final int epoch;
  final int? welcomeSeq;

  const CommitTaken({
    required this.seq,
    required this.generation,
    required this.epoch,
    this.welcomeSeq,
  });

  CommitTaken.fromJson(Map<String, dynamic> j)
      : seq = j['seq'] as int,
        generation = j['generation'] as int,
        epoch = j['epoch'] as int,
        welcomeSeq = j['welcome_seq'] as int?;
}

/// An entry of a conversation's queue, what the core's apply takes: its
/// number, its [kind] (commit, welcome, proposal, message, edit or delete)
/// and its MLS message, when the API took it (Unix milliseconds), the
/// group's generation and epoch it's of, and who sent it, but for the API's
/// own proposals, which carry the [statement] of whoever left. A message's,
/// an edit's and a deletion's [messageId] is the message's; a message's also
/// says whom it [mentions] and what it replies to.
class MlsEntry {
  final int seq;
  final String kind;

  /// Null in an event's entry past 16 KiB, which the queue gives whole; null
  /// or empty in one [deleted], whose bytes are gone.
  final String? data;
  final int sentAt;
  final int generation;
  final int epoch;
  final String? messageId;
  final String? senderUser;
  final String? senderDevice;
  final String? statement;

  /// A deleted message, or an edit of one: not a failure to decrypt.
  final bool deleted;
  final List<String> mentions;
  final String? replyTo;

  const MlsEntry({
    required this.seq,
    required this.kind,
    this.data,
    required this.sentAt,
    required this.generation,
    required this.epoch,
    this.messageId,
    this.senderUser,
    this.senderDevice,
    this.statement,
    this.deleted = false,
    this.mentions = const [],
    this.replyTo,
  });

  MlsEntry.fromJson(Map<String, dynamic> j)
      : seq = j['seq'] as int,
        kind = j['kind'] as String,
        data = j['data'] as String?,
        sentAt = j['sent_at'] as int,
        generation = j['generation'] as int,
        epoch = j['epoch'] as int,
        messageId = j['message_id'] as String?,
        senderUser = j['sender_user'] as String?,
        senderDevice = j['sender_device'] as String?,
        statement = j['statement'] as String?,
        deleted = j['deleted'] as bool? ?? false,
        mentions = _strings(j['mentions']),
        replyTo = j['reply_to'] as String?;
}

/// A page of a conversation's queue, and the group as it was when its
/// entries were read. A read from below [floorSeq] is a 410 (`queue
/// expired`): the device joins again by external commit.
class QueuePage {
  final List<MlsEntry> entries;
  final int lastSeq;
  final int floorSeq;
  final int generation;
  final int epoch;

  const QueuePage({
    required this.entries,
    required this.lastSeq,
    required this.floorSeq,
    required this.generation,
    required this.epoch,
  });

  QueuePage.fromJson(Map<String, dynamic> j)
      : entries = [
          for (final e in j['entries'] as List<dynamic>? ?? const [])
            MlsEntry.fromJson(e as Map<String, dynamic>),
        ],
        lastSeq = j['last_seq'] as int,
        floorSeq = j['floor_seq'] as int,
        generation = j['generation'] as int,
        epoch = j['epoch'] as int;
}

/// An addition's answer: the member, as the conversations list gives them,
/// and the commit that added them.
class MemberAdded extends ConversationMember {
  final CommitTaken commit;

  const MemberAdded({
    required super.id,
    required super.conversationId,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.clientStatus,
    super.user,
    super.statusId,
    required this.commit,
  });

  MemberAdded.fromJson(super.j)
      : commit = CommitTaken.fromJson(j['commit'] as Map<String, dynamic>),
        super.fromJson();
}

// Messages

/// An encrypted message as a device sends it: its MLS message, its nonce
/// (a UUIDv4 in text), whom it mentions, what it replies to, its sticker, and
/// the IDs its files go up with, in their order.
class EncryptedMessage {
  final String ciphertext;
  final String nonce;
  final List<String> mentions;
  final MessageReference? messageReference;
  final AllowedMentions? allowedMentions;
  final String? stickerAttachmentId;
  final List<String> attachmentIds;

  const EncryptedMessage({
    required this.ciphertext,
    required this.nonce,
    this.mentions = const [],
    this.messageReference,
    this.allowedMentions,
    this.stickerAttachmentId,
    this.attachmentIds = const [],
  });

  Map<String, dynamic> toJson() => {
        'ciphertext': ciphertext,
        'nonce': nonce,
        if (mentions.isNotEmpty) 'mentions': mentions,
        if (messageReference != null)
          'message_reference': messageReference!.toJson(),
        if (allowedMentions != null)
          'allowed_mentions': allowedMentions!.toJson(),
        if (stickerAttachmentId != null)
          'sticker_attachment_id': stickerAttachmentId,
        if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
      };
}

/// An edit's answer: when, and its entry, which the core applies.
class MessageEdited {
  final String id;
  final DateTime editedAt;
  final MlsEntry entry;

  const MessageEdited(
      {required this.id, required this.editedAt, required this.entry});

  MessageEdited.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        editedAt = DateTime.parse(j['edited_at'] as String),
        entry = MlsEntry.fromJson(j['entry'] as Map<String, dynamic>);
}

/// A deletion's answer: its tombstone's entry.
class MessageDeleted {
  final String id;
  final MlsEntry entry;

  const MessageDeleted({required this.id, required this.entry});

  MessageDeleted.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        entry = MlsEntry.fromJson(j['entry'] as Map<String, dynamic>);
}

/// What a history share's notice ([MessageType.historyShare]) says: with
/// whom its author shared the conversation's history, and how far back
/// (day, week, month or all).
class ShareNotice {
  final String toUserId;
  final String range;

  const ShareNotice({required this.toUserId, required this.range});

  ShareNotice.fromJson(Map<String, dynamic> j)
      : toUserId = j['to_user_id'] as String,
        range = j['range'] as String;
}

// The inbox between devices

/// A message in this device's inbox, from another device, which the API
/// never opened.
class InboxMessage {
  final String id;
  final String fromUserId;
  final String fromDeviceId;
  final String message;
  final DateTime createdAt;

  const InboxMessage({
    required this.id,
    required this.fromUserId,
    required this.fromDeviceId,
    required this.message,
    required this.createdAt,
  });

  InboxMessage.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        fromUserId = j['from_user_id'] as String,
        fromDeviceId = j['from_device_id'] as String,
        message = j['message'] as String,
        createdAt = DateTime.parse(j['created_at'] as String);
}

// Shared history

/// A shared history package going up: its recipient, its [kind] (share or
/// catch_up), how far back a share goes (day, week, month or all; none for a
/// catch-up), the time from which it holds every message, and its parts'
/// bytes together and how many they are, as the core cut it.
class HistoryShareUpload {
  final String toUserId;
  final String kind;
  final String? range;
  final DateTime startsAt;
  final int size;
  final int parts;

  const HistoryShareUpload({
    required this.toUserId,
    required this.kind,
    this.range,
    required this.startsAt,
    required this.size,
    required this.parts,
  });

  Map<String, dynamic> toJson() => {
        'to_user_id': toUserId,
        'kind': kind,
        if (range != null) 'range': range,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'size': size,
        'parts': parts,
      };
}

/// A shared history package as its recipient gets it (HISTORY_SHARE_CREATE,
/// `E2eApi.shares`), and as making it answers: from whom, its [kind] (share
/// or catch_up), how far back a share goes (null for a catch-up), the time
/// from which it holds every message, its size and its parts. Its key comes
/// by the inbox.
class HistoryShare {
  final String id;
  final String conversationId;
  final String fromUserId;
  final String kind;
  final String? range;
  final DateTime startsAt;
  final int size;
  final int parts;

  const HistoryShare({
    required this.id,
    required this.conversationId,
    required this.fromUserId,
    required this.kind,
    this.range,
    required this.startsAt,
    required this.size,
    required this.parts,
  });

  HistoryShare.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        conversationId = j['conversation_id'] as String,
        fromUserId = j['from_user_id'] as String,
        kind = j['kind'] as String,
        range = j['range'] as String?,
        startsAt = DateTime.parse(j['starts_at'] as String),
        size = j['size'] as int,
        parts = j['parts'] as int;
}

// The encrypted backup

/// A day of the user's backup, as the API keeps it.
class BackupSegment {
  final String id;
  final String conversationId;

  /// YYYY-MM-DD, in UTC.
  final String day;
  final bool complete;
  final String keyId;
  final int size;
  final DateTime createdAt;

  const BackupSegment({
    required this.id,
    required this.conversationId,
    required this.day,
    required this.complete,
    required this.keyId,
    required this.size,
    required this.createdAt,
  });

  BackupSegment.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        conversationId = j['conversation_id'] as String,
        day = j['day'] as String,
        complete = j['complete'] as bool,
        keyId = j['key_id'] as String,
        size = j['size'] as int,
        createdAt = DateTime.parse(j['created_at'] as String);
}

// Decryption failures

/// A day's count of a kind of failure to decrypt, by client and version
/// (staff only).
class DecryptFailureCount {
  final String day;
  final String kind;
  final String client;
  final String version;
  final int count;

  const DecryptFailureCount({
    required this.day,
    required this.kind,
    required this.client,
    required this.version,
    required this.count,
  });

  DecryptFailureCount.fromJson(Map<String, dynamic> j)
      : day = j['day'] as String,
        kind = j['kind'] as String,
        client = j['client'] as String,
        version = j['version'] as String,
        count = j['count'] as int;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// MLS_COMMIT: a commit entered a conversation's group, to its members: the
/// group's generation and epoch after it, and its entry.
class MlsCommitEvent {
  final String conversationId;
  final int generation;
  final int epoch;
  final MlsEntry entry;

  const MlsCommitEvent({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.entry,
  });

  MlsCommitEvent.fromJson(Map<String, dynamic> j)
      : conversationId = j['conversation_id'] as String,
        generation = j['generation'] as int,
        epoch = j['epoch'] as int,
        entry = MlsEntry.fromJson(j['entry'] as Map<String, dynamic>);
}

/// MLS_PROPOSAL: the API proposed a leaf's removal, to the group's members:
/// the generation and epoch it's of, and its entry.
typedef MlsProposalEvent = MlsCommitEvent;

/// MLS_WELCOME: a welcome brings [devices] into a conversation's group, to
/// each user it brings devices of: the group's generation and the epoch they
/// join at, and its entry.
class MlsWelcomeEvent {
  final String conversationId;
  final int generation;
  final int epoch;
  final List<String> devices;
  final MlsEntry entry;

  const MlsWelcomeEvent({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.devices,
    required this.entry,
  });

  MlsWelcomeEvent.fromJson(Map<String, dynamic> j)
      : conversationId = j['conversation_id'] as String,
        generation = j['generation'] as int,
        epoch = j['epoch'] as int,
        devices = _strings(j['devices']),
        entry = MlsEntry.fromJson(j['entry'] as Map<String, dynamic>);
}

/// DM_MESSAGE_UPDATE from an API with end-to-end encryption: an encrypted
/// message was edited: when, and the edit's entry, which the core opens. No
/// text: the device's own database has it.
class DMMessageUpdateEvent {
  final String id;
  final String conversationId;
  final DateTime editedAt;
  final MlsEntry entry;

  const DMMessageUpdateEvent({
    required this.id,
    required this.conversationId,
    required this.editedAt,
    required this.entry,
  });

  DMMessageUpdateEvent.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        conversationId = j['conversation_id'] as String,
        editedAt = DateTime.parse(j['edited_at'] as String),
        entry = MlsEntry.fromJson(j['entry'] as Map<String, dynamic>);
}

/// DEVICE_MESSAGE: a message waits in a device's inbox, to that device's
/// connections alone. Nothing of it: the engine reads it from the inbox.
class DeviceMessageEvent {
  final String deviceId;
  final String id;

  const DeviceMessageEvent({required this.deviceId, required this.id});

  DeviceMessageEvent.fromJson(Map<String, dynamic> j)
      : deviceId = j['device_id'] as String,
        id = j['id'] as String;
}

/// KEY_PACKAGES_LOW: a device has fewer than 20 single-use key packages left
/// to hand out, to its own connections.
class KeyPackagesLowEvent {
  final String deviceId;
  final int remaining;

  const KeyPackagesLowEvent({required this.deviceId, required this.remaining});

  KeyPackagesLowEvent.fromJson(Map<String, dynamic> j)
      : deviceId = j['device_id'] as String,
        remaining = j['remaining'] as int;
}

/// DEVICE_REMOVE: a device of the user's was removed.
class DeviceRemoveEvent {
  final String deviceId;

  const DeviceRemoveEvent({required this.deviceId});

  DeviceRemoveEvent.fromJson(Map<String, dynamic> j)
      : deviceId = j['device_id'] as String;
}

/// IDENTITY_UPDATE: a user's identity or device list changed, to them, their
/// friends and whoever shares a conversation with them, who read it again to
/// observe it.
class IdentityUpdateEvent {
  final String userId;
  final String identityKey;
  final int deviceListVersion;

  const IdentityUpdateEvent({
    required this.userId,
    required this.identityKey,
    required this.deviceListVersion,
  });

  IdentityUpdateEvent.fromJson(Map<String, dynamic> j)
      : userId = j['user_id'] as String,
        identityKey = j['identity_key'] as String,
        deviceListVersion = j['device_list_version'] as int;
}

class MlsCommitPayloadEvent extends GatewayEventPayload {
  final MlsCommitEvent data;
  const MlsCommitPayloadEvent(this.data);
}

class MlsProposalPayloadEvent extends GatewayEventPayload {
  final MlsProposalEvent data;
  const MlsProposalPayloadEvent(this.data);
}

class MlsWelcomePayloadEvent extends GatewayEventPayload {
  final MlsWelcomeEvent data;
  const MlsWelcomePayloadEvent(this.data);
}

/// DM_MESSAGE_UPDATE of an encrypted message ([DMMessageUpdateEvent]). An API
/// before end-to-end encryption sends the message, a [DMMessageUpdatedEvent].
class DMMessageEditedEvent extends GatewayEventPayload {
  final DMMessageUpdateEvent data;
  const DMMessageEditedEvent(this.data);
}

class DeviceMessagePayloadEvent extends GatewayEventPayload {
  final DeviceMessageEvent data;
  const DeviceMessagePayloadEvent(this.data);
}

class KeyPackagesLowPayloadEvent extends GatewayEventPayload {
  final KeyPackagesLowEvent data;
  const KeyPackagesLowPayloadEvent(this.data);
}

/// DEVICE_ADD: a device the user registered, to every session of theirs.
class DeviceAddedEvent extends GatewayEventPayload {
  final UserDevice data;
  const DeviceAddedEvent(this.data);
}

class DeviceRemovedEvent extends GatewayEventPayload {
  final DeviceRemoveEvent data;
  const DeviceRemovedEvent(this.data);
}

class IdentityUpdatedEvent extends GatewayEventPayload {
  final IdentityUpdateEvent data;
  const IdentityUpdatedEvent(this.data);
}

/// HISTORY_SHARE_CREATE: a package its sender completed, to its recipient's
/// sessions alone.
class HistoryShareCreatedEvent extends GatewayEventPayload {
  final HistoryShare data;
  const HistoryShareCreatedEvent(this.data);
}
