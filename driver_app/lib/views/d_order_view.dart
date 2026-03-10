import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:image_picker/image_picker.dart';
import '../controllers/d_order_controller.dart';
import '../models/d_order.dart';
import '../repositories/d_order_repository.dart';

class RouteProcessParams {
  final List<dynamic> polylinesData;
  RouteProcessParams(this.polylinesData);
}

double _getSqDist(LatLng p1, LatLng p2) {
  double dx = p1.longitude - p2.longitude;
  double dy = p1.latitude - p2.latitude;
  return dx * dx + dy * dy;
}

List<LatLng> _simplifyByDistance(List<LatLng> points, double minDistanceSq) {
  if (points.length < 2) return points;

  final List<LatLng> simplified = [points.first];
  LatLng lastPoint = points.first;

  for (int i = 1; i < points.length; i++) {
    if (_getSqDist(points[i], lastPoint) > minDistanceSq) {
      simplified.add(points[i]);
      lastPoint = points[i];
    }
  }
  if (simplified.last != points.last) {
    simplified.add(points.last);
  }
  return simplified;
}

List<List<LatLng>> _processRouteInBackground(RouteProcessParams params) {
  List<List<LatLng>> result = [];
  const double thresholdSq = 0.0002 * 0.0002;

  for (int i = 0; i < params.polylinesData.length; i++) {
    final rawPoints = params.polylinesData[i] as List<dynamic>;
    
    final points = rawPoints.map((p) {
         if (p is Map && p.containsKey('lat') && p.containsKey('lng')) {
             return LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble());
         }
         return null;
    }).whereType<LatLng>().toList();
    
    if (points.isNotEmpty) {
      final simplified = _simplifyByDistance(points, thresholdSq);
      result.add(simplified);
    }
  }
  return result;
}

double distanceToSegment(LatLng p, LatLng v, LatLng w) {
  final l2 = _getSqDist(v, w);
  if (l2 == 0) return Geolocator.distanceBetween(p.latitude, p.longitude, v.latitude, v.longitude);
  
  double t = ((p.latitude - v.latitude) * (w.latitude - v.latitude) + (p.longitude - v.longitude) * (w.longitude - v.longitude)) / l2;
  t = math.max(0, math.min(1, t));
  
  final projLat = v.latitude + t * (w.latitude - v.latitude);
  final projLng = v.longitude + t * (w.longitude - v.longitude);
  
  return Geolocator.distanceBetween(p.latitude, p.longitude, projLat, projLng);
}

bool isOffRoute(LatLng driverLoc, List<List<LatLng>> segments, double thresholdMeters) {
  if (segments.isEmpty) return false;
  double minDistance = double.infinity;
  for (var segment in segments) {
      for (int i = 0; i < segment.length - 1; i++) {
        double d = distanceToSegment(driverLoc, segment[i], segment[i+1]);
        if (d < minDistance) minDistance = d;
        if (minDistance < thresholdMeters) return false; 
      }
  }
  return true; 
}

class OrdersView extends StatefulWidget {
  final int driverId;
  final String token;
  const OrdersView({super.key, required this.driverId, required this.token});

  @override
  State<OrdersView> createState() => _OrdersViewState();
}

class _OrdersViewState extends State<OrdersView> {
  GoogleMapController? mapController;
  StreamSubscription<Position>? _positionStreamSubscription;
  Position? _currentPosition;
  DateTime? _lastRerouteTime;

  Set<Polyline> polylines = {};
  Set<Marker> markers = {};
  bool _isMapInitialized = false;
  final OrderRepository _orderRepository = OrderRepository();
  final Map<int, LatLng> _pickupCoordinates = {};
  
  List<List<LatLng>> _routeSegments = []; 
  List<dynamic> _routeStops = [];         
  final Set<String> _visitedStopIds = {}; 

