const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const { db, admin } = require('../config');
const { getNextSequenceValue } = require('../utils');
const { JWT_SECRET } = require('../middlewares');

exports.register = async (req, res) => { 
    const { name, email, phone, address, username, password } = req.body;
    if (!name || !email || !phone || !address || !username || !password) {
        return res.status(400).json({ message: 'Missing required fields' });
    }
    try {
        const usersRef = db.collection('customers');
        const snapshot = await usersRef.where('username', '==', username).get();
        if (!snapshot.empty) {
        return res.status(400).json({ message: 'Username exists' });
        }

        const newUserId = await getNextSequenceValue('customer_id');
        const hashedPassword = await bcrypt.hash(password, 10);

        await usersRef.doc(String(newUserId)).set({
        name,
        email,
        phone,
        address,
        username,
        password: hashedPassword,
        creation_time: admin.firestore.FieldValue.serverTimestamp()
        });

        res.status(200).json({ message: 'Registration successful', userId: newUserId });
    } catch (err) {
        console.error("Registration Error:", err);
        res.status(500).json({ message: 'Server error' });
    }    
};

exports.login = async (req, res) => {
    const { username, password } = req.body;
    try {
      // Check Customers collection
      const userSnapshot = await db.collection('customers').where('username', '==', username).limit(1).get();
      if (!userSnapshot.empty) {
        const userDoc = userSnapshot.docs[0];
        const user = userDoc.data();
        const match = await bcrypt.compare(password, user.password);
        if (match) {
          const userId = parseInt(userDoc.id, 10);
          const token = jwt.sign({ id: userId, type: 'user' }, JWT_SECRET, { expiresIn: '1h' });
          return res.status(200).json({ message: 'Login successful', userId: userId, token });
        }
      }
  
      // Check Drivers collection
      const driverSnapshot = await db.collection('drivers').where('username', '==', username).limit(1).get();
      if (!driverSnapshot.empty) {
        const driverDoc = driverSnapshot.docs[0];
        const driver = driverDoc.data();
        const match = await bcrypt.compare(password, driver.password);
        if (match) {
          const driverId = parseInt(driverDoc.id, 10);
          const token = jwt.sign({ id: driverId, type: 'driver' }, JWT_SECRET, { expiresIn: '1h' });
          return res.status(200).json({ message: 'Login successful', driverId: driverId, token });
        }
      }

      // Check Admins collection
      const adminSnapshot = await db.collection('admins').where('username', '==', username).limit(1).get();
      if (!adminSnapshot.empty) {
        const adminDoc = adminSnapshot.docs[0];
        const adminData = adminDoc.data();
        const match = await bcrypt.compare(password, adminData.password);
        if (match) {
            const adminId = parseInt(adminDoc.id, 10);
            const token = jwt.sign({ id: adminId, type: 'admin', admin_id: adminId }, JWT_SECRET, { expiresIn: '1h' });
            return res.status(200).json({ message: 'Login successful', adminId: adminId, token });
        }
      }
  
      return res.status(401).json({ message: 'Invalid credentials' });
  
    } catch (err) {
      console.error("Login Error:", err);
      res.status(500).json({ message: 'Server error' });
    }    
};

exports.getUser = async (req, res) => {
    const userId = req.params.id; 
    if (String(req.user.id) !== userId) return res.status(403).json({ error: 'Not authorized' });
    
    try {
        const doc = await db.collection('customers').doc(userId).get();
        if (!doc.exists) {
            return res.status(404).json({ error: 'User not found' });
        }
        const { password, ...userData } = doc.data();
        res.json({ user_id: parseInt(doc.id, 10), ...userData });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
};
