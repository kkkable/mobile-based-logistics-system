import 'dart:async';
import 'dart:convert';
import 'dart:js' as js;
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../providers/a_login_provider.dart';

class MasterMapView extends StatefulWidget {
  const MasterMapView({super.key});

  @override
  State<MasterMapView> createState() => _MasterMapViewState();
}

class _MasterMapViewState extends State<MasterMapView> {
  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(22.3193, 114.1694),
    zoom: 11,
  );

  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  Timer? _timer;
  bool _isLoading = true;
  bool _scriptLoaded = false;
  
  List<dynamic> _allDrivers = [];
  Map<String, Offset> _bubbleOffsets = {};
  Map<String, dynamic>? _selectedDriver;

  @override
  void initState() {
    super.initState();
    _loadMapScript();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadMapScript() async {
    if (_isMapsFullyLoaded()) {
      setState(() { _scriptLoaded = true; _isLoading = false; });
      _startLiveTracking();
      return;
    }

    final loginProv = Provider.of<LoginProvider>(context, listen: false);
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'http://localhost:8080';
    
    String? apiKey;
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/config/maps-key'),
        headers: {'Authorization': 'Bearer ${loginProv.token}'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        apiKey = data['key'];
      }
    } catch (e) {
      print(e);
    }

    if (apiKey == null) return;

    final script = html.ScriptElement()
      ..src = 'https://maps.googleapis.com/maps/api/js?key=$apiKey&loading=async'
      ..async = true
      ..defer = true;

    script.onLoad.listen((event) {
      _waitForMapsApi();
    });

    html.document.head!.append(script);
  }

  bool _isMapsFullyLoaded() {
    try {
      if (!js.context.hasProperty('google')) return false;
      final google = js.context['google'];
      if (!google.hasProperty('maps')) return false;
      final maps = google['maps'];
      if (!maps.hasProperty('MapTypeId')) return false;
      return true;
    } catch (e) {
      return false;
    }
  }

  void _waitForMapsApi() {
    if (_isMapsFullyLoaded()) {
      if (mounted) {
        setState(() { _scriptLoaded = true; _isLoading = false; });
        _startLiveTracking();
      }
    } else {
      Timer(const Duration(milliseconds: 100), _waitForMapsApi);
    }
  }

  void _startLiveTracking() {
    _fetchDrivers();
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (mounted) _fetchDrivers();
    });
  }

  Future<void> _fetchDrivers() async {
    final loginProv = Provider.of<LoginProvider>(context, listen: false);
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'http://localhost:8080';
    
    if (loginProv.token == null) return;

    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/web/master-map/drivers'),
        headers: {'Authorization': 'Bearer ${loginProv.token}'},
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        _updateMarkers(data);
      }
    } catch (e) {
      print(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _updateMarkers(List<dynamic> drivers) {
    final Set<Marker> newMarkers = {};
    _allDrivers = drivers;

    for (var d in drivers) {
      final double lat = (d['current_lat'] as num).toDouble();
      final double lng = (d['current_lng'] as num).toDouble();
      final String driverId = d['driver_id'].toString();

      final marker = Marker(
        markerId: MarkerId(driverId),
        position: LatLng(lat, lng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        onTap: () {
          _selectDriver(d);
        },
      );
      newMarkers.add(marker);
    }

    if (mounted) {
      setState(() {
        _markers = newMarkers;
      });
      _updateAllBubblePositions();
    }
  }

  // calculate screen coordinates
  void _updateAllBubblePositions() async {
    if (_mapController == null || _allDrivers.isEmpty) return;

    final Map<String, Offset> newOffsets = {};

    for (var d in _allDrivers) {
       final double lat = (d['current_lat'] as num).toDouble();
       final double lng = (d['current_lng'] as num).toDouble();
       final String driverId = d['driver_id'].toString();
       
       try {
         ScreenCoordinate screenPos = await _mapController!.getScreenCoordinate(LatLng(lat, lng));
         newOffsets[driverId] = Offset(screenPos.x.toDouble(), screenPos.y.toDouble());
       } catch (e) {
       }
    }

    if (mounted) {
      setState(() {
        _bubbleOffsets = newOffsets;
      });
    }
  }

  void _selectDriver(Map<String, dynamic> d) {
    setState(() {
      _selectedDriver = d;
    });
  }

  void _closeDetailPanel() {
    setState(() {
      _selectedDriver = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Master Map - Live Tracking"),
        actions: [
          if (_isLoading || !_scriptLoaded)
            const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
            )
        ],
      ),
      body: !_scriptLoaded
          ? const Center(child: Text("Loading Map..."))
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: _initialPosition,
                  markers: _markers,
                  onMapCreated: (controller) {
                    _mapController = controller;
                    // hide POIs
                    controller.setMapStyle(jsonEncode([
                      {
                        "featureType": "poi",
                        "stylers": [{"visibility": "off"}]
                      }
                    ]));
                  },
                  
                  zoomControlsEnabled: true,
                  mapToolbarEnabled: false,
                  onTap: (_) => _closeDetailPanel(),
                  onCameraMove: (_) => _updateAllBubblePositions(),
                ),

                // driver bubbles
                ..._allDrivers.map((d) {
                   final String driverId = d['driver_id'].toString();
                   final Offset? offset = _bubbleOffsets[driverId];
                   
                   if (offset == null) return const Positioned(child: SizedBox.shrink());

                   return Positioned(
                     left: offset.dx - 75, 
                     top: offset.dy - 110, 
                     child: _buildPersistentBubble(d),
                   );
                }).toList(),

                // detail panel
                if (_selectedDriver != null)
                  Positioned(
                    left: 20,
                    top: 20,
                    child: _buildDriverDetailCard(_selectedDriver!),
                  ),
              ],
            ),
    );
  }

  Widget _buildPersistentBubble(Map<String, dynamic> d) {
    return GestureDetector(
      onTap: () => _selectDriver(d),
      child: Column(
        children: [
          Container(
            width: 150, 
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 2)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Driver ${d['driver_id']}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 2),
                Text(
                  "Task: ${d['current_task'] ?? 'Idle'}",
                  style: const TextStyle(fontSize: 11, color: Colors.black87),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          ClipPath(
            clipper: TriangleClipper(),
            child: Container(
              color: Colors.white,
              width: 10,
              height: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverDetailCard(Map<String, dynamic> d) {
    String routeStr = (d['expected_route'] as List).join(' -> ');
    String timeStr = (d['expected_time'] as List).map((t) {
      if (t is int) {
        final dt = DateTime.fromMillisecondsSinceEpoch(t);
        return "${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}";
      }
      return "";
    }).join(', ');

    return GestureDetector(
      onTap: () {},
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 5)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Driver Info", style: Theme.of(context).textTheme.titleLarge),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _closeDetailPanel, 
                )
              ],
            ),
            const Divider(),
            _buildInfoRow("ID", "${d['driver_id']}"),
            _buildInfoRow("Name", "${d['name']}"),
            _buildInfoRow("Avg Rating", "${d['avg_rating']} ★"),
            _buildInfoRow("Vehicle", "${d['vehicle_details']}"),
            _buildInfoRow("Max Weight", "${d['max_weight']} kg"),
            _buildInfoRow("Phone", "${d['phone']}"),
            _buildInfoRow("Working Time", "${d['working_time']}"),
            _buildInfoRow("Location", "${d['current_lat'].toStringAsFixed(4)}, ${d['current_lng'].toStringAsFixed(4)}"),
            const SizedBox(height: 8),
            const Text("Expected Route:", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(routeStr.isEmpty ? "None" : routeStr, style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
            const SizedBox(height: 8),
            const Text("Expected Time:", style: TextStyle(fontWeight: FontWeight.bold)),
            Container(
              constraints: const BoxConstraints(maxHeight: 60), 
              child: SingleChildScrollView(
                child: Text(timeStr.isEmpty ? "None" : timeStr, style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text("$label:", style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.grey))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}

class TriangleClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(size.width / 2, size.height);
    path.lineTo(size.width, 0);
    path.close();
    return path;
  }
  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
