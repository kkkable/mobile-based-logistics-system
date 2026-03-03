# Logistics & Delivery Management System (FYP)

An end-to-end logistics platform featuring an intelligent driver-routing algorithm, live tracking, and a comprehensive admin dashboard.

## Apps Demo
* **Admin Dashboard (Live Web):** [Web Demo](http://20.2.65.194:3000/)
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

## How to run locally
**Backend:**
Edit the .env file:
1. API_KEY=`google map API key`
2. PORT=`8080` (Default)
3. FIREBASE_KEY_PATH=`firebase key` (firestore)
4. AZURE_STORAGE_CONNECTION_STRING=`Azure blob storage` (it is optional or it will store in local "uploads" folder in backend)
5. ETA_UPDATE_INTERVAL_SECONDS=`900` (default)
6. JWT_SECRET=  (Optional)

Start Backend:
1. cd `backend`
2. `npm install`
3. `node server.js`

**Flutter Apps (Android):**
Edit the .env file:
1. BASE_URL: `http://{backend IP}:{Port}` or `http://10.0.2.2:{Port}`

Start App:
1. cd `app`(customer app), `driver_app`
2. `flutter pub get`
3. `flutter run`

**Flutter Apps (Web):**
1. Edit the dotenv file in assets folder:
2. BASE_URL: `http://{backend IP}:{Port}` or `http://localhost:{Port}`
3. DASHBOARD_UPDATE_INTERVAL=`60` (default)

Start App:
1. cd `admin_web_app`
2. `flutter pub get`
3. `flutter run`

or

1. cd `admin_web_app`
2. `flutter pub get`
3. `flutter build web`
4. Create public_web folder in backend
5. Copy all files in `admin_web_app\build\web` into `backend\public_web`
6. Web server start automatically when the server start

**Create first account:**
1. edit Admin Creator Script.js with firestore key location, username, password, name
2. run the script to create first admin account
3. Use the edit database feature in admin web app to create driver or customer
