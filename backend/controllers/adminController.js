const { db, admin } = require('../config');
const { getNextSequenceValue, geocodeAddress } = require('../utils');
const { allocateOrderToBestDriver } = require('../services/allocationService');
const bcrypt = require('bcrypt');

// Admin Dashboard Stats
exports.getDashboardStats = async (req, res) => {
    try {
        const now = new Date();
        const startOfToday = new Date();
        startOfToday.setHours(0, 0, 0, 0);

        const sevenDaysAgo = new Date();
        sevenDaysAgo.setDate(now.getDate() - 7);

        // Fetch Finished Orders
        const finishedOrdersSnap = await db.collection('orders')
            .where('status', '==', 'finished')
            .get();

        // Fetch Active Orders
        const availableOrdersSnap = await db.collection('orders')
            .where('status', '!=', 'finished')
            .get();

        // --- CALCULATION VARIABLES ---
        
        // Global Counts
        const finishedCount = finishedOrdersSnap.size;
        const activeCount = availableOrdersSnap.size;
        const totalOrdersCount = finishedCount + activeCount;
        
        let inProgressCount = 0;
        let pendingCount = 0;
        let lateCount = 0;
        
        // Time and quality metrics
        let totalDeliveryTimeMs = 0;
        let onTimeCount = 0;
        
        // Today metrics
        let newOrdersTodayCount = 0;
        let todayDeliveryTimeMs = 0;
        let todayOnTimeCount = 0;
        let todayFinishedCount = 0;

        // --- PROCESS FINISHED ORDERS ---
        finishedOrdersSnap.forEach(doc => {
            const data = doc.data();
        
            let end = null;
            if (data.dropoff_time && typeof data.dropoff_time.toDate === 'function') end = data.dropoff_time.toDate();
            else if (data.dropoff_time) end = new Date(data.dropoff_time);

            let start = null;
            if (data.timestamp && typeof data.timestamp.toDate === 'function') start = data.timestamp.toDate();
            else if (data.create_time && typeof data.create_time.toDate === 'function') start = data.create_time.toDate();
            
            // delivery Time and On Time count
            if (start && end) {
                const duration = end - start;
                if (duration > 0) totalDeliveryTimeMs += duration;
            }
            if (data.on_time === true) onTimeCount++;
            else if (data.on_time === false) lateCount++;

            // check if created today
            if (start && start >= startOfToday) {
                newOrdersTodayCount++;
            }

            // check if finished today
            if (end && end >= startOfToday) {
                if (start) {
                    const duration = end - start;
                    if (duration > 0) todayDeliveryTimeMs += duration;
                }
                todayFinishedCount++;
                if (data.on_time === true) todayOnTimeCount++;
            }
        });

        // --- PROCESS ACTIVE ORDERS ---
        availableOrdersSnap.forEach(doc => {
            const data = doc.data();
            const status = data.status || 'pending';

            if (status === 'pending') {
                pendingCount++;
            } else {
                inProgressCount++;
            }

            let start = null;
            if (data.timestamp && typeof data.timestamp.toDate === 'function') start = data.timestamp.toDate();
            else if (data.create_time && typeof data.create_time.toDate === 'function') start = data.create_time.toDate();

            if (start && start >= startOfToday) {
                newOrdersTodayCount++;
            }
        });

        // --- RATINGS ---
        const ratingsSnap = await db.collectionGroup('ratings').get();
        const ratingDist = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
        let totalRatings = 0;
        let totalRatingScore = 0;
        let todayRatingCount = 0;
        let todayRatingScore = 0;

        ratingsSnap.forEach(doc => {
            const data = doc.data();
            const r = data.score;
            const score = Math.round(r);
            if (score >= 1 && score <= 5) {
                ratingDist[score]++;
                totalRatings++;
                totalRatingScore += r;
            }
            
            let created = null;
            if (data.create_time && typeof data.create_time.toDate === 'function') created = data.create_time.toDate();
            if (created && created >= startOfToday) {
                todayRatingCount++;
                todayRatingScore += r;
            }
        });

        // --- WORKING DRIVERS ---
        const driversSnap = await db.collection('drivers').get();
        let workingDriversCount = 0;
        const currentHour = now.getHours();
        driversSnap.forEach(doc => {
            const d = doc.data();
            if (d.working_time && d.working_time.includes('-')) {
                try {
                    const parts = d.working_time.split('-');
                    const startH = parseInt(parts[0].trim().split(':')[0], 10);
                    const endH = parseInt(parts[1].trim().split(':')[0], 10);
                    if (!isNaN(startH) && !isNaN(endH) && currentHour >= startH && currentHour < endH) {
                        workingDriversCount++;
                    }
                } catch (e) {}
            }
        });

        // --- CALCULATE AVERAGES ---
        const avgDeliveryTimeMinutes = finishedCount > 0 ? Math.round((totalDeliveryTimeMs / finishedCount) / 60000) : 0;
        const onTimePercentage = finishedCount > 0 ? Math.round((onTimeCount / finishedCount) * 100) : 0;
        const globalAvgRating = totalRatings > 0 ? parseFloat((totalRatingScore / totalRatings).toFixed(1)) : 0.0;

        const todayAvgDelivery = todayFinishedCount > 0 ? Math.round((todayDeliveryTimeMs / todayFinishedCount) / 60000) : 0;
        const todayOnTime = todayFinishedCount > 0 ? Math.round((todayOnTimeCount / todayFinishedCount) * 100) : 0;
        const todayAvgRating = todayRatingCount > 0 ? parseFloat((todayRatingScore / todayRatingCount).toFixed(1)) : 0.0;

        // --- VOLUME CHART ---
        const getHKDateString = (dateObj) => {
            const hkDate = new Date(dateObj.getTime() + (8 * 60 * 60 * 1000));
            return hkDate.toISOString().split('T')[0];
        };

        const recentOrdersSnap = await db.collection('orders')
            .where('timestamp', '>=', sevenDaysAgo)
            .get();

        const weeklyVolume = {};
        
        for (let i = 6; i >= 0; i--) {
            const d = new Date();
            d.setDate(now.getDate() - i);
            const key = getHKDateString(d); 
            weeklyVolume[key] = 0;
        }

        recentOrdersSnap.forEach(doc => {
            const data = doc.data();
            
            let dateObj = null;
            if (data.timestamp && typeof data.timestamp.toDate === 'function') {
                dateObj = data.timestamp.toDate();
            } else if (data.create_time && typeof data.create_time.toDate === 'function') {
                dateObj = data.create_time.toDate();
            }

            if (dateObj) {
                const dateKey = getHKDateString(dateObj);
                
                if (weeklyVolume[dateKey] !== undefined) {
                    weeklyVolume[dateKey]++;
                }
            }
        });

        const volumeChartData = Object.keys(weeklyVolume).sort().map(date => ({ 
            date, 
            count: weeklyVolume[date] 
        }));

        res.json({
            metrics: {
                avg_delivery_time_mins: avgDeliveryTimeMinutes,
                on_time_percentage: onTimePercentage,
                total_finished_orders: finishedCount,
                total_ratings: totalRatings,
                avg_rating: globalAvgRating,
                
                total_orders_all_time: totalOrdersCount,
                in_progress_count: inProgressCount,
                pending_count: pendingCount,
                total_late: lateCount,
                working_drivers: workingDriversCount,
                
                today: {
                    avg_delivery: todayAvgDelivery,
                    on_time: todayOnTime,
                    new_orders: newOrdersTodayCount,
                    avg_rating: todayAvgRating
                }
            },
            rating_distribution: ratingDist,
            weekly_volume: volumeChartData
        });

    } catch (err) {
        console.error("Dashboard Stats Error:", err);
        res.status(500).json({ error: err.message });
    }
};

