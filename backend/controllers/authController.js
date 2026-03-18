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
    const { username, password, role } = req.body;
    try {
      const normalizedRole = typeof role === 'string' ? role.trim().toLowerCase() : null;
      const loginTargets = {
        user: { collection: 'customers', type: 'user', idField: 'userId' },
        driver: { collection: 'drivers', type: 'driver', idField: 'driverId' },
        admin: { collection: 'admins', type: 'admin', idField: 'adminId' }
      };

      const targets = loginTargets[normalizedRole]
        ? [loginTargets[normalizedRole]]
        : [loginTargets.user, loginTargets.driver, loginTargets.admin];

      for (const target of targets) {
        const snapshot = await db.collection(target.collection)
          .where('username', '==', username)
          .limit(1)
          .get();

        if (snapshot.empty) continue;

        const doc = snapshot.docs[0];
        const account = doc.data();

        // Skip malformed records instead of crashing login flow
        if (!account || !account.password) continue;

        const match = await bcrypt.compare(password, account.password);
        if (!match) continue;

        const accountId = parseInt(doc.id, 10);
        const jwtPayload = target.type === 'admin'
          ? { id: accountId, type: target.type, admin_id: accountId }
          : { id: accountId, type: target.type };

        const token = jwt.sign(jwtPayload, JWT_SECRET, { expiresIn: '1h' });
        return res.status(200).json({
          message: 'Login successful',
          accountType: target.type,
          [target.idField]: accountId,
          token
        });
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
