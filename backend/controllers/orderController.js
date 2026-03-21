const { db, admin, containerClient } = require('../config');
const { geocodeAddress, getNextSequenceValue, getDistanceFromLatLonInKm, googleMapsClient } = require('../utils');
const { allocateOrderToBestDriver } = require('../services/allocationService');
const fs = require('fs');
const path = require('path');

exports.createOrder = async (req, res) => {
    const { pickup_location, dropoff_location, weight } = req.body;
  
    if (!pickup_location || !dropoff_location || !weight) {
        return res.status(400).json({ error: 'Missing required fields' });
    }
    
    try {
        // 1. Geocode immediately to store coordinates in firestore
        let pickupCoord, dropoffCoord;
        try {
            pickupCoord = await geocodeAddress(pickup_location);
            dropoffCoord = await geocodeAddress(dropoff_location);
        } catch (e) {
            return res.status(400).json({ error: `Geocoding failed: ${e.message}` });
        }

        const orderId = await getNextSequenceValue('order_id');
        
        // 2. Store Order WITH coordinates
        const newOrderData = {
        user_id: req.user.id,
        driver_id: null,
        pickup_location,
        dropoff_location,
        pickup_coordinate: new admin.firestore.GeoPoint(pickupCoord.lat, pickupCoord.lng),
        dropoff_coordinate: new admin.firestore.GeoPoint(dropoffCoord.lat, dropoffCoord.lng),
        status: 'pending',
        weight,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        pickup_time: null,
        dropoff_time: null,
        proof_of_delivery: null
        };

        await db.collection('orders').doc(String(orderId)).set(newOrderData);

        // 3. Allocate using the stored coordinates
        allocateOrderToBestDriver(orderId, pickupCoord, dropoffCoord, parseFloat(weight), async (err, result) => {
            if (err) console.error(`Allocation failed for order ${orderId}:`, err.message);
            else {
                console.log(`Order ${orderId} assigned to driver ${result.driverId} with cost ${result.cost/60000} minutes.`);
            }
        });
        
        res.json({ orderId, message: 'Order created and is pending allocation.' });
    } catch (err) {
        res.status(500).json({ error: 'Failed to create order: ' + err.message });
    }
};

