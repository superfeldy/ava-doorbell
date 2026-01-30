# AVA Doorbell System - Complete Setup Instructions

## 🎯 What This Does

Connects your **IC Realtime Dinger Pro 2** doorbell to your **AVA Remote** device, providing:
- Live video streaming on AVA Remote
- Push notifications when doorbell rings
- Web-based admin panel to configure everything

---

## 📋 Requirements

### Hardware
- ✅ Raspberry Pi 3B+ (or newer) with power supply
- ✅ 16GB+ microSD card
- ✅ Ethernet cable (recommended) or WiFi
- ✅ IC Realtime Dinger Pro 2 doorbell (already installed)
- ✅ AVA Remote device
- ✅ Computer for initial setup

### Information Needed
Before starting, find these values:

| Item | Where to Find | Your Value |
|------|---------------|------------|
| Doorbell IP | Router admin page or IC View+ app | __________ |
| Doorbell Password | Set during doorbell setup | __________ |
| NVR IP (optional) | Router admin page | __________ |

---

## 🚀 Step 1: Prepare Raspberry Pi

### 1.1 Flash the SD Card

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Insert SD card into your computer
3. Open Raspberry Pi Imager
4. Choose:
   - **OS**: Raspberry Pi OS Lite (64-bit)
   - **Storage**: Your SD card
5. Click ⚙️ **Settings** and configure:
   - ✅ Hostname: `ava-doorbell`
   - ✅ Enable SSH (password authentication)
   - ✅ Username: `pi`
   - ✅ Password: (choose something secure)
   - ✅ WiFi (if not using Ethernet)
   - ✅ Timezone
6. Click **Save**, then **Write**

### 1.2 First Boot

1. Insert SD card into Raspberry Pi
2. Connect Ethernet cable (recommended)
3. Connect power
4. Wait 2-3 minutes

### 1.3 Find Your Pi's IP Address

**Option A**: Check your router's admin page (usually 192.168.1.1)

**Option B**: From your computer terminal:
```bash
ping ava-doorbell.local
```

**Option C**: Use a network scanner app

---

## 🔧 Step 2: Run the Installer

### 2.1 Connect via SSH

From your computer's terminal:
```bash
ssh pi@YOUR_PI_IP
```
Enter your password when prompted.

### 2.2 Download and Run Setup Script

Copy and paste this entire command:
```bash
curl -fsSL https://raw.githubusercontent.com/yourusername/ava-doorbell/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

**Or, if you have the files locally:**
```bash
chmod +x setup.sh
./setup.sh
```

### 2.3 Wait for Installation

The script will:
1. Update the system (~2-5 minutes)
2. Install Docker (~2-3 minutes)
3. Create configuration files
4. Build and start services (~5-10 minutes)

**Total time: ~15-20 minutes**

---

## ⚙️ Step 3: Configure via Admin Panel

### 3.1 Open Admin Panel

On any device (phone, computer), open a browser and go to:
```
http://YOUR_PI_IP:8888
```

You'll see the AVA Doorbell Admin Panel.

### 3.2 Enter Your Camera Settings

1. **Doorbell IP Address**: Enter your Dinger Pro 2's IP
2. **Doorbell Username**: Usually `admin`
3. **Doorbell Password**: Your doorbell's password
4. **NVR IP** (optional): If you have additional cameras on an NVR

### 3.3 Save and Apply

1. Click **Save Configuration**
2. Click **Restart All** to apply changes
3. Wait 30 seconds

### 3.4 Test the Setup

1. Click **Test Stream** - should show "Streams found"
2. Click **Test Doorbell Ring** - simulates a doorbell press
3. Click the **go2rtc Interface** link to see live video

---

## 📱 Step 4: Build the Android App

### 4.1 Install Android Studio

Download from: https://developer.android.com/studio

### 4.2 Open the Project

1. Extract the `doorbell-system.zip` file
2. Open Android Studio
3. File → Open → Select the `android-app` folder
4. Wait for Gradle sync to complete

### 4.3 Build the APK

1. Menu: **Build → Build Bundle(s) / APK(s) → Build APK(s)**
2. Wait for build to complete
3. Click **locate** to find the APK

APK location: `android-app/app/build/outputs/apk/debug/app-debug.apk`

---

## 📲 Step 5: Install on AVA Remote

### 5.1 Enable Unknown Sources

On AVA Remote:
1. Go to **Settings**
2. Find **Security** or **Privacy**
3. Enable **Install unknown apps**

### 5.2 Transfer and Install APK

**Option A: USB Drive**
1. Copy APK to USB drive
2. Plug into AVA Remote
3. Open file manager, find and install APK

**Option B: ADB (if you have it)**
```bash
adb connect AVA_REMOTE_IP:5555
adb install app-debug.apk
```

**Option C: Local Web Server**
1. On your computer: `python3 -m http.server 8000`
2. On AVA Remote browser: `http://YOUR_COMPUTER_IP:8000/app-debug.apk`
3. Download and install

