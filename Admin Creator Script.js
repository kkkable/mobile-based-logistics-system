const admin = require('firebase-admin');
const bcrypt = require('bcrypt');

// --- CONFIGURATION ---
// REPLACE with your actual service account path
const serviceAccount = require(' ');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

// --- EDIT THESE VALUES TO CREATE A NEW ADMIN ---
const NEW_ADMIN = {
    username: " ",
    password: " ",
    name: "Administrator"
};

async function getNextSequenceValue(sequenceName) {
    const counterRef = db.collection('counters').doc(sequenceName);
    return db.runTransaction(async (transaction) => {
        const counterDoc = await transaction.get(counterRef);
        let newCount;
        if (!counterDoc.exists) {
	    console.log(`'counters' collection or '${sequenceName}' document not found. Creating them now...`);
            newCount = 1;
        } else {
            newCount = counterDoc.data().count + 1;
        }
        transaction.set(counterRef, { count: newCount });
        return newCount;
    });
}

async function createAdmin() {
    try {
        console.log(`Creating Admin: ${NEW_ADMIN.username}...`);

        const snapshot = await db.collection('admins').where('username', '==', NEW_ADMIN.username).get();
        if (!snapshot.empty) {
            console.error('Error: Username already exists.');
            process.exit(1);
        }

        const newId = await getNextSequenceValue('admin_id');

        const hashedPassword = await bcrypt.hash(NEW_ADMIN.password, 10);

        await db.collection('admins').doc(String(newId)).set({
            username: NEW_ADMIN.username,
            password: hashedPassword,
            name: NEW_ADMIN.name,
            create_time: admin.firestore.FieldValue.serverTimestamp()
        });

        console.log(`Successfully created Admin (ID: ${newId})`);
        process.exit(0);
    } catch (error) {
        console.error('Error creating admin:', error);
        process.exit(1);
    }
}

createAdmin();