exports.getPreferences = async (req, res) => {
    try {
        const doc = await db.collection('admins').doc(String(req.admin.id)).get();
        if (!doc.exists) {
            return res.json({ widget_order: [], visible_widgets: [] }); 
        }
        const data = doc.data();
        res.json(data.dashboard_preferences || { widget_order: [], visible_widgets: [] });
    } catch (err) {
        console.error("Get Prefs Error:", err);
        res.status(500).json({ error: err.message });
    }
};

exports.savePreferences = async (req, res) => {
    try {
        const { widget_order, visible_widgets } = req.body;
        console.log(`[Admin Prefs] Saving for Admin ${req.admin.id}...`);

        await db.collection('admins').doc(String(req.admin.id)).set({
            dashboard_preferences: {
                widget_order,
                visible_widgets
            }
        }, { merge: true });
        res.json({ success: true });
    } catch (err) {
        console.error("Save Prefs Error:", err);
        res.status(500).json({ error: err.message });
    }
};

exports.getMapsKey = async (req, res) => {
    res.json({ key: process.env.GOOGLE_MAPS_WEB_KEY || process.env.API_KEY });
};

exports.getMasterMapDrivers = async (req, res) => {
    try {
        const driversSnap = await db.collection('drivers').get();
        const drivers = [];
        
        driversSnap.forEach(doc => {
            const d = doc.data();

            // 1. Only show drivers who have a location
            if (d.current_lat && d.current_lng) {
                
                // 2. Determine Current Task
                let currentTask = "Idle";
                if (d.expected_route && d.expected_route.length > 0) {
                    const nextNode = d.expected_route.find(node => node !== "");
                    if (nextNode) currentTask = nextNode;
                }

                drivers.push({
                    driver_id: parseInt(doc.id, 10),
                    name: d.name || "Unknown",
                    avg_rating: d.avg_rating || 0.0,
                    vehicle_details: d.vehicle_details || "N/A",
                    max_weight: d.max_weight || 50,
                    phone: d.phone || "N/A",
                    working_time: d.working_time || "N/A",
                    current_lat: d.current_lat,
                    current_lng: d.current_lng,
                    expected_route: d.expected_route || [],
                    expected_time: d.expected_time || [],
                    current_task: currentTask
                });
            }
        });

        res.json(drivers);
    } catch (err) {
        console.error("Master Map Error:", err);
        res.status(500).json({ error: err.message });
    }
};

