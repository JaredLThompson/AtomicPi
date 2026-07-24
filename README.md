# Atomic Pi GPIO Reference (Kernel 6.x)

## Overview

The Atomic Pi uses an Intel Cherry Trail Z8350 SoC with four GPIO controllers exposed via the `INT33FF` pinctrl driver. On kernel 6.x, these are enumerated as:

| gpiochip | Controller | Community | Lines |
|----------|-----------|-----------|-------|
| gpiochip0 | INT33FF:00 | Southwest | 98 |
| gpiochip1 | INT33FF:01 | North | 73 |
| gpiochip2 | INT33FF:02 | East | 27 |
| gpiochip3 | INT33FF:03 | Southeast | 86 |

> **Note:** The original AAEON documentation (2019) refers to gpiochip3 for the East community. On kernel 6.x the chip numbering has shifted — the East community is now **gpiochip2**. The legacy sysfs GPIO numbers remain the same.

## On-Board LEDs

Both user LEDs are **active-low** (drive to 0 to turn ON, 1 to turn OFF).

| Label | Color | gpiochip | Line | Schematic Name | Legacy sysfs GPIO |
|-------|-------|----------|------|----------------|-------------------|
| GPIO1 | Green | gpiochip2 | 18 | MF_ISH_GPIO_1 | 332 |
| GPIO2 | Yellow | gpiochip2 | 24 | MF_ISH_GPIO_2 | 338 |

### Quick Commands

```bash
# Green LED on/off
sudo gpioset gpiochip2 18=0    # ON
sudo gpioset gpiochip2 18=1    # OFF

# Yellow LED on/off
sudo gpioset gpiochip2 24=0    # ON
sudo gpioset gpiochip2 24=1    # OFF

# Both on
sudo gpioset gpiochip2 18=0 24=0

# Blink test script
sudo ./gpio-led-test.sh
```

## 26-Pin Header GPIO Pins

These are the user-accessible GPIO pins on the 26-pin connector (active-high, accent3.3V logic):

| Schematic Name | gpiochip | Line | Legacy sysfs | 26-Pin Header | Enchilada Board |
|----------------|----------|------|--------------|---------------|-----------------|
| ISH_GPIO_0 | gpiochip2 | 21 | 335 | Pin 24 | Pin 9 |
| ISH_GPIO_1 | gpiochip2 | 18 | 332 | Pin 25 | Pin 10 |
| ISH_GPIO_2 | gpiochip2 | 24 | 338 | Pin 26 | Pin 11 |
| ISH_GPIO_3 | gpiochip2 | 15 | 329 | Pin 18 | Pin 3 |
| ISH_GPIO_4 | gpiochip2 | 22 | 336 | Pin 19 | Pin 4 |
| ISH_GPIO_7 | gpiochip2 | 16 | 330 | Pin 20 | Pin 5 |

## Other Peripherals

### North Community (gpiochip1, base = 341)

| Schematic Name | Line | Legacy sysfs | Function |
|----------------|------|--------------|----------|
| AU_MIC_SEL | 0 | 341 | XMOS audio mic loopback selector |
| GPIO_DFX_5 | 4 | 345 | WiFi enable ⚠️ **DO NOT TOGGLE** |
| GPIO_DFX_4 | 5 | 346 | Volume Down (3-pin header) |
| GPIO_DFX_2 | 7 | 348 | Volume Up (3-pin header) |
| XMOS_RESET | 8 | 349 | XMOS audio reset (active-low) |
| GPIO_SUS3 | 17 | 358 | BNO055 interrupt (active-low) |
| GPIO_SUS6 | 25 | 366 | BNO055 reset (active-low) |

### Southwest Community (gpiochip0, base = 414)

| Schematic Name | Line | Legacy sysfs | Function |
|----------------|------|--------------|----------|
| I2C2_3P3_SDA | 62 | 476 | BNO055 I2C SDA |
| I2C2_3P3_SCL | 66 | 480 | BNO055 I2C SCL |

## Dangerous Lines

**Do NOT toggle these — they will lock up the system:**

| gpiochip | Line | Reason |
|----------|------|--------|
| gpiochip1 | 4 | WiFi enable / critical SoC function |

## Setup for Non-Root GPIO Access

