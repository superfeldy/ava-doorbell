# 🔔 AVA Doorbell System - Complete Setup Guide

## What This Does

This system connects your **IC Realtime Dinger Pro 2** doorbell to your **AVA Remote**, giving you:
- 📹 Live video on AVA Remote
- 🔔 Push notifications when doorbell rings
- ⚙️ Easy web-based configuration

---

## 📋 Before You Start

### You'll Need:
- Raspberry Pi 3B+ (or newer) with power supply
- 16GB+ microSD card
- Network cable or WiFi
- IC Realtime Dinger Pro 2 (already installed)
- AVA Remote device

### Gather This Information:

| Item | Where to Find It | Write It Here |
|------|------------------|---------------|
| Doorbell IP Address | Router admin page or IC View+ app | _____________ |
| Doorbell Password | Set during doorbell setup | _____________ |
| NVR IP (if applicable) | Router admin page | _____________ |

---

## 🚀 STEP 1: Prepare the Raspberry Pi (10 minutes)

### 1.1 Download Raspberry Pi Imager
Go to: **https://www.raspberrypi.com/software/**

### 1.2 Flash the SD Card

1. Insert SD card into your computer
2. Open Raspberry Pi Imager
3. Click **CHOOSE OS** → **Raspberry Pi OS (other)** → **Raspberry Pi OS Lite (64-bit)**
4. Click **CHOOSE STORAGE** → Select your SD card
5. Click the **⚙️ gear icon** (bottom right)
6. Configure these settings:

   | Setting | Value |
   |---------|-------|
   | ✅ Set hostname | `ava-doorbell` |
   | ✅ Enable SSH | Use password authentication |
   | ✅ Set username | `pi` |
   | ✅ Set password | (choose something secure) |
   | ✅ Configure WiFi | (if not using ethernet) |
   | ✅ Set locale settings | Your timezone |

7. Click **SAVE**
8. Click **WRITE** and wait for it to complete

### 1.3 First Boot

1. Insert the SD card into your Raspberry Pi
2. Connect an ethernet cable (recommended) or use WiFi
3. Connect the power supply
4. Wait 2-3 minutes for first boot

---

## 🔧 STEP 2: Run the Installer (15 minutes)

### 2.1 Find Your Pi's IP Address

**Option A - From your router:**
Open your router's admin page (usually `192.168.1.1`) and look for a device named `ava-doorbell`

**Option B - From your computer:**
```
ping ava-doorbell.local
```

### 2.2 Connect via SSH

Open Terminal (Mac/Linux) or PowerShell (Windows) and run:
```bash
ssh pi@YOUR_PI_IP_ADDRESS
```
Enter your password when prompted.

### 2.3 Download and Run the Installer

Copy and paste this command:
```bash
curl -fsSL https://example.com/install.sh -o install.sh && chmod +x install.sh && ./install.sh
```

**Or if you have the install.sh file:**
```bash
chmod +x install.sh
./install.sh
```

### 2.4 Wait for Installation

The script will automatically:
- ✅ Update the system
- ✅ Install Docker
- ✅ Create all configuration files
- ✅ Build and start all services
- ✅ Launch the Admin Panel

**This takes about 10-15 minutes.** You'll see progress updates.

---

## ⚙️ STEP 3: Configure via Admin Panel (5 minutes)

### 3.1 Open the Admin Panel

On any device (phone, tablet, computer), open a web browser and go to:

```
http://YOUR_PI_IP:8888
```

For example: `http://192.168.1.100:8888`

### 3.2 Configure Your Doorbell

You'll see the Admin Panel with these fields:

| Field | What to Enter |
|-------|---------------|
| **Doorbell IP Address** | Your Dinger Pro 2's IP (e.g., `192.168.1.50`) |
| **Doorbell Username** | Usually `admin` |
| **Doorbell Password** | Your doorbell's password |

### 3.3 Save and Apply

1. Click **💾 Save Configuration**
2. Click **🔄 Restart Services**
3. Wait about 30 seconds

### 3.4 Test Your Setup

1. Click **🔔 Test Doorbell** - You should see "Test ring sent!"
2. Click **📡 Test Streams** - Should show "Streams: doorbell, doorbell_sub"
3. Click the **go2rtc Web Interface** link to see live video

---

## 📱 STEP 4: Build the Android App (10 minutes)

### 4.1 Install Android Studio

Download from: **https://developer.android.com/studio**

### 4.2 Open the Project

1. Extract the downloaded zip file
2. Open Android Studio
3. Click **File → Open**
4. Select the `android-app` folder
5. Wait for Gradle sync to complete (first time takes a few minutes)

### 4.3 Build the APK

