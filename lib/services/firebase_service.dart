import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import '../models/tracking_session.dart';

class FirebaseService {
  // ✅ FIXED: Using the correct Asia-Southeast region database URL
  static final DatabaseReference _db = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: 'https://friend-finder-hackathon-e9f5f-default-rtdb.asia-southeast1.firebasedatabase.app',
  ).ref();

  // 1. REGISTER DEVICE (So you appear in the global list)
  static Future<void> registerDevice(String deviceId, String deviceName) async {
    print("💾 [FIREBASE] Registering device: $deviceId");
    await _db.child('devices/$deviceId').set({
      'name': deviceName,
      'online': true,
      'lastSeen': ServerValue.timestamp,
    });
  }

  // 1b. UPDATE DEVICE LOCATION
  static Future<void> updateDeviceLocation(String deviceId, double lat, double lng, [double heading = 0.0]) async {
    await _db.child('devices/$deviceId').update({
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'lastSeen': ServerValue.timestamp,
    });
  }

  // 2. GET ALL DEVICES (Global Discovery)
  static Stream<List<Map<String, dynamic>>> getAllDevicesStream() {
    return _db.child('devices').onValue.map((event) {
      final List<Map<String, dynamic>> devices = [];
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> data =
            event.snapshot.value as Map<dynamic, dynamic>;
        data.forEach((key, value) {
          final deviceData = Map<String, dynamic>.from(value as Map);
          deviceData['id'] = key;
          devices.add(deviceData);
        });
      }
      return devices;
    });
  }

  // 3. START SESSION (For the Tracker)
  static Future<String> startDirectSession(String myDeviceId, String targetId) async {
    // Create the session
    final sessionRef = _db.child('tracking_sessions').push();
    final String sessionId = sessionRef.key!;

    await sessionRef.set({
      'deviceA': myDeviceId, // Tracker
      'deviceB': targetId,   // Target
      'active': true,
      'createdAt': ServerValue.timestamp,
    });

    // Force-write an invite to the target's folder
    await _db.child('users/$targetId/instant_invite').set({
      'sessionId': sessionId,
      'fromId': myDeviceId,
      'timestamp': ServerValue.timestamp,
    });

    return sessionId;
  }

  // 4. LISTEN FOR SESSION (For the Target)
  static Stream<Map<String, dynamic>?> listenForInstantInvite(String myDeviceId) {
    return _db.child('users/$myDeviceId/instant_invite').onValue.map((event) {
      if (event.snapshot.value != null) {
        return Map<String, dynamic>.from(event.snapshot.value as Map);
      }
      return null;
    });
  }

  // 5. CLEANUP INVITE
  static Future<void> clearInstantInvite(String myDeviceId) async {
    await _db.child('users/$myDeviceId/instant_invite').remove();
  }
  
  // 6. TRACKING UPDATES
  static Future<void> updateLocation(String sessionId, String deviceId,
      double lat, double lng, double heading) async {
    await _db.child('tracking_sessions/$sessionId/$deviceId').set({
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'timestamp': ServerValue.timestamp,
    });
  }

  static Stream<LocationData?> listenToLocation(String sessionId, String deviceId) {
    return _db.child('tracking_sessions/$sessionId/$deviceId').onValue.map((event) {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        return LocationData.fromMap(data);
      }
      return null;
    });
  }

  // 6b. LISTEN TO DEVICE GLOBAL LOCATION
  static Stream<LocationData?> listenToDeviceLocation(String deviceId) {
    return _db.child('devices/$deviceId').onValue.map((event) {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        if (data['lat'] != null && data['lng'] != null) {
          return LocationData.fromMap(data);
        }
      }
      return null;
    });
  }

  // 7. END SESSION
  static Future<void> endTrackingSession(String sessionId) async {
    await _db.child('tracking_sessions/$sessionId').remove();
  }

  // 8. UPDATE DEVICE ONLINE STATUS
  static Future<void> setDeviceOnline(String deviceId, bool online) async {
    await _db.child('devices/$deviceId').update({
      'online': online,
      'lastSeen': ServerValue.timestamp,
    });
  }

  // 9. CLEANUP ON DISCONNECT (Optional but recommended)
  static Future<void> setupDisconnectHandlers(String deviceId) async {
    // This will automatically set the device offline when disconnected
    await _db.child('devices/$deviceId/online').onDisconnect().set(false);
    await _db.child('devices/$deviceId/lastSeen').onDisconnect().set(ServerValue.timestamp);
  }

  // ✅ NEW: 10. STORE BLUETOOTH DEVICE ID (For Bluetooth tracking)
  static Future<void> updateBluetoothId(String sessionId, String deviceId, String bluetoothId) async {
    print("📡 [FIREBASE] Storing Bluetooth ID for $deviceId: $bluetoothId");
    await _db.child('tracking_sessions/$sessionId/$deviceId/bluetoothId').set(bluetoothId);
  }

  // ✅ NEW: 11. GET OTHER DEVICE'S BLUETOOTH ID
  static Stream<String?> listenToBluetoothId(String sessionId, String deviceId) {
    return _db.child('tracking_sessions/$sessionId/$deviceId/bluetoothId').onValue.map((event) {
      if (event.snapshot.value != null) {
        final bluetoothId = event.snapshot.value.toString();
        print("📡 [FIREBASE] Got Bluetooth ID for $deviceId: $bluetoothId");
        return bluetoothId;
      }
      return null;
    });
  }

  // ✅ NEW: 12. GET BLUETOOTH ID (One-time fetch, not stream)
  static Future<String?> getBluetoothId(String sessionId, String deviceId) async {
    final snapshot = await _db.child('tracking_sessions/$sessionId/$deviceId/bluetoothId').get();
    if (snapshot.exists) {
      return snapshot.value.toString();
    }
    return null;
  }

  // ── COMMUNITY INVITE FLOW ──────────────────────────────────────────────────

  // 13a. SEND a community join invite to a target device
  //      Writes to: users/{targetId}/community_invite
  static Future<String> sendCommunityInvite({
    required String fromId,
    required String fromName,
    required String targetId,
    required String communityName,
  }) async {
    final inviteRef = _db.child('users/$targetId/community_invite').push();
    final inviteId = inviteRef.key!;
    await inviteRef.set({
      'inviteId': inviteId,
      'fromId': fromId,
      'fromName': fromName,
      'communityName': communityName,
      'status': 'pending', // 'pending' | 'accepted' | 'declined'
      'timestamp': ServerValue.timestamp,
    });
    return inviteId;
  }

  // 13b. LISTEN for incoming community invites (on the recipient's side)
  static Stream<List<Map<String, dynamic>>> listenForCommunityInvites(
      String myDeviceId) {
    return _db
        .child('users/$myDeviceId/community_invite')
        .onValue
        .map((event) {
      final List<Map<String, dynamic>> invites = [];
      if (event.snapshot.value != null) {
        final raw = event.snapshot.value as Map<dynamic, dynamic>;
        raw.forEach((key, value) {
          if (value is Map) {
            final m = Map<String, dynamic>.from(value);
            m['_key'] = key.toString();
            invites.add(m);
          }
        });
      }
      return invites;
    });
  }

  // 13c. RESPOND to a community invite (accept or decline)
  static Future<void> respondToCommunityInvite({
    required String myDeviceId,
    required String inviteKey, // the Firebase push key
    required bool accepted,
  }) async {
    await _db
        .child('users/$myDeviceId/community_invite/$inviteKey/status')
        .set(accepted ? 'accepted' : 'declined');
  }

  // 13d. LISTEN for the response to an invite the sender sent
  //      Watches: users/{targetId}/community_invite/{inviteKey}/status
  static Stream<String?> listenForCommunityInviteResponse({
    required String targetId,
    required String inviteKey,
  }) {
    return _db
        .child('users/$targetId/community_invite/$inviteKey/status')
        .onValue
        .map((event) {
      return event.snapshot.value?.toString();
    });
  }

  // 13e. CLEAR a community invite entry
  static Future<void> clearCommunityInvite(
      String myDeviceId, String inviteKey) async {
    await _db
        .child('users/$myDeviceId/community_invite/$inviteKey')
        .remove();
  }

  // 13. COMMUNITY LOCATION BROADCAST
  static Future<void> updateCommunityLocation({
    required String deviceId,
    required String name,
    required double lat,
    required double lng,
    double heading = 0.0,
  }) async {
    await _db.child('community_members/$deviceId').set({
      'id': deviceId,
      'name': name,
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'lastSeen': ServerValue.timestamp,
    });
  }

  // 14. LISTEN TO COMMUNITY MEMBERS
  static Stream<List<Map<String, dynamic>>> getCommunityMembersStream() {
    return _db.child('community_members').onValue.map((event) {
      final List<Map<String, dynamic>> members = [];
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> data =
            event.snapshot.value as Map<dynamic, dynamic>;
        data.forEach((key, value) {
          if (value is Map) {
            final memberData = Map<String, dynamic>.from(value);
            memberData['id'] = key.toString();
            members.add(memberData);
          }
        });
      }
      return members;
    });
  }
}