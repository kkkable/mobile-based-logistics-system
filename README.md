# Logistics & Delivery Management System (FYP)

An end-to-end logistics platform featuring an intelligent driver-routing algorithm, live tracking, and a comprehensive admin dashboard.

## Apps Demo
* **Admin Dashboard (Live Web):** [http://20.2.65.194:3000/]
* **Customer App (Android):** [Download CustomerApp.apk](https://github.com/kkkable/mobile-based-logistics-system/releases/download/v1/CustomerApp.apk)
* **Driver App (Android):** [Download DriverApp.apk](https://github.com/kkkable/mobile-based-logistics-system/releases/download/v1/DriverApp.apk)

### Test Account
* **Admin:** username: `a1` / password: `1`
* **Driver:** username: `d4` / password: `4`
* **Customer:** username: `c5`/ password: `5`

## System Architecture
1.  **Backend:** Node.js, Firebase Firestore (Hosted on Azure Linux VM)
2.  **Admin Portal:** Flutter Web
3.  **Customer App:** Flutter Mobile (Android)
4.  **Driver App:** Flutter Mobile (Android)

## Key Features
* **Smart Routing:** Uses Google Maps API to calculate the most efficient route for drivers.
* **Live Tracking:** Customers and Admins can see the driver's live GPS location on a map.
* **Order Management:** Customers can create orders, and drivers can upload photo proof of delivery.
* **Admin Control:** View real-time analytics, edit database records, and monitor all drivers concurrently.

## How to run locally (For Developers)
**Backend:**
Edit the .env file
1. cd `backend`
2. `npm install`
3. `node server.js`

**Flutter Apps:**
1. cd `customer_app`, `driver_app`, or `admin_app`
2. `flutter pub get`
3. `flutter run`