exports.getOrders = async (req, res) => {
    try {
        const snapshot = await db.collection('orders').where('user_id', '==', req.user.id).get();
        const orders = snapshot.docs.map(doc => ({ order_id: parseInt(doc.id, 10), ...doc.data() }));
        res.json(orders);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.checkRating = async (req, res) => {
    
try {
        const orderId = parseInt(req.params.id, 10);
        const orderDoc = await db.collection('orders').doc(String(orderId)).get();
        if (!orderDoc.exists) {
             return res.json({ rated: false }); 
        }
        
        const data = orderDoc.data();
        if (!data.driver_id) {
             return res.json({ rated: false });
        }
        const snapshot = await db.collection('drivers')
            .doc(String(data.driver_id))
            .collection('ratings')
            .where('order_id', '==', orderId)
            .limit(1)
            .get();
            
        res.json({ rated: !snapshot.empty });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.getEstimatedTime = async (req, res) => { 
try {
        const orderId = req.params.id;
        const orderDoc = await db.collection('orders').doc(orderId).get();

        if (!orderDoc.exists) {
            return res.status(404).json({ error: 'Order not found' });
        }

        const orderData = orderDoc.data();
        const driverId = orderData.driver_id;

        if (!driverId) {
            return res.json({ estimated_delivery_time: null, status: 'Pending Driver' });
        }

        const driverDoc = await db.collection('drivers').doc(String(driverId)).get();
        if (!driverDoc.exists) {
             return res.json({ estimated_delivery_time: null, status: 'Driver not found' });
        }

        const driverData = driverDoc.data();
        const cleanRoute = (driverData.expected_route || []).filter(node => node !== "");
        const times = driverData.expected_time || [];

        const dropoffNode = `D${orderId}`;
        const index = cleanRoute.indexOf(dropoffNode);

        if (index !== -1 && index < times.length) {
            const timestamp = times[index];
            const date = new Date(timestamp);
            return res.json({ estimated_delivery_time: date.toISOString() });
        } else {
             return res.json({ estimated_delivery_time: null, status: 'Not in route' });
        }

    } catch (err) {
        console.error("Error fetching estimated time:", err);
        res.status(500).json({ error: err.message });
    }
};

exports.submitRating = async (req, res) => {
    const { order_id, driver_id, score, comment } = req.body;
    try {
        // 1. Check for existing rating
        const existingRating = await db.collection('drivers')
            .doc(String(driver_id))
            .collection('ratings')
            .where('order_id', '==', order_id)
            .get();

        if (!existingRating.empty) {
            return res.status(400).json({ error: 'Order has already been rated.' });
        }

        // 2.Create rating
        const newRatingId = await getNextSequenceValue('rating_id'); 
        await db.collection('drivers').doc(String(driver_id)).collection('ratings').doc(String(newRatingId)).set({
            order_id,
            customer_id: req.user.id,
            driver_id,
            score,
            comment,
            create_time: admin.firestore.FieldValue.serverTimestamp()
        });

        res.json({ message: 'Rating submitted' });
    } catch (err) {
        if (err.message.includes('counters')) {
            try {
                // Fallback logic
                const fallbackId = Date.now().toString();
                await db.collection('drivers').doc(String(driver_id)).collection('ratings').doc(fallbackId).set({
                    order_id, 
                    customer_id: req.user.id,
                    driver_id, 
                    score, 
                    comment, 
                    create_time: admin.firestore.FieldValue.serverTimestamp()
                });
                return res.json({ message: 'Rating submitted' });
            } catch (e) {
                return res.status(500).json({ error: e.message });
            }
        }
        res.status(500).json({ error: err.message });
    }
};

exports.finishOrder = async (req, res) => {
    const { lat, lng } = req.body;
    const orderId = req.params.id;
    
    // 1. Basic validation
    if (!req.file) {
        return res.status(400).json({ error: 'Photo is required for proof of delivery.' });
    }
    if (!lat || !lng) {
        return res.status(400).json({ error: 'GPS location is required.' });
    }

    try {
        const orderRef = db.collection('orders').doc(orderId);
        const orderDoc = await orderRef.get();

        if (!orderDoc.exists) return res.status(404).json({ error: 'Order not found' });
        const orderData = orderDoc.data();

        if (orderData.driver_id !== req.user.id) {
        return res.status(403).json({ error: 'Order not assigned to this driver' });
        }

        // 2. distance check
        const driverLat = parseFloat(lat);
        const driverLng = parseFloat(lng);
        const dropoffLat = orderData.dropoff_coordinate.latitude;
        const dropoffLng = orderData.dropoff_coordinate.longitude;

        const distanceKm = getDistanceFromLatLonInKm(driverLat, driverLng, dropoffLat, dropoffLng);
        
        if (distanceKm > 0.2) {
            fs.unlinkSync(req.file.path); 
            return res.status(400).json({ 
                error: `Too far from destination! Distance: ${(distanceKm * 1000).toFixed(0)}m. Allowed: 200m.` 
            });
        }

        // 3. upload to azure blob storage
        let photoUrl = '';
        if (containerClient) {
            const blobName = `${orderId}${path.extname(req.file.originalname)}`;
            const blockBlobClient = containerClient.getBlockBlobClient(blobName);
            
            await blockBlobClient.uploadFile(req.file.path);
            photoUrl = blockBlobClient.url;
            fs.unlinkSync(req.file.path);
        } else {
            photoUrl = `/uploads/${req.file.filename}`; // fallback to local path
        }

        // 4. create pod
        const proofOfDelivery = {
            photo_url: photoUrl,
            driver_location: { lat: driverLat, lng: driverLng },
            captured_at: new Date().toISOString(),
            distance_offset_km: parseFloat(distanceKm.toFixed(4))
        };

        let onTime = false;
        
        if (orderData.expected_delivery_time) {
            const deadline = orderData.expected_delivery_time.toDate().getTime();
            const now = Date.now();
            const GRACE_PERIOD_MS = 5 * 60 * 1000; 

            if (now <= (deadline + GRACE_PERIOD_MS)) {
                onTime = true;
            }
        } else {
            onTime = true; 
        }

        // 5. update order status
        await orderRef.update({ 
            status: "finished", 
            proof_of_delivery: proofOfDelivery, 
            dropoff_time: admin.firestore.FieldValue.serverTimestamp(),
            on_time: onTime
        });
        // 6. Clear driver route
        const driverId = req.user.id;
        const driverRef = db.collection('drivers').doc(String(driverId));
        const driverDoc = await driverRef.get();
        
        if (driverDoc.exists) {
            let { expected_route, available_weight, expected_time } = driverDoc.data();
            const pNode = `P${orderId}`;
            const dNode = `D${orderId}`;
            
            if (expected_route) {
                let newRoute = [];
                let newWeights = [];
                let newTimes = [];
                
                for(let i=0; i<expected_route.length; i++) {
                    if (expected_route[i] !== pNode && expected_route[i] !== dNode) {
                        newRoute.push(expected_route[i]);
                        if (available_weight && available_weight.length > i) newWeights.push(available_weight[i]);
                        if (expected_time && expected_time.length > i) newTimes.push(expected_time[i]);
                    }
                }
                if (newRoute.length === 0) newTimes = [];

                await driverRef.update({
                    expected_route: newRoute,
                    available_weight: newWeights,
                    expected_time: newTimes
                });
            }
        }
        
        res.json({ success: true, message: 'Order finished successfully' });

    } catch (err) {
        console.error(err);
        res.status(500).json({ error: err.message });
    }
};

exports.getDriverOrders = async (req, res) => {
const driverId = parseInt(req.params.id, 10);
    if (req.user.id != driverId || req.user.type !== 'driver') return res.status(403).json({ error: 'Unauthorized' });
    try {
        const snapshot = await db.collection('orders')
            .where('driver_id', '==', driverId)
            .where('status', 'in', ['pending', 'in_progress'])
            .get();
        const orders = snapshot.docs.map(doc => ({ order_id: parseInt(doc.id, 10), ...doc.data()}));
        res.json(orders);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.findPlaces = async (req, res) => {
const { input } = req.body;
    try {
        if (req.user.type !== 'admin') {
            const doc = await db.collection('customers').doc(String(req.user.id)).get();
            if (!doc.exists) {
                return res.status(401).json({ error: 'User not found' });
            }
        }
        const response = await googleMapsClient.placeAutocomplete({
            params: { input, components: 'country:HK', key: process.env.API_KEY },
        });
        res.json({
            predictions: response.data.predictions.slice(0, 3),
            status: response.data.status
        });
    } catch (error) {
        res.status(400).json({ error: 'Failed to fetch places: ' + error.message });
    }
};

exports.geocodeAddressAPI = async (req, res) => {
    const { address } = req.body;
    if (!address) return res.status(400).json({ error: 'Address is required' });
    try {
        const coords = await geocodeAddress(address);
        res.json(coords);
    } catch (error) {
        res.status(400).json({ error: error.message });
    }
};