exports.getAllRecords = async (req, res) => {
    let collectionName = req.params.table;
    
    try {
        if (collectionName === 'ratings') {
            const snapshot = await db.collectionGroup('ratings').get();
            const items = [];
            snapshot.forEach(doc => {
                const driverId = doc.ref.parent.parent.id;
                items.push({ 
                    id: parseInt(doc.id, 10), 
                    driver_id: parseInt(driverId, 10),
                    ...doc.data() 
                });
            });
            return res.json(items);
        }

        // Standard logic for root collections
        const snapshot = await db.collection(collectionName).get();
        const items = snapshot.docs.map(doc => ({ ...doc.data(), id: parseInt(doc.id, 10) }));
        res.json(items);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};

exports.getRecordById = async (req, res) => {
    const { table, id } = req.params;
    const validTables = ['customers', 'drivers', 'orders', 'ratings', 'admins'];
    if (!validTables.includes(table)) return res.status(400).json({ error: `Invalid table: ${table}` });

    try {
        if (table === 'ratings') {
            const snapshot = await db.collectionGroup('ratings').get();
            const doc = snapshot.docs.find(d => d.id === id);
            
            if (doc) {
                const data = doc.data();
                const driverId = doc.ref.parent.parent.id;
                res.json({ 
                    id: parseInt(doc.id, 10), 
                    driver_id: parseInt(driverId, 10),
                    ...data 
                });
            } else {
                res.status(404).json({ error: `Rating with ID ${id} not found.` });
            }
        } else {
            const doc = await db.collection(table).doc(id).get();
            if (doc.exists) {
                res.json({ id: parseInt(doc.id, 10), ...doc.data() });
            } else {
                res.status(404).json({ error: `Record with ID ${id} not found in ${table}` });
            }
        }
    } catch (err) {
        res.status(500).json({ error: 'Database error: ' + err.message });
    }
};

//Create Order (Geocode & Dispatch)
exports.createRecord = async (req, res) => {
    const { table } = req.params;
    const data = req.body;
    let collectionName = table;

    
    if (table === 'orders') {
        const { user_id, pickup_location, dropoff_location, weight } = data;
        
        if (!user_id || !pickup_location || !dropoff_location || !weight) {
            return res.status(400).json({ error: 'Missing required fields: user_id, pickup, dropoff, weight' });
        }

        try {
            // 1. Geocode Addresses
            let pickupCoord, dropoffCoord;
            try {
                pickupCoord = await geocodeAddress(pickup_location);
                dropoffCoord = await geocodeAddress(dropoff_location);
            } catch (e) {
                return res.status(400).json({ error: `Geocoding failed: ${e.message}` });
            }

            // 2. Generate ID
            const orderId = await getNextSequenceValue('order_id');

            // 3. Prepare Order Data
            const newOrderData = {
                order_id: orderId,
                user_id: parseInt(user_id, 10),
                driver_id: null,
                pickup_location,
                dropoff_location,
                pickup_coordinate: new admin.firestore.GeoPoint(pickupCoord.lat, pickupCoord.lng),
                dropoff_coordinate: new admin.firestore.GeoPoint(dropoffCoord.lat, dropoffCoord.lng),
                status: 'pending',
                weight: parseFloat(weight),
                timestamp: admin.firestore.FieldValue.serverTimestamp(),
                create_time: admin.firestore.FieldValue.serverTimestamp(),
                pickup_time: null,
                dropoff_time: null,
                proof_of_delivery: null
            };

            await db.collection('orders').doc(String(orderId)).set(newOrderData);

            // 4. Trigger auto allocation
            
            allocateOrderToBestDriver(orderId, pickupCoord, dropoffCoord, parseFloat(weight), (err, result) => {
                if (err) console.error(`[Admin] Allocation failed for order ${orderId}:`, err.message);
                else console.log(`[Admin] Order ${orderId} assigned to driver ${result.driverId}`);
            });

            return res.status(201).json({ message: 'Order created and dispatched', id: orderId });

        } catch (err) {
            console.error("Admin Add Order Error:", err);
            return res.status(500).json({ error: 'Failed to create order: ' + err.message });
        }
    }

    // --- GENERIC LOGIC for other tables (Customers, Drivers, Admins) ---
    try {
      const idFieldMap = {
        customers: 'customer_id',
        drivers: 'driver_id',
        admins: 'admin_id',
        ratings: 'rating_id', 
        orders: 'order_id', 
      };
      const idField = idFieldMap[table];
      
      if (!idField) {
        return res.status(400).json({ error: `Table "${table}" does not support sequential ID generation.`});
      }
  
      const newId = await getNextSequenceValue(idField);
      
      if ((table === 'customers' || table === 'drivers' || table === 'admins') && data.password) {
          data.password = await bcrypt.hash(data.password, 10);
      }
      
      if (!data.create_time && !data.timestamp) {
          data.create_time = admin.firestore.FieldValue.serverTimestamp();
      }

      await db.collection(collectionName).doc(String(newId)).set(data);
  
      res.status(201).json({ message: 'Record added successfully', id: newId });
    } catch (err) {
      console.error(`Error adding record to ${table}:`, err);
      res.status(500).json({ error: 'Failed to add record.' });
    }
};

exports.updateRecord = async (req, res) => {
    const { table, id } = req.params;
    const data = req.body;

    const validTables = ['customers', 'drivers', 'orders', 'ratings', 'admins'];
    if (!validTables.includes(table)) return res.status(400).json({ error: `Invalid table: ${table}` });

    let collectionName = table;


    try {
      if ((table === 'customers' || table === 'drivers' || table === 'admins') && data.password) {
          if (!data.password.startsWith('$2b$')) {
            data.password = await bcrypt.hash(data.password, 10);
          }
      }
      
      await db.collection(collectionName).doc(id).update(data);
      res.json({ message: 'Record updated successfully' });
    } catch (err) {
        res.status(500).json({ error: 'Failed to update record.' });
    }
};

exports.deleteRecord = async (req, res) => {
    const { table, id } = req.params;
    const validTables = ['customers', 'drivers', 'orders', 'ratings', 'admins'];
    if (!validTables.includes(table)) return res.status(400).json({ error: `Invalid table: ${table}` });

    try {
        if (table === 'orders') {
            const orderDoc = await db.collection('orders').doc(id).get();
            
            if (orderDoc.exists) {
                const orderData = orderDoc.data();
                const driverId = orderData.driver_id;

                if (driverId) {
                    const driverRef = db.collection('drivers').doc(String(driverId));
                    
                    await db.runTransaction(async (t) => {
                        const driverDoc = await t.get(driverRef);
                        if (!driverDoc.exists) return;

                        const dData = driverDoc.data();
                        const pNode = `P${id}`;
                        const dNode = `D${id}`;

                        let oldRoute = dData.expected_route || [];
                        let oldWeights = dData.available_weight || [];
                        let oldTimes = dData.expected_time || [];

                        // 1.Calculate the weight change for every existing node
                        let nodeWeightChanges = {};
                        for (let i = 0; i < oldRoute.length; i++) {
                            if (i + 1 < oldWeights.length) {
                                nodeWeightChanges[oldRoute[i]] = oldWeights[i + 1] - oldWeights[i];
                            }
                        }

                        // 2.Filter the route and times array
                        let newRoute = [];
                        let newTimes = [];
                        for (let i = 0; i < oldRoute.length; i++) {
                            if (oldRoute[i] !== pNode && oldRoute[i] !== dNode) {
                                newRoute.push(oldRoute[i]);
                                if (i < oldTimes.length) {
                                    newTimes.push(oldTimes[i]);
                                }
                            }
                        }

                        // 3. Recalculate the available_weight array
                        let newWeights = [];
                        if (oldWeights.length > 0) {
                            let currentCap = oldWeights[0];
                            if (oldRoute.includes(dNode) && !oldRoute.includes(pNode)) {
                                const deletedWeight = orderData.weight ? parseFloat(orderData.weight) : 0;
                                currentCap += deletedWeight;
                                
                                const maxWeight = dData.max_weight ? parseFloat(dData.max_weight) : 50;
                                if (currentCap > maxWeight) currentCap = maxWeight;
                            }

                            newWeights.push(currentCap);

                            for (let i = 0; i < newRoute.length; i++) {
                                let node = newRoute[i];
                                let delta = nodeWeightChanges[node] || 0;
                                currentCap += delta;
                                newWeights.push(currentCap);
                            }
                        }

                        t.update(driverRef, {
                            expected_route: newRoute,
                            available_weight: newWeights,
                            expected_time: newTimes
                        });
                    });
                    console.log(`Cleaned up route for driver ${driverId} after deleting order ${id}`);
                }
            }
            await db.collection('orders').doc(id).delete();
            return res.json({ message: 'Order deleted and driver route cleaned up.' });
        } 
        
        else if (table === 'ratings') {
            const snapshot = await db.collectionGroup('ratings').get();
            const doc = snapshot.docs.find(d => d.id === id);

            if (doc) {
                await doc.ref.delete();
                return res.json({ message: 'Rating deleted successfully' });
            } else {
                return res.status(404).json({ error: 'Rating not found' });
            }
        }

        await db.collection(table).doc(id).delete();
        res.json({ message: 'Record deleted successfully' });

    } catch (err) {
        console.error("Delete Error:", err);
        res.status(500).json({ error: 'Failed to delete record: ' + err.message });
    }
};