  // panel states
  double _panelHeight = 0; 
  double _minPanelHeight = 70; 
  double _maxPanelHeight = 400; 
  bool _isPanelOpen = true; 
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _startLocationUpdates();
    Future.delayed(const Duration(milliseconds: 1000), _fetchOptimizedRoute);
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    mapController?.dispose();
    super.dispose();
  }

  Future<void> _startLocationUpdates() async {
    // check gps
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
       if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enable GPS')));
       return;
    }
    
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    
    try {
        _currentPosition = await Geolocator.getCurrentPosition();
        if (mounted && !_isMapInitialized && mapController != null) {
          mapController!.animateCamera(CameraUpdate.newLatLngZoom(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            16,
          ));
          _isMapInitialized = true;
          _updateMapObjects();
        }
    } catch (e) {
        print(e);
    }

    const LocationSettings locationSettings = LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);

    _positionStreamSubscription = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position pos) {
          if (!mounted) return;
          _currentPosition = pos;
          _orderRepository.updateDriverLocation(
            token: widget.token, latitude: pos.latitude, longitude: pos.longitude,
          ).catchError((e) => print(e));
          
          if (mapController != null) {
             mapController!.animateCamera(CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)));
          }
          _handleDynamicRoute(pos);
          _updateMapObjects();
      }, onError: (e) {
          print(e);
      });
  }

  void _handleDynamicRoute(Position pos) {
    if (_routeStops.isEmpty) return;
    final LatLng driverLoc = LatLng(pos.latitude, pos.longitude);
    double hitRadius = math.max(50.0, pos.accuracy);

    for (var stop in _routeStops) {
      if (stop['type'] == 'dropoff') continue;
      final double dist = Geolocator.distanceBetween(
        driverLoc.latitude, driverLoc.longitude,
        (stop['lat'] as num).toDouble(), (stop['lng'] as num).toDouble()
      );
      if (dist < hitRadius) {
         _triggerArrival(stop, renderImmediately: false);
         break; 
      }
    }

    if (_routeSegments.isNotEmpty) {
      List<LatLng> activeLeg = _routeSegments.first;
      if (activeLeg.length > 2) {
        int closestIndex = -1;
        double minDistance = double.infinity;
        int searchLimit = math.min(activeLeg.length, 30); 
        for (int i = 0; i < searchLimit; i++) {
          double dist = Geolocator.distanceBetween(
            driverLoc.latitude, driverLoc.longitude, activeLeg[i].latitude, activeLeg[i].longitude
          );
          if (dist < minDistance) {
            minDistance = dist;
            closestIndex = i;
          }
        }
        if (closestIndex > 0 && minDistance < 50) {
          _routeSegments[0] = activeLeg.sublist(closestIndex);
        }
      }
    }

    if (_lastRerouteTime != null && DateTime.now().difference(_lastRerouteTime!).inSeconds < 60) return;

    if (_routeSegments.isNotEmpty) {
       bool offTrack = isOffRoute(driverLoc, [_routeSegments.first], 100);
       if (offTrack) {
           if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Rerouting..."), duration: Duration(seconds: 2)));
           _lastRerouteTime = DateTime.now();
           _fetchOptimizedRoute(); 
       }
    }
  }

  void _triggerArrival(dynamic stopInfo, {bool renderImmediately = true}) {
      String typePrefix = stopInfo['type'] == 'pickup' ? 'P' : 'D';
      String nodeId = '$typePrefix${stopInfo['orderId']}';
      final String stopKey = '${stopInfo['orderId']}_${stopInfo['type']}';
      
      if (!_visitedStopIds.contains(stopKey)) {
        _visitedStopIds.add(stopKey);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Arrived at ${stopInfo['type'].toString().toUpperCase()} location"), backgroundColor: Colors.green, duration: const Duration(seconds: 2))
        );
        if (_routeStops.contains(stopInfo)) {
             _routeStops.remove(stopInfo);
             if (_routeSegments.isNotEmpty) _routeSegments.removeAt(0);
        }
        _orderRepository.removeRouteNode(token: widget.token, nodeId: nodeId);
        if (renderImmediately) _updateMapObjects();
      }
  }

  void _showManualArrivalDialog(dynamic loc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirm Arrival?"),
        content: Text("Are you at the ${loc['type']} location for Order #${loc['orderId']}?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("No")),
          ElevatedButton(onPressed: () {
              Navigator.pop(ctx);
              _triggerArrival(loc, renderImmediately: true);
            }, child: const Text("Yes, I'm here")),
        ],
      ),
    );
  }

  void _updateMapObjects() {
    if (!mounted) return;
    final Set<Polyline> newPolylines = {};
    final Set<Marker> newMarkers = {};

    for (int i = 0; i < _routeSegments.length; i++) {
      final isFirstRoute = (i == 0);
      newPolylines.add(Polyline(
        polylineId: PolylineId('route_border_$i'),
        points: _routeSegments[i],
        color: Colors.black, 
        width: isFirstRoute ? 9 : 6,
        zIndex: isFirstRoute ? 10 : 1,
        jointType: JointType.round,
        endCap: Cap.roundCap,
        startCap: Cap.roundCap,
      ));
      newPolylines.add(Polyline(
        polylineId: PolylineId('route_main_$i'),
        points: _routeSegments[i],
        color: isFirstRoute ? const Color.fromARGB(255, 33, 150, 243) : Colors.grey,
        width: isFirstRoute ? 5 : 3, 
        zIndex: isFirstRoute ? 11 : 2, 
        jointType: JointType.round,
        endCap: Cap.roundCap,
        startCap: Cap.roundCap,
      ));
    }

    for (int i = 0; i < _routeStops.length; i++) {
       final loc = _routeStops[i];
       if (loc['lat'] != null && loc['lng'] != null) {
          double markerHue = BitmapDescriptor.hueRed; 
          bool isPickup = (loc['type'] == 'pickup');
          if (isPickup) markerHue = BitmapDescriptor.hueAzure; 
          final isNextStop = (i == 0); 
          final canVerify = isPickup && isNextStop; 
          newMarkers.add(Marker(
            markerId: MarkerId('${loc['orderId']}_${loc['type']}'),
            position: LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble()),
            infoWindow: InfoWindow(title: '${loc['type'].toString().toUpperCase()} #${loc['orderId']}', snippet: canVerify ? 'Tap marker to verify arrival' : null),
            icon: BitmapDescriptor.defaultMarkerWithHue(markerHue),
            zIndex: isNextStop ? 15 : 5,
            onTap: canVerify ? () => _showManualArrivalDialog(loc) : null, 
          ));
       }
    }

    final activeOrders = Provider.of<OrderController>(context, listen: false).orders;
    for (var order in activeOrders) {
       if (_pickupCoordinates.containsKey(order.orderId) && order.status != 'finished') {
           final markerIdVal = '${order.orderId}_pickup';
           bool alreadyExists = newMarkers.any((m) => m.markerId.value == markerIdVal);
           if (!alreadyExists) {
               newMarkers.add(Marker(
                   markerId: MarkerId(markerIdVal),
                   position: _pickupCoordinates[order.orderId]!,
                   infoWindow: InfoWindow(title: 'Pickup #${order.orderId} (Done)', snippet: order.pickupLocation),
                   icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                   alpha: 0.6, zIndex: 4,
               ));
           }
       }
    }

    if (_currentPosition != null) {
        newMarkers.add(Marker(
            markerId: MarkerId('driver_${widget.driverId}'),
            position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
            zIndex: 100,
        ));
    }

    setState(() {
      polylines = newPolylines;
      markers = newMarkers;
    });
  }

  Future<void> _fetchOptimizedRoute() async {
    if (!mounted) return;
    final orderController = Provider.of<OrderController>(context, listen: false);
    try {
      await orderController.fetchOrders(token: widget.token, driverId: widget.driverId);
      final data = await _orderRepository.fetchOptimizedRoute(token: widget.token, driverId: widget.driverId);
      if (!mounted) return;

      final rawPolylines = data['polylines'] as List<dynamic>? ?? [];
      final rawStops = data['order'] as List<dynamic>? ?? [];

      if (rawPolylines.isEmpty) {
          setState(() { _routeSegments = []; _routeStops = []; });
          _updateMapObjects(); 
          return;
      }

      final simplifiedSegments = await compute(_processRouteInBackground, RouteProcessParams(rawPolylines));
      List<dynamic> filteredStops = [];
      List<List<LatLng>> filteredSegments = [];

      int segmentIndex = 0;
      for (var stop in rawStops) {
          final String stopId = '${stop['orderId']}_${stop['type']}';
          int? oId = int.tryParse(stop['orderId'].toString());
          if (oId != null && stop['type'] == 'pickup' && stop['lat'] != null && stop['lng'] != null) {
             _pickupCoordinates[oId] = LatLng((stop['lat'] as num).toDouble(), (stop['lng'] as num).toDouble());
          }
          if (!_visitedStopIds.contains(stopId)) {
              filteredStops.add(stop);
              if (segmentIndex < simplifiedSegments.length) {
                  filteredSegments.add(simplifiedSegments[segmentIndex]);
              }
          }
          segmentIndex++;
      }
      _routeSegments = filteredSegments;
      _routeStops = filteredStops;
      _updateMapObjects();
    } catch (e) {
      print(e);
    }
  }

  Future<void> _finishOrder(Order order) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.camera, imageQuality: 50);
      if (image == null) return; 
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Uploading proof of delivery...')));

      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final response = await _orderRepository.finishOrder(
        token: widget.token, orderId: order.orderId, imagePath: image.path, lat: position.latitude, lng: position.longitude,
      );
      final respStr = await response.stream.bytesToString();
      
      if (response.statusCode == 200) {
        if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order finished successfully!')));
            Provider.of<OrderController>(context, listen: false).fetchOrders(token: widget.token, driverId: widget.driverId);
            _fetchOptimizedRoute();
        }
      } else {
        String errorMessage = 'Failed to finish order';
        try {
          final errorJson = jsonDecode(respStr);
          if (errorJson['error'] != null) errorMessage = errorJson['error'];
        } catch (_) {}
        if (mounted) _showErrorDialog(errorMessage);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delivery Failed"),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("OK"))],
      ),
    );
  }

  void _zoomToOrder(int orderId) {
    List<LatLng> points = [];
    if (_currentPosition != null) points.add(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    if (_pickupCoordinates.containsKey(orderId)) points.add(_pickupCoordinates[orderId]!);

    final dropoffStop = _routeStops.firstWhere(
      (stop) => stop['orderId'].toString() == orderId.toString() && stop['type'] == 'dropoff',
      orElse: () => null,
    );

    if (dropoffStop != null && dropoffStop['lat'] != null && dropoffStop['lng'] != null) {
      points.add(LatLng((dropoffStop['lat'] as num).toDouble(), (dropoffStop['lng'] as num).toDouble()));
    }

    if (points.isNotEmpty && mapController != null) {
       if (points.length == 1) {
          mapController!.animateCamera(CameraUpdate.newLatLngZoom(points[0], 16));
       } else {
          LatLngBounds bounds = _boundsFromLatLngList(points);
          mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 45.0));
       }
    } else {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Location data not available for this order.")));
    }
  }

  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double? x0, x1, y0, y1;
    for (LatLng latLng in list) {
      if (x0 == null) {
        x0 = x1 = latLng.latitude;
        y0 = y1 = latLng.longitude;
      } else {
        if (latLng.latitude > x1!) x1 = latLng.latitude;
        if (latLng.latitude < x0!) x0 = latLng.latitude;
        if (latLng.longitude > y1!) y1 = latLng.longitude;
        if (latLng.longitude < y0!) y0 = latLng.longitude;
      }
    }
    return LatLngBounds(northeast: LatLng(x1!, y1!), southwest: LatLng(x0!, y0!));
  }

  void _setupPanelHeights(BuildContext context) {
    if (_panelHeight == 0) {
      final double screenHeight = MediaQuery.of(context).size.height;
      _maxPanelHeight = screenHeight * 0.4; 
      _minPanelHeight = 70; 
      _panelHeight = _maxPanelHeight; 
    }
  }

  void _onPanelDragUpdate(DragUpdateDetails details) {
    setState(() {
      _isDragging = true;
      _panelHeight -= details.delta.dy;
      if (_panelHeight > _maxPanelHeight) _panelHeight = _maxPanelHeight;
      if (_panelHeight < _minPanelHeight) _panelHeight = _minPanelHeight;
    });
  }

  void _onPanelDragEnd(DragEndDetails details) {
    final double screenHeight = MediaQuery.of(context).size.height;
    final double threshold = screenHeight * 0.25; 

    setState(() {
      _isDragging = false;
      if (_isPanelOpen) {
        if ((_maxPanelHeight - _panelHeight) > threshold) {
          _panelHeight = _minPanelHeight;
          _isPanelOpen = false;
        } else {
          _panelHeight = _maxPanelHeight; 
        }
      } else {
        if ((_panelHeight - _minPanelHeight) > threshold) {
          _panelHeight = _maxPanelHeight;
          _isPanelOpen = true;
        } else {
          _panelHeight = _minPanelHeight; 
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final orderController = Provider.of<OrderController>(context);
    _setupPanelHeights(context);

    // pad map so panel doesnt hide controls
    final double currentMapPadding = _panelHeight + 20;

    return Scaffold(
      
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              padding: EdgeInsets.only(bottom: currentMapPadding),
              initialCameraPosition: CameraPosition(
                target: _currentPosition != null
                    ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
                    : const LatLng(22.3193, 114.1694),
                zoom: 15,
              ),
              myLocationEnabled: false, 
              myLocationButtonEnabled: true,
              zoomControlsEnabled: true,
              mapToolbarEnabled: false,
              onMapCreated: (controller) {
                mapController = controller;
                if (_currentPosition != null) {
                   _isMapInitialized = true;
                }
              },
              polylines: polylines,
              markers: markers,
            ),
          ),

          AnimatedPositioned(
            duration: _isDragging ? Duration.zero : const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            height: _panelHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    spreadRadius: 2,
                  )
                ]
              ),
              child: Column(
                children: [
                  GestureDetector(
                    onVerticalDragUpdate: _onPanelDragUpdate,
                    onVerticalDragEnd: _onPanelDragEnd,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        children: [
                          Container(
                            width: 40,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(5)
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text("Driver Orders", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),

                  Expanded(
                    child: orderController.orders.isEmpty 
                    ? const Center(child: Text("No active orders"))
                    : ListView.builder(
                      padding: const EdgeInsets.all(0),
                      itemCount: orderController.orders.length,
                      itemBuilder: (context, index) {
                        final order = orderController.orders[index];
                        bool isPickedUp = !_routeStops.any((stop) => 
                            stop['orderId'].toString() == order.orderId.toString() && 
                            stop['type'] == 'pickup'
                        );

                        return Card(
                          margin: const EdgeInsets.all(8),
                          child: ListTile(
                            onTap: () => _zoomToOrder(order.orderId),
                            title: Text('Order #${order.orderId}'),
                            subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                    Text('Pickup: ${order.pickupLocation}'),
                                    const SizedBox(height: 4),
                                    Text('Dropoff: ${order.dropoffLocation}'),
                                    const SizedBox(height: 4),
                                    Text('Status: ${order.status}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                ],
                            ),
                            isThreeLine: true,
                            trailing: order.status != 'finished'
                                ? ElevatedButton(
                                    onPressed: isPickedUp ? () => _finishOrder(order) : null, 
                                    child: Text(isPickedUp ? 'Finish' : 'Require PickUp'),
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
