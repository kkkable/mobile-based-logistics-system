const express = require('express');
const cors = require('cors');
const path = require('path');
require('dotenv').config();

const routes = require('./routes');
const { startSchedulers } = require('./services/schedulerService');

const app = express();
const webApp = express();

app.use(cors());
app.use(express.json());
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

// Link all API routes
app.use('/api', routes);

//catch missing API routes
app.use('/api', (req, res) => {
  res.status(404).json({ error: 'API endpoint not found' });
});



const PORT = process.env.PORT || 8080;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
  startSchedulers();
});

// Serve the Admin Web App from public_web folder
webApp.get('/assets/dotenv', (req, res) => {
  const baseUrl = process.env.BASE_URL || 'http://localhost:8080';
  const interval = process.env.DASHBOARD_UPDATE_INTERVAL || '60';
  res.type('text/plain');
  res.send(`BASE_URL=${baseUrl}\nDASHBOARD_UPDATE_INTERVAL=${interval}\n`);
});

webApp.use(express.static(path.join(__dirname, 'public_web'), { dotfiles: 'allow' }));
webApp.use((req, res) => {
  res.sendFile(path.join(__dirname, 'public_web', 'index.html'));
});

const WEB_PORT = 3000;
webApp.listen(WEB_PORT, '0.0.0.0', () => {
  console.log(`Admin Web App running on port ${WEB_PORT}`);

});