1. In the menu: **Build → Build Bundle(s) / APK(s) → Build APK(s)**
2. Wait for the build to complete
3. Click **locate** in the popup

The APK is at: `app/build/outputs/apk/debug/app-debug.apk`

---

## 📲 STEP 5: Install on AVA Remote (5 minutes)

### 5.1 Enable Unknown Sources

On your AVA Remote:
1. Go to **Settings**
2. Find **Security** or **Privacy**
3. Enable **Install from unknown sources**

### 5.2 Transfer the APK

**Option A: USB Drive**
1. Copy `app-debug.apk` to a USB drive
2. Plug it into your AVA Remote
3. Use a file manager to find and install it

**Option B: ADB (if you have it set up)**
```bash
adb connect AVA_REMOTE_IP:5555
adb install app-debug.apk
```

### 5.3 Configure the App

1. Open the **AVA Doorbell** app
2. Tap the **⚙️ Settings** button
3. Enter your Raspberry Pi's IP address
4. Tap **Test** - should show "Connected!"
5. Tap **Save**
6. Return to main screen - video should start playing!

---

## 🔔 STEP 6: Configure NVR Webhooks (5 minutes)

For doorbell notifications to work, your NVR needs to notify the Raspberry Pi.

### 6.1 Open Your NVR's Web Interface

In a browser, go to: `http://YOUR_NVR_IP`

### 6.2 Find Alarm/Webhook Settings

Look for one of these (location varies by model):
- Settings → Network → Alarm Server
- Settings → Event → HTTP Notification
- Setup → Network → Alarm Center

### 6.3 Add the Webhook

Configure with these settings:

| Setting | Value |
|---------|-------|
| Enable | ✅ Yes |
| URL | `http://YOUR_PI_IP:8080/webhook/alarm` |
| Method | POST |

### 6.4 Enable Doorbell Alarm

1. Find channel settings for your doorbell camera
2. Enable **Doorbell** or **Button Press** alarm
3. Set it to trigger the HTTP notification

---

## ✅ Testing Checklist

| Test | How to Test | Expected Result |
|------|-------------|-----------------|
| Admin Panel | Browser: `http://PI_IP:8888` | Web interface loads |
| Live Video | Admin Panel → go2rtc link | Video plays |
| Test Ring | Admin Panel → Test Doorbell | "Test ring sent!" |
| App Video | Open AVA Doorbell app | Video loads |
| Real Test | Press actual doorbell | Notification on AVA Remote! |

---

## 🔧 Troubleshooting

### "Connection failed" in the app

1. **Check the IP address** - Make sure you entered the Pi's IP correctly in Settings
2. **Check services are running** - In Admin Panel, all services should show "running"
3. **Restart services** - Click "Restart Services" in Admin Panel

### Video not loading

1. **Check your doorbell credentials** - Double-check IP and password in Admin Panel
2. **Test directly** - Try opening this URL in VLC:
   ```
   rtsp://admin:PASSWORD@DOORBELL_IP:554/cam/realmonitor?channel=1&subtype=0
   ```
3. **Check go2rtc logs** - Click "View Logs" in Admin Panel

### Not receiving doorbell notifications

1. **Test manually** - Click "Test Doorbell" in Admin Panel
2. **Check NVR webhook** - Make sure URL is exactly: `http://PI_IP:8080/webhook/alarm`
3. **Check webhook logs** - SSH to Pi and run:
   ```bash
   cd ~/ava-doorbell && sudo docker-compose logs webhook
   ```

---

## 📚 Quick Reference

### URLs

| Service | URL |
|---------|-----|
| **Admin Panel** | `http://PI_IP:8888` |
| **go2rtc Interface** | `http://PI_IP:1984` |
| **Live Stream** | `http://PI_IP:1984/stream.html?src=doorbell` |
| **Test Ring** | `http://PI_IP:8080/test/ring` |
| **NVR Webhook** | `http://PI_IP:8080/webhook/alarm` |

### Commands (run from SSH)

```bash
# Go to project folder
cd ~/ava-doorbell

# View all logs
sudo docker-compose logs -f

# Restart all services
sudo docker-compose restart

# Stop everything
sudo docker-compose down

# Start everything
sudo docker-compose up -d
```

### Android App Settings

| Setting | Value |
|---------|-------|
| Server IP | Your Raspberry Pi's IP |
| RTSP Port | 8554 |
| MQTT Port | 1883 |

---

## 🎉 You're Done!

When someone presses your doorbell:
1. 🔔 Your AVA Remote shows a notification
2. 📱 The app displays an alert overlay
3. 📹 You see live video from the doorbell

Enjoy your smart doorbell system!