```bash
# Create gpio group and add user
sudo groupadd gpio
sudo usermod -aG gpio $USER

# Create udev rule
sudo tee /etc/udev/rules.d/99-gpio.rules << 'EOF'
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
SUBSYSTEM=="gpio", KERNEL=="gpio*", GROUP="gpio", MODE="0660"
EOF

# Reload rules
sudo udevadm control --reload-rules
sudo udevadm trigger

# Log out and back in for group membership to take effect
```

## Audio (XMOS Mayfield Audio)

The Atomic Pi does **not** use the Cherry Trail SoC's built-in audio codec. Instead, it has an **XMOS USB audio processor** ("Mayfield Audio") connected internally via USB, driving a TI Class-D stereo amplifier.

The SOF driver error in dmesg (`no matching ASoC machine driver found`) is expected and harmless — the SoC audio DSP is unused.

### Audio Devices

| Card | Device | Type | Notes |
|------|--------|------|-------|
| 0 | Intel HDMI/DP LPE Audio | HDMI | Works out of the box |
| 1 | XMOS Mayfield Audio | USB Audio | Requires GPIO reset at boot |

### Enabling XMOS Audio

The XMOS chip must be reset via GPIO after every boot before it appears as a USB audio device:

```bash
# Reset XMOS (gpiochip1 line 8, active-low reset)
sudo gpioset gpiochip1 8=0 & PID=$!; sleep 0.1; kill $PID; wait $PID 2>/dev/null
sudo gpioset gpiochip1 8=1 & PID=$!; sleep 0.5; kill $PID; wait $PID 2>/dev/null

# Verify it appeared
aplay -l
# Should show: card 1: Audio_1 [Mayfield Audio], device 0: USB Audio [USB Audio]
```

### Microphone Selector

The XMOS has a mic input mux controlled by GPIO:

```bash
# Select external microphone (gpiochip1 line 0 = LOW)
sudo gpioset gpiochip1 0=0 & PID=$!; sleep 0.1; kill $PID; wait $PID 2>/dev/null

# Select internal/loopback (gpiochip1 line 0 = HIGH)
sudo gpioset gpiochip1 0=1 & PID=$!; sleep 0.1; kill $PID; wait $PID 2>/dev/null
```

### Testing Playback

```bash
# Test XMOS output (speakers/amp)
speaker-test -c 2 -D plughw:1,0

# Test HDMI output
speaker-test -c 2 -D plughw:0,0

# Play a WAV file via XMOS
aplay -D plughw:1,0 /usr/share/sounds/alsa/Front_Center.wav
```

### Permissions

Your user must be in the `audio` group:

```bash
sudo usermod -aG audio $USER
# Log out and back in
```

### Auto-Reset at Boot (systemd service)

Create `/etc/systemd/system/xmos-audio-reset.service`:

```ini
[Unit]
Description=Reset XMOS Audio Processor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'gpioset gpiochip1 8=0 & PID=$$!; sleep 0.1; kill $$PID; wait $$PID 2>/dev/null; gpioset gpiochip1 8=1 & PID=$$!; sleep 0.5; kill $$PID; wait $$PID 2>/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl enable xmos-audio-reset.service
sudo systemctl start xmos-audio-reset.service
```

### Silencing the SOF Error (Optional)

To suppress the harmless SOF probe error in dmesg:

```bash
echo "blacklist snd_sof_acpi_intel_byt" | sudo tee /etc/modprobe.d/blacklist-sof-byt.conf
sudo update-initramfs -u
```

## BNO055 Absolute Orientation Sensor

The Atomic Pi has a built-in **Bosch BNO055** 9-axis absolute orientation sensor (accelerometer + gyroscope + magnetometer) connected via a GPIO-based I2C bus (bus 50, address 0x28).

The `i2c-gpio-custom` kernel module creates bus 50 using GPIO lines 574 (SDA) and 578 (SCL) — these map to gpiochip0 lines 62/66 in the Southwest community.

### Verifying the Sensor

```bash
# Check if the I2C bus and device are present
sudo i2cdetect -y 50
# Should show device at address 0x28

# Check dmesg for confirmation
dmesg | grep bno055
# Should show: i2c i2c-50: new_device: Instantiated device bno055 at 0x28
```

### GPIO Lines for BNO055

