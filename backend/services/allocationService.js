const { db, admin } = require('../config');
const { getTravelTime, geocodeAddress } = require('../utils');

async function allocateOrderToBestDriver(orderId, pickupCoord, dropoffCoord, weight, callback) {
    try {
        const orderDoc = await db.collection('orders').doc(String(orderId)).get();
        
        if (!pickupCoord || !dropoffCoord) {
             try {
                const newOrder = orderDoc.data();
                pickupCoord = await geocodeAddress(newOrder.pickup_location);
                dropoffCoord = await geocodeAddress(newOrder.dropoff_location);
             } catch(e) {
                 return callback(new Error("Geocoding failed during allocation"));
             }
        }

        // Fetch drivers
        const driversSnapshot = await db.collection('drivers').get();
        
        let bestDriver = null;
        let bestScore = Infinity; 
        let bestPlan = null; 

        // 1. Collect all IDs from every driver route to fetch order data
        let allOrderIds = new Set();
        driversSnapshot.docs.forEach(doc => {
            const d = doc.data();
            if (d.expected_route && d.expected_route.length > 0) {
                d.expected_route.forEach(node => {
                    if (node && node.length > 1 && node !== "") { 
                        allOrderIds.add(node.substring(1));
                    }
                });
            }
        });

        // 2.Fetch those specific orders
        const ordersMap = {};
        const allOrdersSnap = await db.collection('orders').where('status', '!=', 'finished').get();

        allOrdersSnap.forEach(d => {
            const data = d.data();
            if (data.pickup_coordinate && data.dropoff_coordinate) {
                ordersMap[d.id] = {
                    P: { lat: data.pickup_coordinate.latitude, lng: data.pickup_coordinate.longitude },
                    D: { lat: data.dropoff_coordinate.latitude, lng: data.dropoff_coordinate.longitude },
                    weight: parseFloat(data.weight) || 0
                };
            }
        });

        // 3.Add the NEW order
        const safeWeight = parseFloat(weight) || 0;
        ordersMap[orderId] = { P: pickupCoord, D: dropoffCoord, weight: safeWeight };

        console.log(`\n=== STARTING ALLOCATION FOR ORDER ${orderId} (Weight: ${safeWeight}kg) ===`);

        // Local cache for Google Maps API
        const distanceCache = {};

        async function getCachedTravelTime(origin, dest) {
            const key = `${origin.lat},${origin.lng}-${dest.lat},${dest.lng}`;
            if (distanceCache[key] !== undefined) {
                return distanceCache[key]; 
            }
            const duration = await getTravelTime(origin, dest);
            distanceCache[key] = duration; 
            return duration;
        }

        for (const doc of driversSnapshot.docs) {
            const driver = { id: parseInt(doc.id, 10), ...doc.data() };
            
            // Shift Time Filter
            const workingTimeParts = driver.working_time ? driver.working_time.split('-') : ["09:00", "18:00"];
            const [startH, startM] = workingTimeParts[0].trim().split(':').map(Number);
            const shiftStartTime = new Date();
            shiftStartTime.setHours(startH, startM, 0, 0);

            const [endH, endM] = workingTimeParts[1].trim().split(':').map(Number);
            const shiftEndTime = new Date();
            shiftEndTime.setHours(endH, endM, 0, 0);

            const currentTime = Date.now();
            
            if (currentTime < shiftStartTime.getTime() || currentTime > shiftEndTime.getTime()) {
                continue; 
            }

            console.log(`\nChecking Driver ${driver.id} (${driver.name}) | Shift: ${driver.working_time}`);

            const maxWeight = parseFloat(driver.max_weight);
            const currentRoute = (driver.expected_route || []).filter(node => node !== "");
            const currentTimes = (driver.expected_time && driver.expected_time.length > 0) ? driver.expected_time : [];
            const driverLoc = { lat: driver.current_lat || 22.3193, lng: driver.current_lng || 114.1694 };

            let currentLoad = 0;
            for (const node of currentRoute) {
                const type = node.charAt(0);
                const nodeData = ordersMap[node.substring(1)];
                if (nodeData) {
                    // If D is in the route, the item is currently on the truck OR will be picked up
                    if (type === 'D') currentLoad += parseFloat(nodeData.weight) || 0;
                    // If P is in the route, the item is NOT on the truck yet
                    if (type === 'P') currentLoad -= parseFloat(nodeData.weight) || 0;
                }
            }
            const initialTestCap = maxWeight - currentLoad;


            // --- INSERTION HEURISTIC ---
            const N = currentRoute.length;
            let bestPlanForDriver = null; 
            let minPenaltyForDriver = Infinity;

            for (let i = 0; i <= N; i++) {
                for (let j = i + 1; j <= N + 1; j++) {
                    
                    let candidateRoute = [...currentRoute];
                    candidateRoute.splice(i, 0, `P${orderId}`);
                    candidateRoute.splice(j, 0, `D${orderId}`); 

                    let validCap = true;
                    let testCap = initialTestCap;
                    let tempWeights = [initialTestCap]; 
                    
                    for (const node of candidateRoute) {
                        const type = node.charAt(0);
                        const nodeData = ordersMap[node.substring(1)];
                        
                        if (!nodeData) { validCap = false; break; }

                        const nodeWeight = parseFloat(nodeData.weight) || 0;

                        if (type === 'P') testCap -= nodeWeight;
                        else testCap += nodeWeight;

                        if (testCap > maxWeight) testCap = maxWeight;

                        if (testCap < 0) {
                            console.log(`  [Skipped] Route P@${i}, D@${j} | Reason: Overcapacity`);
                            validCap = false; 
                            break; 
                        }
                        tempWeights.push(testCap);
                    }

                    if (!validCap) continue; 

                    let validTime = true;
                    let tempTimes = [];
                    let lastLoc = driverLoc;
                    
                    let accumulatedTime = (currentTimes.length > 0) ? currentTimes[currentTimes.length - 1] : Date.now();
                    let simAccumulatedTime = Date.now();
                    
                    for (const node of candidateRoute) {
                        const type = node.charAt(0);
                        const nodeData = ordersMap[node.substring(1)];
                        const targetLoc = type === 'P' ? nodeData.P : nodeData.D;
                        
                        const duration = await getCachedTravelTime(lastLoc, targetLoc);
                        
                        simAccumulatedTime += (duration * 1000) + (300 * 1000); 
                        tempTimes.push(simAccumulatedTime);
                        lastLoc = targetLoc;
                    }
                    
                    if (simAccumulatedTime > shiftEndTime.getTime() || simAccumulatedTime < shiftStartTime.getTime()) {
                         continue; 
                    }

                    // Scoring
                    const oldEndTime = accumulatedTime;
                    const newEndTime = tempTimes[tempTimes.length - 1];
                    const penaltyTime = newEndTime - oldEndTime;
                    
                    const wTime = 1.0;
                    const wRating = 60000 * 5; 
                    const rating = driver.avg_rating || 0;
                    
                    const score = (wTime * penaltyTime) - (wRating * rating);
                    console.log(`  [Valid]   Route P@${i}, D@${j} | Penalty: ${(penaltyTime/60000).toFixed(1)}m | Score: ${score.toFixed(0)}`);
                    if (score < minPenaltyForDriver) {
                        minPenaltyForDriver = score;
                        bestPlanForDriver = {
                            route: candidateRoute,
                            weights: tempWeights,
                            times: tempTimes,
                            score: score
                        };
                    }
                }
            }

            if (bestPlanForDriver) {
                console.log(`  => Best for Driver ${driver.id}: Score ${bestPlanForDriver.score.toFixed(0)}`);
                if (bestPlanForDriver.score < bestScore) {
                    bestScore = bestPlanForDriver.score;
                    bestDriver = driver;
                    bestPlan = bestPlanForDriver;
                }
            } else {
                console.log(`  => No valid routes found for Driver ${driver.id}`);
            }
        }

        console.log(`\n=== WINNER: Driver ${bestDriver ? bestDriver.id : 'None'} ===\n`);

        if (!bestDriver) {
             return callback(null, { driverId: null, status: 'pending_no_drivers' });
        }

        // 4. Update Database
        await db.collection('drivers').doc(String(bestDriver.id)).update({
            expected_route: bestPlan.route,
            available_weight: bestPlan.weights,
            expected_time: bestPlan.times
        });

        // 5. Update Order
        let expectedDeliveryTime = null;
        const dropoffNode = `D${orderId}`;
        const dropoffIndex = bestPlan.route.indexOf(dropoffNode);
        if (dropoffIndex !== -1 && bestPlan.times[dropoffIndex]) {
            expectedDeliveryTime = admin.firestore.Timestamp.fromMillis(bestPlan.times[dropoffIndex]);
        }

        await orderDoc.ref.update({ 
            driver_id: bestDriver.id, 
            status: "in_progress",
            pickup_time: admin.firestore.FieldValue.serverTimestamp(),
            expected_delivery_time: expectedDeliveryTime 
        });
        
        callback(null, { driverId: bestDriver.id, cost: bestScore });

    } catch (err) {
        callback(err);
    }
}

module.exports = { allocateOrderToBestDriver };
