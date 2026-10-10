import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:math';
import '../services/firebase_service.dart';
import 'tracking_screen_a.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────
class CommunityMember {
  final String id;
  final String name;
  final double distance; // metres from current user
  final double bearing; // degrees 0=N, 90=E
  final double? lat;
  final double? lng;
  final bool hasLocation;

  const CommunityMember({
    required this.id,
    required this.name,
    required this.distance,
    required this.bearing,
    this.lat,
    this.lng,
    this.hasLocation = false,
  });

  bool get isInZone => distance <= 50.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────
class CommunityScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final String communityName;

  const CommunityScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.communityName = 'Radar',
  });

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen>
    with SingleTickerProviderStateMixin {
  // ── Location ────────────────────────────────────────────────────────────────
  Position? _myPosition;
  StreamSubscription<Position>? _positionSub;

  // ── Firebase contacts (same source as Individual section) ──────────────────
  List<Map<String, dynamic>> _allContacts = [];
  StreamSubscription<List<Map<String, dynamic>>>? _contactsSub;
  StreamSubscription? _communityInviteListener;

  // ── Community: which contact IDs the user has selected (accepted) ───────────
  final Set<String> _communityIds = {};

  // ── Pending invites we sent (waiting for response) ──────────────────────────
  // Map of contactId -> {inviteKey, responseSubscription}
  final Map<String, Map<String, dynamic>> _pendingInvites = {};

  // ── UI state ────────────────────────────────────────────────────────────────
  late AnimationController _radarCtrl;
  String _filter = 'all'; // 'all' | 'in_zone' | 'out_zone'
  CommunityMember? _selectedMember;
  double _simOffset = 0.0; // for simulation slider

  // ── Tabs ────────────────────────────────────────────────────────────────────
  // 0 = Contacts (pick people), 1 = Radar
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _initLocation();
    _listenContacts();
    _listenForCommunityInvites();
  }

  // ── Location ────────────────────────────────────────────────────────────────
  Future<void> _initLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high);
        if (!mounted) return;
        setState(() => _myPosition = pos);
        _broadcastLocation(pos);

        _positionSub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high, distanceFilter: 2),
        ).listen((pos) {
          if (!mounted) return;
          setState(() => _myPosition = pos);
          _broadcastLocation(pos);
        });
      }
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  void _broadcastLocation(Position pos) {
    FirebaseService.updateDeviceLocation(
        widget.deviceId, pos.latitude, pos.longitude, pos.heading);
    FirebaseService.updateCommunityLocation(
      deviceId: widget.deviceId,
      name: widget.deviceName,
      lat: pos.latitude,
      lng: pos.longitude,
      heading: pos.heading,
    );
  }

  // ── Contacts (same Firebase 'devices' node as Individual) ───────────────────
  void _listenContacts() {
    _contactsSub = FirebaseService.getAllDevicesStream().listen((contacts) {
      if (!mounted) return;
      setState(() {
        // Filter out self
        _allContacts =
            contacts.where((c) => c['id'] != widget.deviceId).toList();
        
        // Sort: online first, then by name
        _allContacts.sort((a, b) {
          final bool aOnline = a['online'] == true;
          final bool bOnline = b['online'] == true;
          if (aOnline && !bOnline) return -1;
          if (!aOnline && bOnline) return 1;
          
          final String aName = (a['name'] as String? ?? '').toLowerCase();
          final String bName = (b['name'] as String? ?? '').toLowerCase();
          return aName.compareTo(bName);
        });
      });
    });
  }

  // ── Build CommunityMember list from selected IDs ─────────────────────────────
  List<CommunityMember> _buildCommunityMembers() {
    final members = <CommunityMember>[];
    for (final contact in _allContacts) {
      final id = contact['id'] as String? ?? '';
      if (!_communityIds.contains(id)) continue;

      double distance = 999.0;
      double bearing = 0.0;
      double? lat;
      double? lng;
      bool hasLoc = false;

      if (_myPosition != null &&
          contact['lat'] != null &&
          contact['lng'] != null) {
        lat = (contact['lat'] as num).toDouble();
        lng = (contact['lng'] as num).toDouble();
        distance = Geolocator.distanceBetween(
            _myPosition!.latitude, _myPosition!.longitude, lat, lng);
        bearing = Geolocator.bearingBetween(
            _myPosition!.latitude, _myPosition!.longitude, lat, lng);
        bearing = (bearing + 360) % 360;
        hasLoc = true;
      } else {
        // No GPS yet: spread them out evenly so they appear on radar
        final idx = members.length;
        bearing = (idx * 72.0) % 360; // 360/5 = 72
        // Assign a realistic-looking distance so they're visible
        distance = 20.0 + (idx * 18.0);
      }

      // Apply simulation offset (clamp to keep on radar)
      final adjustedDist = (distance + _simOffset).clamp(2.0, 150.0);

      members.add(CommunityMember(
        id: id,
        name: contact['name'] as String? ?? 'Device $id',
        distance: adjustedDist,
        bearing: bearing,
        lat: lat,
        lng: lng,
        hasLocation: hasLoc,
      ));
    }
    return members;
  }

  // ── Track an out-of-zone person 1-on-1 ──────────────────────────────────────
  Future<void> _trackPerson(CommunityMember m) async {
    final sessionId =
        await FirebaseService.startDirectSession(widget.deviceId, m.id);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrackingScreenA(
          sessionId: sessionId,
          friendId: m.id,
          friendName: m.name,
          myDeviceId: widget.deviceId,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _contactsSub?.cancel();
    _communityInviteListener?.cancel();
    // Cancel all pending invite response listeners
    for (final p in _pendingInvites.values) {
      (p['sub'] as StreamSubscription?)?.cancel();
    }
    _radarCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final communityMembers = _buildCommunityMembers();
    final inZone = communityMembers.where((m) => m.isInZone).toList();
    final outZone = communityMembers.where((m) => !m.isInZone).toList();

    List<CommunityMember> displayed;
    if (_filter == 'in_zone') {
      displayed = inZone;
    } else if (_filter == 'out_zone') {
      displayed = outZone;
    } else {
      displayed = communityMembers;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: _buildAppBar(communityMembers, inZone, outZone),
      body: _tab == 0
          ? _buildContactsTab()
          : _buildRadarTab(communityMembers, inZone, outZone, displayed),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // ── AppBar ──────────────────────────────────────────────────────────────────
  AppBar _buildAppBar(List<CommunityMember> members,
      List<CommunityMember> inZone, List<CommunityMember> outZone) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.communityName} Radar',
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          ),
          Text(
            '${_communityIds.length} members selected',
            style: const TextStyle(fontSize: 11, color: Color(0xFF2DD4BF)),
          ),
        ],
      ),
      backgroundColor: const Color(0xFF1E293B),
      foregroundColor: Colors.white,
      elevation: 0,
      actions: [
        if (_tab == 1)
          IconButton(
            tooltip: 'Simulate movement',
            icon:
                const Icon(Icons.tune_rounded, color: Color(0xFF2DD4BF)),
            onPressed: _showSimDialog,
          ),
      ],
    );
  }

  // ── Bottom Nav ───────────────────────────────────────────────────────────────
  Widget _buildBottomNav() {
    return Container(
      color: const Color(0xFF1E293B),
      child: Row(
        children: [
          Expanded(child: _navBtn(0, Icons.group_add_rounded, 'Contacts')),
          Expanded(child: _navBtn(1, Icons.radar_rounded, 'Zone Radar')),
        ],
      ),
    );
  }

  Widget _navBtn(int index, IconData icon, String label) {
    final active = _tab == index;
    return InkWell(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: active ? const Color(0xFF2DD4BF) : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color:
                    active ? const Color(0xFF2DD4BF) : Colors.grey.shade500,
                size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active
                    ? const Color(0xFF2DD4BF)
                    : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 0 — CONTACTS PICKER  (same source as Individual section)
  // ────────────────────────────────────────────────────────────────────────────
  Widget _buildContactsTab() {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          color: const Color(0xFF1E293B),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select Community Members',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'All online contacts from your network. Tap to add or remove from your community group.',
                      style: TextStyle(
                          color: Colors.grey.shade400, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (_communityIds.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() => _tab = 1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2DD4BF),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'View Radar (${_communityIds.length})',
                          style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_forward_rounded,
                            size: 14, color: Color(0xFF0F172A)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Search hint / online count
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xFF131D2E),
          child: Row(
            children: [
              const Icon(Icons.wifi_tethering_rounded,
                  size: 14, color: Color(0xFF2DD4BF)),
              const SizedBox(width: 6),
              Text(
                '${_allContacts.length} contact${_allContacts.length != 1 ? "s" : ""} online right now',
                style: const TextStyle(
                    color: Color(0xFF2DD4BF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (_communityIds.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() => _communityIds.clear()),
                  child: Text(
                    'Clear all',
                    style: TextStyle(
                        color: Colors.red.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),

        // Contact list
        Expanded(
          child: _allContacts.isEmpty
              ? _emptyContacts()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  itemCount: _allContacts.length,
                  itemBuilder: (context, index) {
                    final contact = _allContacts[index];
                    final id = contact['id'] as String? ?? '';
                    final name =
                        contact['name'] as String? ?? 'Unknown Device';
                    final selected = _communityIds.contains(id);
                    final hasLoc = contact['lat'] != null;

                    return _buildContactTile(
                        id, name, selected, hasLoc, contact);
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyContacts() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.signal_wifi_off_rounded,
              size: 52, color: Colors.grey.shade600),
          const SizedBox(height: 16),
          Text(
            'No contacts online',
            style: TextStyle(
                color: Colors.grey.shade300,
                fontSize: 17,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Waiting for other users to come online.\nAsk your friends to open the app!',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(String id, String name, bool selected,
      bool hasLoc, Map<String, dynamic> contact) {
    final isPending = _pendingInvites.containsKey(id);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF0D2B2B)
            : const Color(0xFF182234),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected
              ? const Color(0xFF2DD4BF)
              : isPending
                  ? const Color(0xFFF59E0B)
                  : Colors.white.withOpacity(0.06),
          width: (selected || isPending) ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: selected
                  ? const Color(0xFF2DD4BF)
                  : isPending
                      ? const Color(0xFFF59E0B).withOpacity(0.3)
                      : const Color(0xFF1E3A5F),
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                  color: selected
                      ? const Color(0xFF0F172A)
                      : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            if (hasLoc)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: const Color(0xFF182234), width: 1.5),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          name,
          style: TextStyle(
            color: Colors.white,
            fontWeight: (selected || isPending)
                ? FontWeight.bold
                : FontWeight.w500,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          '${id.substring(0, id.length >= 8 ? 8 : id.length).toUpperCase()}${hasLoc ? ' • GPS active' : ' • No GPS yet'}',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: hasLoc
                ? const Color(0xFF34D399)
                : Colors.grey.shade500,
          ),
        ),
        trailing: GestureDetector(
          onTap: () {
            if (selected) {
              // Remove from community
              setState(() => _communityIds.remove(id));
            } else if (isPending) {
              // Show the waiting dialog again (tap to view status)
              _showWaitingDialog(id, name);
            } else {
              // Send invite
              _sendCommunityInvite(id, name);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 90,
            height: 36,
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF2DD4BF)
                  : isPending
                      ? const Color(0xFFF59E0B).withOpacity(0.2)
                      : Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? const Color(0xFF2DD4BF)
                    : isPending
                        ? const Color(0xFFF59E0B)
                        : Colors.white.withOpacity(0.15),
              ),
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected
                        ? Icons.check_rounded
                        : isPending
                            ? Icons.hourglass_top_rounded
                            : Icons.send_rounded,
                    size: 13,
                    color: selected
                        ? const Color(0xFF0F172A)
                        : isPending
                            ? const Color(0xFFF59E0B)
                            : Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    selected
                        ? 'Added'
                        : isPending
                            ? 'Pending'
                            : 'Invite',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: selected
                          ? const Color(0xFF0F172A)
                          : isPending
                              ? const Color(0xFFF59E0B)
                              : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 1 — RADAR VIEW
  // ────────────────────────────────────────────────────────────────────────────
  Widget _buildRadarTab(
    List<CommunityMember> members,
    List<CommunityMember> inZone,
    List<CommunityMember> outZone,
    List<CommunityMember> displayed,
  ) {
    return Column(
      children: [
        // Alert ribbon
        _buildAlertRibbon(outZone),

        // Radar canvas
        Expanded(
          flex: 6,
          child: members.isEmpty
              ? _emptyRadar()
              : Padding(
                  padding: const EdgeInsets.all(10),
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final size = min(
                          constraints.maxWidth, constraints.maxHeight);
                      return Center(
                        child: SizedBox(
                          width: size,
                          height: size,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              AnimatedBuilder(
                                animation: _radarCtrl,
                                builder: (ctx, _) => CustomPaint(
                                  size: Size(size, size),
                                  painter: RadarZonePainter(
                                    sweepAngle:
                                        _radarCtrl.value * 2 * pi,
                                  ),
                                ),
                              ),
                              _buildYouMarker(),
                              ...members.map((m) =>
                                  _buildMemberNode(m, size)),
                              Positioned(
                                bottom: 10,
                                child: _buildLegend(),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),

        // Filter bar
        _buildFilterBar(members.length, inZone.length, outZone.length),

        // Member list
        Expanded(
          flex: 4,
          child: Container(
            color: const Color(0xFF131D2E),
            child: displayed.isEmpty
                ? Center(
                    child: Text(
                      _communityIds.isEmpty
                          ? 'Add members in the Contacts tab'
                          : 'No members match this filter',
                      style: TextStyle(
                          color: Colors.grey.shade400, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    itemCount: displayed.length,
                    itemBuilder: (ctx, i) =>
                        _buildMemberCard(displayed[i]),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _emptyRadar() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.group_add_rounded,
              size: 60, color: Colors.grey.shade700),
          const SizedBox(height: 16),
          Text('No community members yet',
              style: TextStyle(
                  color: Colors.grey.shade300,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Go to the Contacts tab to\nadd people to your community.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.grey.shade500, fontSize: 13)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => setState(() => _tab = 0),
            icon: const Icon(Icons.group_add_rounded, size: 18),
            label: const Text('Add Members'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2DD4BF),
              foregroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertRibbon(List<CommunityMember> outZone) {
    final hasAlert = outZone.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      color: hasAlert ? const Color(0xFF451A1A) : const Color(0xFF132A22),
      child: Row(
        children: [
          Icon(
            hasAlert
                ? Icons.warning_amber_rounded
                : Icons.check_circle_outline_rounded,
            color: hasAlert
                ? const Color(0xFFFF6B6B)
                : const Color(0xFF4ADE80),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasAlert
                  ? '${outZone.length} member${outZone.length > 1 ? "s" : ""} out of 50 m zone!'
                  : _communityIds.isEmpty
                      ? 'No members added yet — go to Contacts'
                      : 'All community members inside 50 m zone ✓',
              style: TextStyle(
                color: hasAlert
                    ? const Color(0xFFFFE3E3)
                    : const Color(0xFFDCFCE7),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Zone: 50 m',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade200)),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(int all, int inZ, int outZ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: const Color(0xFF1E293B),
      child: Row(
        children: [
          _filterChip('all', 'All ($all)'),
          const SizedBox(width: 8),
          _filterChip('in_zone', 'In Zone ($inZ)',
              color: const Color(0xFF10B981)),
          const SizedBox(width: 8),
          _filterChip('out_zone', 'Out ($outZ)',
              color: const Color(0xFFEF4444)),
        ],
      ),
    );
  }

  Widget _filterChip(String key, String label, {Color? color}) {
    final active = _filter == key;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _filter = key),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? (color ?? const Color(0xFF2DD4BF))
              : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active
                  ? Colors.transparent
                  : Colors.white.withOpacity(0.12)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.bold : FontWeight.w500,
            color: active
                ? (color != null
                    ? Colors.white
                    : const Color(0xFF0F172A))
                : Colors.grey.shade300,
          ),
        ),
      ),
    );
  }

  // ── Incoming Community Invites ───────────────────────────────────────────────
  void _listenForCommunityInvites() {
    _communityInviteListener =
        FirebaseService.listenForCommunityInvites(widget.deviceId!).listen(
      (invites) async {
        // Only handle pending invites
        final pending = invites
            .where((i) => (i['status'] as String? ?? '') == 'pending')
            .toList();
        for (final invite in pending) {
          final key = invite['_key'] as String;
          final fromId = invite['fromId'] as String? ?? '';
          final fromName = invite['fromName'] as String? ?? fromId;
          final communityName =
              invite['communityName'] as String? ?? 'a community';
          if (!mounted) return;
          _showCommunityInviteDialog(key, fromId, fromName, communityName);
        }
      },
    );
  }

  void _showCommunityInviteDialog(
      String inviteKey, String fromId, String fromName, String communityName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0D9488), Color(0xFF0F172A)],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.group_add_rounded,
                    size: 44, color: Colors.white),
              ),
              const SizedBox(height: 18),
              const Text(
                'Community Invite',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 10),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withOpacity(0.85)),
                  children: [
                    TextSpan(
                        text: fromName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold)),
                    const TextSpan(text: ' wants to add you to\n'),
                    TextSpan(
                        text: '"$communityName"',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2DD4BF))),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'ID: ${fromId.substring(0, fromId.length >= 8 ? 8 : fromId.length).toUpperCase()}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 12),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await FirebaseService.respondToCommunityInvite(
                          myDeviceId: widget.deviceId!,
                          inviteKey: inviteKey,
                          accepted: false,
                        );
                        // Clean up after a short delay
                        await Future.delayed(
                            const Duration(seconds: 2));
                        await FirebaseService.clearCommunityInvite(
                            widget.deviceId!, inviteKey);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(
                            color: Colors.white54, width: 1.5),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Decline',
                          style: TextStyle(
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await FirebaseService.respondToCommunityInvite(
                          myDeviceId: widget.deviceId!,
                          inviteKey: inviteKey,
                          accepted: true,
                        );
                        
                        // ✅ Mutually add the sender to OUR community
                        if (mounted) {
                          setState(() {
                            _communityIds.add(fromId);
                          });
                        }

                        // Clean up after sender reads the response
                        await Future.delayed(
                            const Duration(seconds: 3));
                        await FirebaseService.clearCommunityInvite(
                            widget.deviceId!, inviteKey);
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                'You joined "$communityName"!'),
                            backgroundColor:
                                const Color(0xFF059669),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2DD4BF),
                        foregroundColor: const Color(0xFF0F172A),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Accept',
                          style: TextStyle(
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Send community invite and wait for response ───────────────────────────────
  Future<void> _sendCommunityInvite(String contactId, String contactName) async {
    // Don't double-send
    if (_pendingInvites.containsKey(contactId)) return;

    // Show waiting dialog immediately
    _showWaitingDialog(contactId, contactName);

    // Send the invite via Firebase
    final inviteKey = await FirebaseService.sendCommunityInvite(
      fromId: widget.deviceId,
      fromName: widget.deviceName,
      targetId: contactId,
      communityName: widget.communityName,
    );

    if (!mounted) return;
    setState(() => _pendingInvites[contactId] = {'inviteKey': inviteKey});

    // Listen for the response
    final sub = FirebaseService.listenForCommunityInviteResponse(
      targetId: contactId,
      inviteKey: inviteKey,
    ).listen((status) async {
      if (status == null || status == 'pending') return;

      // Close the waiting dialog if still open
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();

      if (status == 'accepted') {
        if (!mounted) return;
        setState(() {
          _communityIds.add(contactId);
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$contactName joined your community! ✓'),
          backgroundColor: const Color(0xFF059669),
        ));
      } else {
        // Declined
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$contactName declined the invite.'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }

      // Cleanup
      final p = _pendingInvites.remove(contactId);
      (p?['sub'] as StreamSubscription?)?.cancel();
      if (mounted) setState(() {});

      // Clean up Firebase node after a delay so the target also reads it
      await Future.delayed(const Duration(seconds: 4));
      await FirebaseService.clearCommunityInvite(contactId, inviteKey);
    });

    if (mounted) {
      setState(() => _pendingInvites[contactId]!['sub'] = sub);
    } else {
      sub.cancel();
    }
  }

  void _showWaitingDialog(String contactId, String contactName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: Dialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24)),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 52,
                  height: 52,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF2DD4BF)),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Invite Sent',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Waiting for $contactName\nto accept your community invite…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    // Cancel the pending invite
                    final p = _pendingInvites.remove(contactId);
                    (p?['sub'] as StreamSubscription?)?.cancel();
                    final key = p?['inviteKey'] as String?;
                    if (key != null) {
                      await FirebaseService.clearCommunityInvite(
                          contactId, key);
                    }
                    if (mounted) setState(() {});
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side:
                        const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Cancel Invite'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildYouMarker() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFF2DD4BF),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF2DD4BF).withOpacity(0.6),
                  blurRadius: 14,
                  spreadRadius: 2)
            ],
          ),
          child: const Center(
            child: Icon(Icons.person, size: 17, color: Color(0xFF0F172A)),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text('YOU',
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2DD4BF))),
        ),
      ],
    );
  }

  Widget _buildMemberNode(CommunityMember m, double canvasSize) {
    final center = canvasSize / 2;
    final zoneR = center * 0.60;
    final maxR = center * 0.90;

    double r;
    if (m.isInZone) {
      r = (m.distance / 50.0) * (zoneR - 18);
    } else {
      final excess = (m.distance - 50.0).clamp(0.0, 60.0);
      r = zoneR + (excess / 60.0) * (maxR - zoneR);
    }

    final rad = (m.bearing - 90) * (pi / 180.0);
    final dx = center + r * cos(rad);
    final dy = center + r * sin(rad);
    final isSelected = _selectedMember?.id == m.id;

    return Positioned(
      left: dx - 22,
      top: dy - 22,
      child: GestureDetector(
        onTap: () => setState(() => _selectedMember = m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: m.isInZone
                    ? const Color(0xFF059669)
                    : const Color(0xFFDC2626),
                border: Border.all(
                    color: isSelected
                        ? Colors.white
                        : (m.isInZone
                            ? const Color(0xFF34D399)
                            : const Color(0xFFFCA5A5)),
                    width: isSelected ? 3 : 1.5),
                boxShadow: [
                  BoxShadow(
                    color: (m.isInZone
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444))
                        .withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 1,
                  )
                ],
              ),
              child: Center(
                child: Text(
                  m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 4, vertical: 1.5),
              decoration: BoxDecoration(
                color: m.isInZone
                    ? const Color(0xFF064E3B).withOpacity(0.9)
                    : const Color(0xFF7F1D1D).withOpacity(0.9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${m.distance.toStringAsFixed(0)}m',
                  style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2DD4BF), width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 4, backgroundColor: Color(0xFF2DD4BF)),
          SizedBox(width: 5),
          Text('≤ 50 m inside circle  |  > 50 m outside',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ── Member list card ─────────────────────────────────────────────────────────
  Widget _buildMemberCard(CommunityMember m) {
    final isSelected = _selectedMember?.id == m.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF1E293B) : const Color(0xFF182234),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? (m.isInZone
                  ? const Color(0xFF2DD4BF)
                  : const Color(0xFFF87171))
              : Colors.white.withOpacity(0.06),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: m.isInZone
                  ? const Color(0xFF059669)
                  : const Color(0xFFDC2626),
              child: Text(
                m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.name,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: m.isInZone
                              ? const Color(0xFF065F46)
                              : const Color(0xFF7F1D1D),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          m.isInZone
                              ? 'IN ZONE'
                              : 'OUT OF ZONE',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: m.isInZone
                                  ? const Color(0xFF6EE7B7)
                                  : const Color(0xFFFCA5A5)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${m.distance.toStringAsFixed(1)} m',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade400,
                            fontFamily: 'monospace'),
                      ),
                      if (!m.hasLocation) ...[
                        const SizedBox(width: 6),
                        Text('(No GPS)',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.orange.shade300)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Remove from community
            IconButton(
              tooltip: 'Remove from community',
              icon: const Icon(Icons.remove_circle_outline_rounded,
                  size: 20, color: Colors.red),
              onPressed: () =>
                  setState(() => _communityIds.remove(m.id)),
            ),
            // Track
            ElevatedButton.icon(
              onPressed: () => _trackPerson(m),
              icon: Icon(
                m.isInZone
                    ? Icons.navigation_rounded
                    : Icons.search_rounded,
                size: 14,
              ),
              label: Text(
                m.isInZone ? 'TRACK' : 'FIND',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: m.isInZone
                    ? const Color(0xFF0D9488)
                    : const Color(0xFFDC2626),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 7),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
                elevation: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Simulation dialog ────────────────────────────────────────────────────────
  void _showSimDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Simulate Movement',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                'Move all members closer or further to test the 50 m boundary.',
                style: TextStyle(
                    color: Colors.grey.shade400, fontSize: 12),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Distance offset',
                      style: TextStyle(color: Colors.white)),
                  Text(
                    '${_simOffset >= 0 ? "+" : ""}${_simOffset.toStringAsFixed(0)} m',
                    style: const TextStyle(
                        color: Color(0xFF2DD4BF),
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ],
              ),
              Slider(
                value: _simOffset,
                min: -30,
                max: 45,
                divisions: 15,
                activeColor: const Color(0xFF2DD4BF),
                inactiveColor: Colors.white12,
                onChanged: (v) {
                  setS(() => _simOffset = v);
                  setState(() => _simOffset = v);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        setS(() => _simOffset = 0);
                        setState(() => _simOffset = 0);
                      },
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24)),
                      child: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2DD4BF),
                        foregroundColor: const Color(0xFF0F172A),
                      ),
                      child: const Text('Done',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Radar Painter  (unchanged visual)
// ─────────────────────────────────────────────────────────────────────────────
class RadarZonePainter extends CustomPainter {
  final double sweepAngle;
  const RadarZonePainter({required this.sweepAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = (size.width / 2) * 0.92;
    final zoneR = (size.width / 2) * 0.60;

    // Background
    canvas.drawCircle(center, maxR,
        Paint()..color = const Color(0xFF0B132B));

    // Out-zone tint
    canvas.drawCircle(
        center,
        maxR,
        Paint()
          ..color = const Color(0xFFEF4444).withOpacity(0.06)
          ..style = PaintingStyle.fill);

    // Safe-zone fill
    canvas.drawCircle(
        center,
        zoneR,
        Paint()
          ..color = const Color(0xFF10B981).withOpacity(0.12)
          ..style = PaintingStyle.fill);

    // Grid rings
    final grid = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, zoneR * 0.33, grid);
    canvas.drawCircle(center, zoneR * 0.66, grid);
    canvas.drawCircle(center, maxR, grid);

    // Crosshairs
    final cross = Paint()
      ..color = const Color(0xFF334155).withOpacity(0.5)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(center.dx, center.dy - maxR),
        Offset(center.dx, center.dy + maxR), cross);
    canvas.drawLine(Offset(center.dx - maxR, center.dy),
        Offset(center.dx + maxR, center.dy), cross);

    // Zone perimeter
    canvas.drawCircle(
        center,
        zoneR,
        Paint()
          ..color = const Color(0xFF2DD4BF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    canvas.drawCircle(
        center,
        zoneR,
        Paint()
          ..color = const Color(0xFF2DD4BF).withOpacity(0.22)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7);

    // Radar sweep
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(sweepAngle);
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: maxR),
      -pi / 4,
      pi / 4,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: pi / 2,
          colors: [
            Colors.transparent,
            const Color(0xFF2DD4BF).withOpacity(0.28)
          ],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: maxR))
        ..style = PaintingStyle.fill,
    );
    canvas.restore();

    // Labels
    _text(canvas, '50 m ZONE',
        Offset(center.dx + 4, center.dy - zoneR + 4),
        const Color(0xFF2DD4BF), 10, FontWeight.bold);
    _text(canvas, '25 m',
        Offset(center.dx + 4, center.dy - zoneR * 0.5 + 4),
        Colors.white38, 9, FontWeight.normal);
    _text(canvas, 'OUT >',
        Offset(center.dx + 4, center.dy - maxR + 4),
        const Color(0xFFF87171), 9, FontWeight.w600);
  }

  void _text(Canvas c, String text, Offset pos, Color color,
      double size, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              color: color,
              fontSize: size,
              fontWeight: weight,
              fontFamily: 'monospace')),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, pos);
  }

  @override
  bool shouldRepaint(RadarZonePainter old) => old.sweepAngle != sweepAngle;
}
