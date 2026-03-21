const { db } = require('../config');
const { decodePolyline, googleMapsClient } = require('../utils');

exports.getDriverBasic = async (req, res) => {
    try {
        const driverId = req.params.id;
        const doc = await db.collection('drivers').doc(driverId).get();
        if (!doc.exists) {
            res.status(404).json({ error: 'Driver not found' });
        } else {
            const { name } = doc.data();
            res.json({ driver_id: parseInt(doc.id, 10), name });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.getDriverDetails = async (req, res) => {
    const driverId = req.params.id;
    if (String(req.user.id) != driverId || req.user.type !== 'driver') {
        return res.status(403).json({ error: 'Unauthorized' });
    }
    try {
        const doc = await db.collection('drivers').doc(driverId).get();
        if (doc.exists) {
            const { password, ...driverData } = doc.data();
            res.json({driver_id: parseInt(doc.id, 10), ...driverData});
        } else {
            res.status(404).json({ error: 'Driver not found' });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.getDriverRating = async (req, res) => {
    try {
        const driverId = req.params.id;
        const snapshot = await db.collection('drivers').doc(driverId).collection('ratings').get();
        if (snapshot.empty) {
            return res.json({ average_rating: 0 });
        }
        let totalScore = 0;
        snapshot.forEach(doc => { totalScore += doc.data().score; });
        const average_rating = totalScore / snapshot.size;
        res.json({ average_rating });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.updateLocation = async (req, res) => {
    const { latitude, longitude } = req.body;
    if (req.user.type !== 'driver') return res.status(403).json({error: 'Unauthorized'});
    try {
        await db.collection('drivers').doc(String(req.user.id)).update({ current_lat: latitude, current_lng: longitude });
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.getLocation = async (req, res) => {
    try {
        const driverId = req.params.id;
        const doc = await db.collection('drivers').doc(driverId).get();
        if (!doc.exists) return res.status(404).json({ error: 'Not found' });
            
        const { current_lat, current_lng } = doc.data();
        res.json({ current_lat, current_lng });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.getRoute = async (req, res) => {
const driverId = req.params.id;
    if (String(req.user.id) !== driverId && req.user.type !== 'admin') {
        if (req.user.type !== 'driver' || String(req.user.id) !== driverId) {
             return res.status(403).json({ error: 'Unauthorized' });
        }
    }

    try {
        // 1. Get Driver Info and Expected Route
        const driverDoc = await db.collection('drivers').doc(driverId).get();
        if (!driverDoc.exists) return res.status(404).json({ error: 'Driver not found' });
        
        const driverData = driverDoc.data();
        const origin = (driverData.current_lat && driverData.current_lng) 
            ? `${driverData.current_lat},${driverData.current_lng}` 
            : "22.3193,114.1694"; 
        
        const expectedRoute = driverData.expected_route || [];

        // 2. Get Active Orders Map
        const ordersSnapshot = await db.collection('orders')
            .where('driver_id', '==', parseInt(driverId))
            .where('status', 'in', ['assigned', 'in_progress'])
            .get();

        if (ordersSnapshot.empty || expectedRoute.length === 0) {
            return res.json({ order: [], polylines: [] }); 
        }

        const ordersMap = {};
        ordersSnapshot.forEach(doc => {
            ordersMap[doc.id] = { id: doc.id, ...doc.data() };
        });

        // 3. Construct Waypoints in order of expected_route
        const waypoints = [];
        const orderInfo = [];

        for (const node of expectedRoute) {
            const type = node.charAt(0);
            const oid = node.substring(1);
            
            const order = ordersMap[oid];
            if (!order) continue;

            if (type === 'P') {
                if (order.pickup_coordinate) {
                    waypoints.push(`${order.pickup_coordinate.latitude},${order.pickup_coordinate.longitude}`);
                    orderInfo.push({ 
                        address: order.pickup_location, 
                        lat: order.pickup_coordinate.latitude, 
                        lng: order.pickup_coordinate.longitude,
                        type: 'pickup',
                        orderId: order.id
                    });
                } else {
                    waypoints.push(order.pickup_location);
                    orderInfo.push({ address: order.pickup_location, type: 'pickup', orderId: order.id });
                }
            } else if (type === 'D') {
                if (order.dropoff_coordinate) {
                    waypoints.push(`${order.dropoff_coordinate.latitude},${order.dropoff_coordinate.longitude}`);
                    orderInfo.push({ 
                        address: order.dropoff_location, 
                        lat: order.dropoff_coordinate.latitude, 
                        lng: order.dropoff_coordinate.longitude,
                        type: 'dropoff',
                        orderId: order.id
                    });
                } else {
                    waypoints.push(order.dropoff_location);
                    orderInfo.push({ address: order.dropoff_location, type: 'dropoff', orderId: order.id });
                }
            }
        }

        if (waypoints.length === 0) return res.json({ order: [], polylines: [] });

        // 4. Request Google Maps
        const destination = waypoints.pop();
        
        const response = await googleMapsClient.directions({
            params: { 
                origin: origin, 
                destination: destination, 
                waypoints: waypoints,
                optimize: false,
                key: process.env.API_KEY 
            },
        });

        if (response.data.routes && response.data.routes.length > 0) {
            const route = response.data.routes[0];
            const allLegsPolylines = [];
            
            if (route.legs) {
                route.legs.forEach(leg => {
                    let legPoints = [];
                    leg.steps.forEach(step => {
                        const stepPoints = decodePolyline(step.polyline.points);
                        const formattedStep = stepPoints.map(pt => ({ lat: pt[0], lng: pt[1] }));
                        legPoints = legPoints.concat(formattedStep);
                    });
                    allLegsPolylines.push(legPoints);
                });
            } else {
                const decodedPoints = decodePolyline(route.overview_polyline.points);
                allLegsPolylines.push(decodedPoints.map(pt => ({ lat: pt[0], lng: pt[1] })));
            }

            res.json({
                order: orderInfo,
                polylines: allLegsPolylines 
            });
        } else {
            res.json({ order: orderInfo, polylines: [] });
        }

    } catch (err) {
        console.error("Route error:", err);
        res.status(500).json({ error: err.message });
    }
};
exports.arriveNode = async (req, res) => { 
    const { node_id } = req.body;
    const driverId = req.user.id;

    if (!node_id) return res.status(400).json({ error: 'Node ID required' });

    try {
        const driverRef = db.collection('drivers').doc(String(driverId));
        
        await db.runTransaction(async (t) => {
            const doc = await t.get(driverRef);
            if (!doc.exists) throw new Error("Driver not found");
            
            const data = doc.data();
            let route = data.expected_route || [];
            let weights = data.available_weight || [];
            let times = data.expected_time || [];
            const index = route.indexOf(node_id);
            
            if (index !== -1) {
                route.splice(index, 1);
                
                if (index < weights.length) weights.splice(index, 1);
                if (index < times.length) times.splice(index, 1);
                
                t.update(driverRef, {
                    expected_route: route,
                    available_weight: weights,
                    expected_time: times
                });
            }
        });

        res.json({ success: true });
    } catch (err) {
        console.error("Error removing node:", err);
        res.status(500).json({ error: err.message });
    }
};
exports.getGoogleRoute = async (req, res) => {
    const { origin, destination } = req.body;
    try {
        const response = await googleMapsClient.directions({
        params: { origin, destination, key: process.env.API_KEY },
        });
        if (response.data.routes && response.data.routes.length > 0) {
            res.json({ path: response.data.routes[0].overview_polyline.points });
        } else {
            res.status(404).json({ error: 'No route found' });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};