### 5.3 Configure the App

1. Open **AVA Doorbell** app
2. Tap ⚙️ **Settings**
3. Enter your Raspberry Pi's IP address
4. Tap **Test** - should show "Connected!"
5. Tap **Save**
6. Return to main screen - video should load!

---

## 🔔 Step 6: Configure NVR Webhooks

For doorbell notifications to work, configure your IC Realtime NVR:

### 6.1 Access NVR Web Interface

Open browser: `http://YOUR_NVR_IP`

### 6.2 Add Webhook

Find **Settings → Network → Alarm Server** (location varies by model)

Set:
- **URL**: `http://YOUR_PI_IP:8080/webhook/alarm`
- **Method**: POST

### 6.3 Enable Doorbell Events

1. Go to channel settings for your doorbell
2. Enable **Doorbell** or **Button Press** alarm
3. Link to HTTP notification

---

## ✅ Verification Checklist

Test each component:

| Test | How | Expected Result |
|------|-----|-----------------|
| Admin Panel | Browser: `http://PI_IP:8888` | Web interface loads |
| go2rtc | Browser: `http://PI_IP:1984` | Shows streams |
| Live Video | Admin Panel → go2rtc link | Video plays |
| Test Ring | Admin Panel → Test Doorbell | Notification appears |
| App Video | Open AVA Doorbell app | Video loads |
| Real Doorbell | Press doorbell button | Notification on AVA Remote |

---

## 🔧 Troubleshooting

### Video Not Loading

1. **Check go2rtc logs**:
   ```bash
   cd ~/ava-doorbell
   docker-compose logs go2rtc
   ```

2. **Verify RTSP URL** - In Admin Panel, your doorbell should use:
   ```
   rtsp://admin:PASSWORD@DOORBELL_IP:554/cam/realmonitor?channel=1&subtype=0
   ```

3. **Test directly with VLC**:
   ```
   vlc rtsp://admin:PASSWORD@DOORBELL_IP:554/cam/realmonitor?channel=1&subtype=0
   ```

### No Doorbell Notifications

1. **Test webhook manually**:
   ```bash
   curl http://PI_IP:8080/test/ring
   ```

2. **Check NVR webhook settings** - URL must be exactly:
   ```
   http://PI_IP:8080/webhook/alarm
   ```

3. **Check webhook-relay logs**:
   ```bash
   docker-compose logs webhook-relay
   ```

### App Won't Connect

1. Verify Pi IP is correct in app settings
2. Ensure AVA Remote is on same network
3. Check all services are running:
   ```bash
   docker-compose ps
   ```

---

## 📚 Quick Reference

### URLs

| Service | URL |
|---------|-----|
| Admin Panel | `http://PI_IP:8888` |
| go2rtc Interface | `http://PI_IP:1984` |
| View Doorbell Stream | `http://PI_IP:1984/stream.html?src=doorbell` |
| Webhook Health | `http://PI_IP:8080/health` |
| Test Doorbell | `http://PI_IP:8080/test/ring` |
| NVR Webhook URL | `http://PI_IP:8080/webhook/alarm` |

### Commands

```bash
# SSH to Pi
ssh pi@PI_IP

# Go to project folder
cd ~/ava-doorbell

# View all logs
docker-compose logs -f

# View specific service logs
docker-compose logs -f go2rtc
docker-compose logs -f webhook-relay

# Restart all services
docker-compose restart

# Stop all services
docker-compose down

# Start all services
docker-compose up -d

# Rebuild after changes
docker-compose up -d --build
```

### Android App Settings

| Setting | Default Value |
|---------|---------------|
| Server IP | (your Pi's IP) |
| RTSP Port | 8554 |
| MQTT Port | 1883 |

---

## 🎉 Done!

Your AVA Doorbell system is now set up! When someone presses the doorbell:

1. 🔔 Your AVA Remote shows a notification
2. 📱 The app displays a doorbell alert
3. 📹 Live video streams from the doorbell

Enjoy your smart doorbell system!
