const { db } = require('../config');
const { allocateOrderToBestDriver } = require('./allocationService');
const { getTravelTime } = require('../utils');

async function retryPendingAllocations() {
    console.log(`\n[${new Date().toLocaleTimeString()}] Checking for pending orders to allocate...`);
    
    try {
        // 1. Fetch ALL pending orders
        const pendingSnapshot = await db.collection('orders')
            .where('status', '==', 'pending')
            .get();

        if (pendingSnapshot.empty) {
            console.log("   -> No pending orders found.");
            return;
        }

        // 2. Convert to Array and Sort by Order ID
        let pendingOrders = [];
        pendingSnapshot.forEach(doc => {
            pendingOrders.push({ id: doc.id, ...doc.data() });
        });

        pendingOrders.sort((a, b) => parseInt(a.id) - parseInt(b.id));

        console.log(`   -> Found ${pendingOrders.length} pending orders. Processing sequentially...`);

        // 3. Process Sequentially
        for (const order of pendingOrders) {
            const orderId = parseInt(order.id);
            console.log(`   -> Attempting to allocate Pending Order #${orderId} (Weight: ${order.weight}kg)...`);

            if (!order.pickup_coordinate || !order.dropoff_coordinate) {
                console.error(`  Skipped Order #${orderId}: Missing coordinates.`);
                continue;
            }

            const pickup = { 
                lat: order.pickup_coordinate.latitude, 
                lng: order.pickup_coordinate.longitude 
            };
            const dropoff = { 
                lat: order.dropoff_coordinate.latitude, 
                lng: order.dropoff_coordinate.longitude 
            };
            const weight = parseFloat(order.weight);

            // 4. Call Allocation and wait for it to finish before next order
            await new Promise((resolve) => {
                allocateOrderToBestDriver(orderId, pickup, dropoff, weight, (err, result) => {
                    if (err) {
                        console.error(`  Allocation error for Order #${orderId}:`, err.message);
                    } else if (result && result.driverId) {
                        console.log(`  Order #${orderId} assigned to Driver ${result.driverId}`);
                    } else {
                        console.log(`  Order #${orderId} could not be assigned (No suitable driver available).`);
                    }
                    resolve(); 
                });
            });
        }
        console.log("   -> Pending allocation cycle finished.\n");

    } catch (err) {
        console.error("Error in retryPendingAllocations:", err);
    }
}

async function updateAllDriverRatings() {
    console.log("Starting scheduled driver rating update...");
    try {
        const driversSnapshot = await db.collection('drivers').get();
        
        for (const driverDoc of driversSnapshot.docs) {
            const driverId = driverDoc.id;
            
            const ratingsSnapshot = await db.collection('drivers').doc(driverId).collection('ratings').get();

            if (ratingsSnapshot.empty) {
                await driverDoc.ref.update({ avg_rating: 0 });
                continue;
            }

            let totalRating = 0;
            let count = 0;

            ratingsSnapshot.forEach(doc => {
                const data = doc.data();
                if (data.score) {
                    totalRating += data.score;
                    count++;
                }
            });

            const newAvg = count > 0 ? (totalRating / count) : 0;

            await driverDoc.ref.update({ 
                avg_rating: parseFloat(newAvg.toFixed(2))
            });
        }
        console.log("Driver ratings updated successfully.");
    } catch (error) {
        console.error("Error updating driver ratings:", error);
    }
}

async function recalculateAllDriverETAs() {
    console.log(`[${new Date().toLocaleTimeString()}] Starting periodic ETA update...`);
    
    try {
        const driversSnapshot = await db.collection('drivers').get();
        if (driversSnapshot.empty) return;

        const ordersSnapshot = await db.collection('orders')
            .where('status', 'in', ['assigned', 'in_progress', 'picking_up'])
            .get();
            
        const ordersMap = {};
        ordersSnapshot.forEach(doc => {
            const data = doc.data();
            if (data.pickup_coordinate && data.dropoff_coordinate) {
                ordersMap[doc.id] = {
                    P: { lat: data.pickup_coordinate.latitude, lng: data.pickup_coordinate.longitude },
                    D: { lat: data.dropoff_coordinate.latitude, lng: data.dropoff_coordinate.longitude },
                    weight: parseFloat(data.weight) || 0
                };
            }
        });

        const updates = [];

        for (const doc of driversSnapshot.docs) {
            const driver = doc.data();
            const driverId = doc.id;

            const route = (driver.expected_route || []).filter(node => node !== "");

            if (route.length === 0) continue;

            let currentLoc = { 
                lat: driver.current_lat || 22.3193, 
                lng: driver.current_lng || 114.1694 
            };

            const newTimes = [];
            let accumulatedTime = Date.now();

            let validRoute = true;
            for (const node of route) {
                const type = node.charAt(0);
                const oid = node.substring(1);
                const orderData = ordersMap[oid];

                if (!orderData) {
                    console.warn(`Driver ${driverId}: Order ${oid} data missing during update. Skipping driver.`);
                    validRoute = false;
                    break;
                }

                const targetLoc = type === 'P' ? orderData.P : orderData.D;
                
                const duration = await getTravelTime(currentLoc, targetLoc);

                accumulatedTime += (duration * 1000) + (300 * 1000);
                newTimes.push(accumulatedTime);

                currentLoc = targetLoc;
            }

            if (validRoute) {
                updates.push(
                    db.collection('drivers').doc(driverId).update({
                        expected_time: newTimes
                    })
                );
            }
        }

        if (updates.length > 0) {
            await Promise.all(updates);
            console.log(`Updated ETAs for ${updates.length} drivers.`);
        }

    } catch (err) {
        console.error("Error in recalculateAllDriverETAs:", err);
    }
}

// --- Scheduler that runs every hour ---
function scheduleNextHourlyAllocation() {
    const now = new Date();
    
    // 1. Calculate target time
    const nextHour = new Date(now);
    nextHour.setHours(now.getHours() + 1, 0, 0, 0);
    
    // 2. Calculate time to wait
    const timeToWait = nextHour.getTime() - now.getTime();

    console.log(`[Scheduler] Next Pending Allocation run scheduled for ${nextHour.toLocaleTimeString()} (in ${(timeToWait/60000).toFixed(1)} mins)`);

    // 3. Set the timer
    setTimeout(() => {
        retryPendingAllocations();
        scheduleNextHourlyAllocation();
    }, timeToWait);
}

function startSchedulers() {
    setTimeout(retryPendingAllocations, 5000);
    scheduleNextHourlyAllocation();
    setTimeout(updateAllDriverRatings, 5000);
    setTimeout(recalculateAllDriverETAs, 5000);
    setInterval(updateAllDriverRatings, 24 * 60 * 60 * 1000);
    const ms = (process.env.ETA_UPDATE_INTERVAL_SECONDS || 900) * 1000;
    setInterval(recalculateAllDriverETAs, ms);
}
module.exports = { startSchedulers };