| Function | gpiochip | Line | Legacy sysfs | Notes |
|----------|----------|------|--------------|-------|
| I2C SDA | gpiochip0 | 62 | 476 | Bus 50 data |
| I2C SCL | gpiochip0 | 66 | 480 | Bus 50 clock |
| Interrupt | gpiochip1 | 17 | 358 | Active-low, optional |
| Reset | gpiochip1 | 25 | 366 | Active-low, optional |

### Reading through Linux IIO

The Linux BNO055 driver owns I²C bus 50. Applications and agent-created tools
must read the corresponding IIO sysfs device rather than opening `/dev/i2c-50`
or creating a second Adafruit/CircuitPython driver.

The IIO device number is not guaranteed to remain `device0`, so locate it by
name:

```bash
for device in /sys/bus/iio/devices/iio:device*; do
    if [[ "$(cat "$device/name" 2>/dev/null)" == "bno055" ]]; then
        echo "BNO055 IIO device: $device"
        cat "$device/in_rot_yaw_raw"
        cat "$device/in_rot_pitch_raw"
        cat "$device/in_rot_roll_raw"
    fi
done
```

In the agent, prefer the built-in `read_orientation`, `read_imu_full`, and
`detect_motion` tools. Dynamic tools importing `board`, `busio`,
`adafruit_bno055`, or `Adafruit_BNO055` are rejected.

### Calibration

The BNO055 requires calibration for accurate readings. The Linux IIO
`*_calibration_auto_status` attributes use `0` when autocalibration is not
enabled and `1` through `5` for increasing calibration quality. This differs
from the 0–3 representation used by some direct BNO055 libraries. For best
results:

1. **Gyroscope**: Keep the sensor still for a few seconds
2. **Magnetometer**: Move the sensor in a figure-8 pattern
3. **Accelerometer**: Place the sensor in 6 different stable positions
4. **System**: Reaches the highest IIO status when the component sensors are calibrated

### Resetting the BNO055 (if needed)

```bash
# Hardware reset via GPIO (active-low)
sudo gpioset gpiochip1 25=0 & PID=$!; sleep 0.1; kill $PID; wait $PID 2>/dev/null
sudo gpioset gpiochip1 25=1 & PID=$!; sleep 0.5; kill $PID; wait $PID 2>/dev/null
```

### Monitoring Interrupts

The BNO055 can generate interrupts on gpiochip1 line 17 (active-low):

```bash
# Watch for interrupt events
sudo gpiomon --falling-edge gpiochip1 17
```

## Tools

- `gpiodetect` — list GPIO controllers
- `gpioinfo` — show all lines and their current state
- `gpioset` — set output value (holds line until process exits)
- `gpioget` — read input value
- `gpiomon` — monitor line for events/interrupts

Install with: `sudo apt install gpiod`

## AI Agent (Strands + Bedrock)

The Atomic Pi runs a Strands Agents SDK-based AI controller powered by Amazon Bedrock (Claude). The agent can control all hardware via natural language.

### Setup

```bash
# Create virtual environment
python3 -m venv ~/atomicpi-agent
source ~/atomicpi-agent/bin/activate

# Install Strands
pip install strands-agents strands-agents-tools

# Run interactively as the hardware-enabled user
/home/thjared/atomicpi-agent/bin/python3 ~/atomicpi_agent.py
```

### Available Tools

| Tool | Description |
|------|-------------|
| `set_led` | Turn green/yellow LED on or off |
| `blink_led` | Blink an LED N times |
| `led_pattern` | Run patterns (alternate, chase, both_on, both_off) |
| `read_orientation` | Get heading, pitch, roll from BNO055 |
| `read_imu_full` | Full IMU data (quaternion, accel, gravity, gyro, mag, temp) |
| `detect_motion` | Check if the board is moving |
| `remap_imu_axes` | Remap BNO055 axis orientation for different mounting positions |
| `set_header_pin` | Set a GPIO header pin high/low |
| `read_header_pin` | Read a GPIO header pin value |
| `get_system_info` | Uptime, memory, board temperature |
| `get_time` | Current date and time |

### Credentials

The systemd service runs as root because the SSM hybrid agent maintains its
rotating AWS credentials under `/root/.aws/credentials`. The associated role
needs `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`.

Because the process runs as root, network API authentication is mandatory,
model-created Python tools are disabled by default, and the systemd unit retains
filesystem and privilege hardening. Treat enabling
`ATOMICPI_ENABLE_SELF_MODIFICATION` as equivalent to granting the model root
code execution.

### Adding a USB Camera

With a USB webcam attached, you could add a vision tool that captures a frame and sends it to Claude's multimodal API. This would enable:

- **Visual inspection** — "What do you see?" / "Is there anyone in the room?"
- **Object detection** — "Count the items on the table"
- **Navigation assistance** — "Describe what's in front of me"
- **Security monitoring** — "Alert me if something changes"
- **QR/barcode reading** — "Scan that code"
- **Combined sensor+vision** — "Take a photo and tell me which direction it's facing"

Example tool (requires `opencv-python`):

```python
import cv2

@tool
def take_photo(description: str = "camera capture") -> dict:
    """Capture a photo from the USB camera and analyze it."""
    cap = cv2.VideoCapture(0)
    ret, frame = cap.read()
    cap.release()
    if not ret:
        return {"status": "error", "content": [{"text": "Capture failed"}]}
    encoded, buffer = cv2.imencode('.jpg', frame)
    if not encoded:
        return {"status": "error", "content": [{"text": "JPEG encoding failed"}]}
    return {
        "status": "success",
        "content": [{
            "image": {"format": "jpeg", "source": {"bytes": buffer.tobytes()}}
        }],
    }
```

## Local network access and mDNS

The setup script installs Avahi and advertises the machine's existing hostname
over mDNS. For a machine whose hostname is `atomic-pi-2`, open:

```text
http://atomic-pi-2.local:5000
```

For an already-configured Atomic Pi, keep or set whatever hostname you want,
then enable Avahi:

```bash
sudo apt update
sudo apt install -y avahi-daemon libnss-mdns
sudo systemctl enable --now avahi-daemon
sudo systemctl restart avahi-daemon
```

Check the name being advertised with `hostname -s`. If it prints `atomic-pi-2`,
the mDNS address is `atomic-pi-2.local`. To deliberately rename the machine,
run `sudo hostnamectl set-hostname <new-name>` and restart Avahi.

Verify from another machine on the same LAN with
`ping atomic-pi-2.local` or `curl http://atomic-pi-2.local:5000/health`.
The `.local` name uses multicast DNS, so it normally does not cross VLANs,
guest-network isolation, or routers that block multicast.

The network API requires a bearer token. The installer creates one in
`/etc/atomicpi-agent.env`; the web UI prompts for it and stores it in that
browser's local storage. For command-line use:

```bash
TOKEN=$(sudo sed -n 's/^ATOMICPI_API_TOKEN=//p' /etc/atomicpi-agent.env)
curl -X POST http://atomic-pi-2.local:5000/ask \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"Blink the green LED"}'
```

### Mobile pairing

To authorize a phone or tablet without typing the long bearer token, display a
pairing QR code on the Atomic Pi terminal:

```bash
sudo atomicpi-pair
```

Scan it with the mobile device. The QR URL carries the token in a URL fragment,
which browsers do not send to the HTTP server. The web UI saves the token in
that browser's local storage and immediately removes it from the visible URL
and browser history. Pairing is required once per browser unless its site data
is cleared.

Treat the QR code as a password: anyone who scans or photographs it can control
the agent. Clear the terminal after pairing and generate a new API token if the
QR code may have been exposed.

### Restarting after AWS credential rotation

The authenticated `POST /restart` endpoint restarts the agent process without
calling Bedrock. This remains available when an expired cached AWS credential
prevents the model from responding. The web UI exposes it as **Restart Service**.

```bash
curl -X POST http://localhost:5000/restart \
  -H "Authorization: Bearer $TOKEN"
```

The endpoint returns its JSON response first, then exits; systemd starts a new
process, which reloads `/root/.aws/credentials`.

Dynamic Python tool loading and self-modification are disabled by default.
Enabling `ATOMICPI_ENABLE_SELF_MODIFICATION=1` permits model-generated code to
run as the service user and should only be done on an isolated, trusted system.

## Notes

- `gpioset` holds the GPIO line for as long as the process runs. When killed/exited, the line is released and reverts to its default state.
- The legacy sysfs interface (`/sys/class/gpio/`) is deprecated on kernel 6.x. Use `libgpiod` tools or the chardev API instead.
- The gpiochip numbering differs from the 2019 AAEON documentation due to kernel version changes. Always verify with `gpiodetect` and `gpioinfo` on your running system.
- Board tested: Atomic Pi (AAEON UP-APL01), kernel 6.x, July 2026.
