#!/usr/bin/env python3
"""
Atomic Pi Robot Agent
Uses Strands Agents SDK with Amazon Bedrock (Claude) to control
the Atomic Pi's hardware via natural language.

Hardware tools:
  - LEDs (green/yellow, active-low on gpiochip2)
  - GPIO header pins (6 pins on 26-pin connector)
  - BNO055 IMU (orientation, acceleration, gravity, temperature)
  - XMOS audio (playback via aplay)

Setup:
  pip install strands-agents strands-agents-tools
  aws configure  # set up credentials with Bedrock access

Usage:
  python3 atomicpi_agent.py
"""

import os
import subprocess
import time

from strands import Agent
from strands.models.bedrock import BedrockModel
from strands.tools import tool

# ─── Configuration ───────────────────────────────────────────────────────────

IIO_PATH = "/sys/bus/iio/devices/iio:device0"

# GPIO mapping (gpiochip2 / East community)
LED_PINS = {
    "green": 18,   # ISH_GPIO_1, active-low
    "yellow": 24,  # ISH_GPIO_2, active-low
}

HEADER_PINS = {
    "ISH_GPIO_0": 21,  # 26-pin header pin 24
    "ISH_GPIO_3": 15,  # 26-pin header pin 18
    "ISH_GPIO_4": 22,  # 26-pin header pin 19
    "ISH_GPIO_7": 16,  # 26-pin header pin 20
}

GPIO_CHIP = "gpiochip2"

# ─── Helper functions ────────────────────────────────────────────────────────

def _gpioset(chip, line, value, duration=0.1):
    """Set a GPIO line to a value, hold briefly, then release."""
    proc = subprocess.Popen(["gpioset", chip, f"{line}={value}"])
    time.sleep(duration)
    proc.terminate()
    proc.wait()

def _gpioget(chip, line):
    """Read a GPIO line value."""
    result = subprocess.run(["gpioget", chip, str(line)], capture_output=True, text=True)
    return int(result.stdout.strip())

def _read_iio(filename):
    """Read a value from the IIO sysfs interface."""
    with open(os.path.join(IIO_PATH, filename)) as f:
        return f.read().strip()

# ─── LED Tools ───────────────────────────────────────────────────────────────

@tool
def set_led(led: str, state: str) -> str:
    """Control an on-board LED.

    Args:
        led: Which LED - 'green' or 'yellow'
        state: 'on' or 'off'
    """
    if led not in LED_PINS:
        return f"Unknown LED '{led}'. Choose 'green' or 'yellow'."

    line = LED_PINS[led]
    # Active-low: 0 = ON, 1 = OFF
    value = 0 if state == "on" else 1

    proc = subprocess.Popen(["gpioset", GPIO_CHIP, f"{line}={value}"])
    # Keep the process running to hold the line
    # Store PID for later cleanup
    global _led_procs
    if not hasattr(set_led, '_procs'):
        set_led._procs = {}

    # Kill any existing process for this LED
    if led in set_led._procs:
        set_led._procs[led].terminate()
        set_led._procs[led].wait()

    set_led._procs[led] = proc
    return f"{led.capitalize()} LED turned {state}."


@tool
def blink_led(led: str, times: int = 3, interval: float = 0.3) -> str:
    """Blink an on-board LED.

    Args:
        led: Which LED - 'green' or 'yellow'
        times: Number of blinks (default 3)
        interval: Time in seconds for each on/off phase (default 0.3)
    """
    if led not in LED_PINS:
        return f"Unknown LED '{led}'. Choose 'green' or 'yellow'."

    line = LED_PINS[led]

    for _ in range(times):
        _gpioset(GPIO_CHIP, line, 0, interval)  # ON (active-low)
        _gpioset(GPIO_CHIP, line, 1, interval)  # OFF

    return f"Blinked {led} LED {times} times."


@tool
def led_pattern(pattern: str) -> str:
    """Run a pattern on both LEDs.

    Args:
        pattern: One of 'alternate', 'both_on', 'both_off', 'chase'
    """
    green = LED_PINS["green"]
    yellow = LED_PINS["yellow"]

    if pattern == "both_on":
        proc = subprocess.Popen(["gpioset", GPIO_CHIP, f"{green}=0", f"{yellow}=0"])
        if not hasattr(led_pattern, '_proc'):
            led_pattern._proc = None
        if led_pattern._proc:
            led_pattern._proc.terminate()
        led_pattern._proc = proc
        return "Both LEDs on."

    elif pattern == "both_off":
        _gpioset(GPIO_CHIP, green, 1, 0.05)
        _gpioset(GPIO_CHIP, yellow, 1, 0.05)
        if hasattr(led_pattern, '_proc') and led_pattern._proc:
            led_pattern._proc.terminate()
        return "Both LEDs off."

    elif pattern == "alternate":
        for _ in range(4):
            _gpioset(GPIO_CHIP, green, 0, 0.3)
            _gpioset(GPIO_CHIP, green, 1, 0.05)
            _gpioset(GPIO_CHIP, yellow, 0, 0.3)
            _gpioset(GPIO_CHIP, yellow, 1, 0.05)
        return "Alternating pattern complete."

    elif pattern == "chase":
        for _ in range(3):
            _gpioset(GPIO_CHIP, green, 0, 0.15)
            _gpioset(GPIO_CHIP, green, 1, 0.05)
            _gpioset(GPIO_CHIP, yellow, 0, 0.15)
            _gpioset(GPIO_CHIP, yellow, 1, 0.05)
        return "Chase pattern complete."

    return f"Unknown pattern '{pattern}'. Use: alternate, both_on, both_off, chase."

# ─── IMU Tools ───────────────────────────────────────────────────────────────

@tool
def read_orientation() -> str:
    """Read the current orientation (heading/yaw, pitch, roll) from the BNO055 IMU."""
    try:
        scale = float(_read_iio("in_rot_scale"))
        yaw = int(_read_iio("in_rot_yaw_raw")) * scale
        pitch = int(_read_iio("in_rot_pitch_raw")) * scale
        roll = int(_read_iio("in_rot_roll_raw")) * scale
        return f"Heading: {yaw:.1f}°, Pitch: {pitch:.1f}°, Roll: {roll:.1f}°"
    except Exception as e:
        return f"Error reading orientation: {e}"


@tool
def read_imu_full() -> str:
    """Read all IMU data: orientation, quaternion, acceleration, gravity, gyro, temperature."""
    try:
        rot_scale = float(_read_iio("in_rot_scale"))
        accel_scale = float(_read_iio("in_accel_scale"))
        grav_scale = float(_read_iio("in_gravity_scale"))
        gyro_scale = float(_read_iio("in_anglvel_scale"))

        yaw = int(_read_iio("in_rot_yaw_raw")) * rot_scale
        pitch = int(_read_iio("in_rot_pitch_raw")) * rot_scale
        roll = int(_read_iio("in_rot_roll_raw")) * rot_scale

        quat = [int(x) / 16384.0 for x in _read_iio("in_rot_quaternion_raw").split()]

        lin_x = int(_read_iio("in_accel_linear_x_raw")) * accel_scale
        lin_y = int(_read_iio("in_accel_linear_y_raw")) * accel_scale
        lin_z = int(_read_iio("in_accel_linear_z_raw")) * accel_scale

        grav_x = int(_read_iio("in_gravity_x_raw")) * grav_scale
        grav_y = int(_read_iio("in_gravity_y_raw")) * grav_scale
        grav_z = int(_read_iio("in_gravity_z_raw")) * grav_scale

        gyro_x = int(_read_iio("in_anglvel_x_raw")) * gyro_scale
        gyro_y = int(_read_iio("in_anglvel_y_raw")) * gyro_scale
        gyro_z = int(_read_iio("in_anglvel_z_raw")) * gyro_scale

        temp = float(_read_iio("in_temp_input")) / 1000.0

        cal_sys = _read_iio("sys_calibration_auto_status")
        cal_gyro = _read_iio("in_gyro_calibration_auto_status")
        cal_accel = _read_iio("in_accel_calibration_auto_status")
        cal_magn = _read_iio("in_magn_calibration_auto_status")

        return (
            f"Orientation: Heading={yaw:.1f}° Pitch={pitch:.1f}° Roll={roll:.1f}°\n"
            f"Quaternion: W={quat[0]:.3f} X={quat[1]:.3f} Y={quat[2]:.3f} Z={quat[3]:.3f}\n"
            f"Linear Accel: X={lin_x:.2f} Y={lin_y:.2f} Z={lin_z:.2f} m/s²\n"
            f"Gravity: X={grav_x:.2f} Y={grav_y:.2f} Z={grav_z:.2f} m/s²\n"
            f"Gyroscope: X={gyro_x:.3f} Y={gyro_y:.3f} Z={gyro_z:.3f} rad/s\n"
            f"Temperature: {temp:.1f}°C\n"
            f"Calibration: Sys={cal_sys} Gyro={cal_gyro} Accel={cal_accel} Magn={cal_magn}"
        )
    except Exception as e:
        return f"Error reading IMU: {e}"


@tool
def detect_motion() -> str:
    """Check if the board is currently in motion by reading linear acceleration."""
    try:
        scale = float(_read_iio("in_accel_scale"))
        x = int(_read_iio("in_accel_linear_x_raw")) * scale
        y = int(_read_iio("in_accel_linear_y_raw")) * scale
        z = int(_read_iio("in_accel_linear_z_raw")) * scale
        magnitude = (x**2 + y**2 + z**2) ** 0.5

        if magnitude > 1.0:
            return f"MOVING - acceleration magnitude: {magnitude:.2f} m/s² (X={x:.2f} Y={y:.2f} Z={z:.2f})"
        elif magnitude > 0.3:
            return f"SLIGHT MOTION - acceleration magnitude: {magnitude:.2f} m/s² (X={x:.2f} Y={y:.2f} Z={z:.2f})"
        else:
            return f"STATIONARY - acceleration magnitude: {magnitude:.2f} m/s² (X={x:.2f} Y={y:.2f} Z={z:.2f})"
    except Exception as e:
        return f"Error detecting motion: {e}"

# ─── Camera Tools ─────────────────────────────────────────────────────────────

@tool
def take_photo(description: str = "camera capture") -> dict:
    """Capture a photo from the USB camera. Returns the image for analysis.

    Args:
        description: Optional description of what to look for in the image.
    """
    import cv2
    import base64

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        return {"error": "Failed to open camera. Is the geocam firmware loaded?"}

    ret, frame = cap.read()
    cap.release()

    if not ret:
        return {"error": "Failed to capture frame"}

    # Encode as JPEG
    _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
    b64_image = base64.b64encode(buffer).decode('utf-8')

    return {
        "image": b64_image,
        "format": "jpeg",
        "resolution": f"{frame.shape[1]}x{frame.shape[0]}",
        "description": description,
    }


# ─── Audio Tools ──────────────────────────────────────────────────────────────

@tool
def play_sound(sound: str = "beep") -> str:
    """Play a sound through the XMOS Mayfield Audio speakers.

    Args:
        sound: One of 'beep', 'success', 'error', 'alert', or a path to a .wav file
    """
    # Find the XMOS audio card number
    result = subprocess.run(["aplay", "-l"], capture_output=True, text=True)
    card_num = None
    for line in result.stdout.split('\n'):
        if 'Mayfield' in line or 'Audio_1' in line:
            card_num = line.split('card ')[1].split(':')[0]
            break

    if card_num is None:
        return "Error: XMOS Mayfield Audio card not found. Has the XMOS been reset?"

    device = f"plughw:{card_num},0"

    # Generate tones using speaker-test or aplay
    if sound == "beep":
        result = subprocess.run(
            ["speaker-test", "-D", device, "-t", "sine", "-f", "800", "-l", "1", "-p", "1"],
            capture_output=True, text=True, timeout=3
        )
    elif sound == "success":
        # Two ascending tones
        subprocess.run(["speaker-test", "-D", device, "-t", "sine", "-f", "600", "-l", "1", "-p", "1"],
                      capture_output=True, timeout=2)
        subprocess.run(["speaker-test", "-D", device, "-t", "sine", "-f", "900", "-l", "1", "-p", "1"],
                      capture_output=True, timeout=2)
    elif sound == "error":
        # Low buzz
        result = subprocess.run(
            ["speaker-test", "-D", device, "-t", "sine", "-f", "200", "-l", "1", "-p", "1"],
            capture_output=True, text=True, timeout=3
        )
    elif sound == "alert":
        # Three quick beeps
        for _ in range(3):
            subprocess.run(["speaker-test", "-D", device, "-t", "sine", "-f", "1000", "-l", "1", "-p", "1"],
                          capture_output=True, timeout=2)
    elif sound.endswith('.wav'):
        result = subprocess.run(["aplay", "-D", device, sound], capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return f"Error playing file: {result.stderr}"
    else:
        return f"Unknown sound '{sound}'. Use: beep, success, error, alert, or a .wav file path."

    return f"Played '{sound}' on XMOS Mayfield Audio (card {card_num})."


@tool
def speak(text: str) -> str:
    """Speak text aloud through the XMOS speakers using text-to-speech.

    Args:
        text: The text to speak aloud.
    """
    # Find XMOS card
    result = subprocess.run(["aplay", "-l"], capture_output=True, text=True)
    card_num = None
    for line in result.stdout.split('\n'):
        if 'Mayfield' in line or 'Audio_1' in line:
            card_num = line.split('card ')[1].split(':')[0]
            break

    if card_num is None:
        return "Error: XMOS Mayfield Audio card not found."

    # Try espeak-ng first, fall back to espeak
    tts_cmd = None
    for cmd in ["espeak-ng", "espeak"]:
        if subprocess.run(["which", cmd], capture_output=True).returncode == 0:
            tts_cmd = cmd
            break

    if tts_cmd is None:
        return "Error: No TTS engine installed. Run: sudo apt install espeak-ng"

    # Generate speech and play through XMOS
    device = f"plughw:{card_num},0"
    result = subprocess.run(
        [tts_cmd, "-v", "en", "--stdout", text],
        capture_output=True
    )

    if result.returncode != 0:
        return f"TTS generation failed."

    # Pipe to aplay
    play = subprocess.run(
        ["aplay", "-D", device, "-"],
        input=result.stdout,
        capture_output=True,
        timeout=30
    )

    if play.returncode != 0:
        return f"Playback failed: {play.stderr.decode()}"

    return f"Spoke: \"{text}\""


# ─── GPIO Header Tools ───────────────────────────────────────────────────────

@tool
def remap_imu_axes(config: str = "default") -> str:
    """Remap the BNO055 IMU axes for different mounting orientations.

    Args:
        config: One of:
            'default' - X=X, Y=Y, Z=Z (chip default, dot facing up-right)
            'x_forward' - X axis points forward (heading follows X)
            'y_forward' - Y axis points forward
            'z_up_x_forward' - Z up, X forward (common robot mounting)
            'custom:XY,YX,ZZ,++-' - Custom: axis mapping + signs
    """
    import smbus2

    BUS = 50
    ADDR = 0x28
    OPR_MODE = 0x3D
    AXIS_MAP_CONFIG = 0x41
    AXIS_MAP_SIGN = 0x42

    # Predefined configurations
    # AXIS_MAP_CONFIG bits: [5:4]=Z_map, [3:2]=Y_map, [1:0]=X_map
    #   0=X, 1=Y, 2=Z
    # AXIS_MAP_SIGN bits: [2]=X_sign, [1]=Y_sign, [0]=Z_sign
    #   0=positive, 1=negative
    configs = {
        "default":          (0x24, 0x00),  # X=X, Y=Y, Z=Z, all positive
        "x_forward":        (0x24, 0x00),  # Same as default
        "y_forward":        (0x21, 0x04),  # X=Y, Y=X, Z=Z, X_sign negative
        "z_up_x_forward":   (0x24, 0x00),  # X=X, Y=Y, Z=Z (standard)
        "x_east_y_north":   (0x21, 0x00),  # Swap X/Y
        "z_down":           (0x24, 0x01),  # Flip Z axis
    }

    if config.startswith("custom:"):
        # Parse custom format: "custom:0x24,0x00"
        try:
            parts = config.split(":")[1].split(",")
            map_config = int(parts[0], 0)
            map_sign = int(parts[1], 0)
        except (IndexError, ValueError) as e:
            return f"Error parsing custom config: {e}. Format: 'custom:0x24,0x00'"
    elif config in configs:
        map_config, map_sign = configs[config]
    else:
        return f"Unknown config '{config}'. Available: {list(configs.keys())} or 'custom:0xNN,0xNN'"

    try:
        # Need to unbind the IIO driver first to access i2c directly
        # Write the device out of the driver
        try:
            with open("/sys/bus/i2c/drivers/bno055-i2c/unbind", "w") as f:
                f.write("50-0028")
        except Exception:
            pass  # May already be unbound

        import time
        time.sleep(0.1)

        bus = smbus2.SMBus(BUS)

        # Switch to CONFIG mode (required for register writes)
        bus.write_byte_data(ADDR, OPR_MODE, 0x00)
        time.sleep(0.025)

        # Write axis remap
        bus.write_byte_data(ADDR, AXIS_MAP_CONFIG, map_config)
        bus.write_byte_data(ADDR, AXIS_MAP_SIGN, map_sign)

        # Switch back to NDOF mode (full fusion)
        bus.write_byte_data(ADDR, OPR_MODE, 0x0C)
        time.sleep(0.1)

        bus.close()

        # Rebind the IIO driver
        try:
            with open("/sys/bus/i2c/drivers/bno055-i2c/bind", "w") as f:
                f.write("50-0028")
        except Exception:
            pass

        time.sleep(0.5)

        return (
            f"Axis remap set to '{config}': "
            f"AXIS_MAP_CONFIG=0x{map_config:02X}, AXIS_MAP_SIGN=0x{map_sign:02X}. "
            f"IIO driver rebound."
        )
    except Exception as e:
        # Try to rebind driver on error
        try:
            with open("/sys/bus/i2c/drivers/bno055-i2c/bind", "w") as f:
                f.write("50-0028")
        except:
            pass
        return f"Error remapping axes: {e}"


# ─── GPIO Header Tools (continued) ──────────────────────────────────────────

@tool
def set_header_pin(pin_name: str, value: int) -> str:
    """Set a 26-pin header GPIO to high (1) or low (0).

    Args:
        pin_name: One of 'ISH_GPIO_0', 'ISH_GPIO_3', 'ISH_GPIO_4', 'ISH_GPIO_7'
        value: 1 for high (3.3V), 0 for low (GND)
    """
    if pin_name not in HEADER_PINS:
        return f"Unknown pin '{pin_name}'. Available: {list(HEADER_PINS.keys())}"

    line = HEADER_PINS[pin_name]
    _gpioset(GPIO_CHIP, line, value, 0.05)
    state = "HIGH (3.3V)" if value == 1 else "LOW (GND)"
    return f"Set {pin_name} (line {line}) to {state}."


@tool
def read_header_pin(pin_name: str) -> str:
    """Read the current value of a 26-pin header GPIO.

    Args:
        pin_name: One of 'ISH_GPIO_0', 'ISH_GPIO_3', 'ISH_GPIO_4', 'ISH_GPIO_7'
    """
    if pin_name not in HEADER_PINS:
        return f"Unknown pin '{pin_name}'. Available: {list(HEADER_PINS.keys())}"

    line = HEADER_PINS[pin_name]
    val = _gpioget(GPIO_CHIP, line)
    state = "HIGH" if val == 1 else "LOW"
    return f"{pin_name} (line {line}) = {state} ({val})"

# ─── System Tools ────────────────────────────────────────────────────────────

@tool
def get_system_info() -> str:
    """Get Atomic Pi system information (board temp, uptime, memory)."""
    try:
        uptime = subprocess.run(["uptime", "-p"], capture_output=True, text=True).stdout.strip()
        mem = subprocess.run(["free", "-h"], capture_output=True, text=True).stdout

        # Use BNO055 IMU temperature (measures board/ambient temp)
        try:
            temp = float(_read_iio("in_temp_input")) / 1000.0
            temp_str = f"Board Temp: {temp:.1f}°C (from BNO055)"
        except:
            temp_str = "Board Temp: unavailable"

        return f"Uptime: {uptime}\n{temp_str}\n{mem}"
    except Exception as e:
        return f"Error: {e}"

@tool
def get_time() -> str:
    """Get the current date and time from the system clock."""
    result = subprocess.run(["date", "+%Y-%m-%d %H:%M:%S %Z (%A)"], capture_output=True, text=True)
    return result.stdout.strip()

# ─── Agent Setup ─────────────────────────────────────────────────────────────

TOOLS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools")

def load_dynamic_tools():
    """Auto-discover and load tools from the tools/ directory."""
    import importlib.util
    import sys

    loaded_tools = []

    if not os.path.isdir(TOOLS_DIR):
        os.makedirs(TOOLS_DIR, exist_ok=True)
        return loaded_tools

    for filename in sorted(os.listdir(TOOLS_DIR)):
        if not filename.endswith('.py') or filename.startswith('_'):
            continue

        filepath = os.path.join(TOOLS_DIR, filename)
        module_name = f"tools.{filename[:-3]}"

        try:
            spec = importlib.util.spec_from_file_location(module_name, filepath)
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            spec.loader.exec_module(module)

            # Find all @tool decorated functions in the module
            for attr_name in dir(module):
                obj = getattr(module, attr_name)
                if callable(obj) and hasattr(obj, 'name'):
                    loaded_tools.append(obj)
        except Exception as e:
            print(f"  ⚠️  Failed to load {filename}: {e}")

    return loaded_tools


# ─── Self-Modification Tools ─────────────────────────────────────────────────

@tool
def create_tool(name: str, description: str, code: str) -> str:
    """Create a new tool by writing a Python file to the tools/ directory.
    The tool will be available after the agent is restarted.

    Args:
        name: Name for the tool file (without .py extension)
        description: What the tool does
        code: Complete Python code including imports and @tool decorator.
              Must import 'from strands.tools import tool' and use @tool decorator.
    """
    if not name.isidentifier():
        return f"Invalid tool name '{name}'. Must be a valid Python identifier."

    filepath = os.path.join(TOOLS_DIR, f"{name}.py")

    if os.path.exists(filepath):
        return f"Tool '{name}' already exists at {filepath}. Use edit_tool to modify it."

    # Ensure the code has the required import
    if "from strands.tools import tool" not in code:
        code = "from strands.tools import tool\nimport os\nimport subprocess\n\n" + code

    with open(filepath, 'w') as f:
        f.write(f'"""\n{description}\n"""\n\n')
        f.write(code)

    return f"Tool '{name}' created at {filepath}. Restart the agent to load it."


@tool
def edit_tool(name: str, code: str) -> str:
    """Edit an existing dynamic tool in the tools/ directory.

    Args:
        name: Name of the tool file (without .py extension)
        code: Complete replacement Python code including imports and @tool decorator.
    """
    filepath = os.path.join(TOOLS_DIR, f"{name}.py")

    if not os.path.exists(filepath):
        return f"Tool '{name}' does not exist. Use create_tool to make a new one."

    # Ensure the code has the required import
    if "from strands.tools import tool" not in code:
        code = "from strands.tools import tool\nimport os\nimport subprocess\n\n" + code

    with open(filepath, 'w') as f:
        f.write(code)

    return f"Tool '{name}' updated at {filepath}. Restart the agent to reload it."


@tool
def list_tools() -> str:
    """List all available dynamic tools in the tools/ directory."""
    if not os.path.isdir(TOOLS_DIR):
        return "No tools directory found."

    files = [f for f in os.listdir(TOOLS_DIR) if f.endswith('.py') and not f.startswith('_')]

    if not files:
        return "No dynamic tools installed. Use create_tool to make one."

    result = "Dynamic tools in tools/ directory:\n"
    for f in sorted(files):
        filepath = os.path.join(TOOLS_DIR, f)
        # Read first docstring line
        with open(filepath) as fh:
            content = fh.read()
        desc = ""
        if '"""' in content:
            desc = content.split('"""')[1].strip().split('\n')[0]
        result += f"  • {f[:-3]}: {desc}\n"

    return result


@tool
def read_tool_source(name: str) -> str:
    """Read the source code of a dynamic tool.

    Args:
        name: Name of the tool file (without .py extension)
    """
    filepath = os.path.join(TOOLS_DIR, f"{name}.py")

    if not os.path.exists(filepath):
        return f"Tool '{name}' not found in {TOOLS_DIR}."

    with open(filepath) as f:
        return f.read()


@tool
def delete_tool(name: str) -> str:
    """Delete a dynamic tool from the tools/ directory.

    Args:
        name: Name of the tool file (without .py extension)
    """
    filepath = os.path.join(TOOLS_DIR, f"{name}.py")

    if not os.path.exists(filepath):
        return f"Tool '{name}' not found."

    os.remove(filepath)
    return f"Tool '{name}' deleted. It will no longer load on next restart."


@tool
def restart_agent() -> str:
    """Restart the agent process to reload configuration and dynamic tools."""
    import sys
    print("\n🔄 Restarting agent...\n")
    os.execv(sys.executable, [sys.executable] + sys.argv)


SYSTEM_PROMPT = """You are an AI agent running on an Atomic Pi single-board computer (Intel Atom x5-Z8350).

You have direct hardware control via tools:
- Two on-board LEDs (green and yellow)
- A BNO055 9-axis IMU (orientation, acceleration, gravity, gyroscope, magnetometer)
- A USB camera (GEO Semiconductor GC6500, 640x480)
- XMOS Mayfield Audio speakers (sound playback and text-to-speech)
- 4 GPIO header pins for connecting external devices
- System monitoring (temperature, uptime, memory, clock)

You can also extend yourself:
- Create new tools (create_tool) that persist in the tools/ directory
- Edit, list, read, or delete dynamic tools
- Restart yourself to load new tools

When asked about orientation, direction, or motion, use the IMU tools.
When asked to signal, indicate, or alert, use the LED tools.
When asked to look or see, use the camera.
When asked to speak or make sound, use the audio tools.
Be concise in responses. You are an embedded controller, not a chatbot.

Hardware facts:
- LEDs are active-low (the tools handle this for you)
- The BNO055 provides absolute orientation (magnetic north reference)
- GPIO header pins output 3.3V logic levels
- Board temperature runs 35-45°C normally
- XMOS audio is card 1 or 2 depending on boot order
- Camera requires geocam firmware (auto-loaded via udev)
"""

def create_agent():
    """Create and return the configured agent with all tools."""
    model = BedrockModel(
        model_id="us.anthropic.claude-sonnet-4-6",
        region_name="us-west-2",  # Change to your Bedrock region
    )

    # Load dynamic tools from tools/ directory
    dynamic_tools = load_dynamic_tools()
    if dynamic_tools:
        print(f"  Loaded {len(dynamic_tools)} dynamic tool(s) from tools/")

    # Core tools + self-modification tools + dynamic tools
    all_tools = [
        # Hardware
        set_led, blink_led, led_pattern,
        read_orientation, read_imu_full, detect_motion,
        remap_imu_axes,
        take_photo,
        play_sound, speak,
        set_header_pin, read_header_pin,
        get_system_info, get_time,
        # Self-modification
        create_tool, edit_tool, list_tools, read_tool_source, delete_tool,
        restart_agent,
    ] + dynamic_tools

    agent = Agent(
        model=model,
        tools=all_tools,
        system_prompt=SYSTEM_PROMPT,
    )

    return agent


# ─── Mode: Interactive (CLI chat) ────────────────────────────────────────────

def mode_interactive():
    """Run the agent in interactive chat mode."""
    agent = create_agent()

    print("╔══════════════════════════════════════════╗")
    print("║   Atomic Pi Robot Agent                  ║")
    print("║   Powered by Strands + Bedrock Claude    ║")
    print("╚══════════════════════════════════════════╝")
    print()
    print("Type commands in natural language. Ctrl+C to exit.")
    print()

    try:
        while True:
            user_input = input("You > ")
            if not user_input.strip():
                continue

            print()
            response = agent(user_input)
            print(f"\nAgent > {response}\n")

    except KeyboardInterrupt:
        print("\nShutting down...")
        _cleanup()


# ─── Mode: Autonomous ────────────────────────────────────────────────────────

def mode_autonomous():
    """Run the agent in autonomous mode — perceives and acts on its own."""
    import json

    agent = create_agent()
    COMMAND_FILE = "/tmp/atomicpi_command.json"

    print("╔══════════════════════════════════════════╗")
    print("║   Atomic Pi Robot Agent (Autonomous)     ║")
    print("║   Powered by Strands + Bedrock Claude    ║")
    print("╚══════════════════════════════════════════╝")
    print()
    print(f"  Command file: {COMMAND_FILE}")
    print(f"  Drop a JSON file there to send commands.")
    print()

    AUTONOMOUS_PROMPT = """You are in autonomous mode. Perform a status check:
1. Blink the green LED once to show you're alive
2. Check for motion — if motion detected, take a photo and describe what you see
3. If temperature is above 50°C, blink yellow LED as a warning
4. Report any anomalies briefly

Keep responses short. Only speak aloud if something urgent is happening."""

    cycle = 0
    try:
        while True:
            cycle += 1
            print(f"[Cycle {cycle}] {time.strftime('%H:%M:%S')} — ", end="", flush=True)

            # Check for external commands
            command = None
            if os.path.exists(COMMAND_FILE):
                try:
                    with open(COMMAND_FILE) as f:
                        command = json.load(f).get("message", "")
                    os.remove(COMMAND_FILE)
                    print(f"COMMAND: {command}")
                except Exception:
                    pass

            if command:
                response = agent(command)
                print(f"  → {response}\n")
            else:
                response = agent(AUTONOMOUS_PROMPT)
                print(f"  → OK\n")

            # Sleep between cycles (30 seconds default)
            time.sleep(30)

    except KeyboardInterrupt:
        print("\nAutonomous mode stopped.")
        _cleanup()


# ─── Mode: API Server ────────────────────────────────────────────────────────

def mode_server(host="0.0.0.0", port=5000):
    """Run the agent as an HTTP API server with web UI."""
    from flask import Flask, request, jsonify, send_from_directory
    import threading

    static_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
    app = Flask(__name__, static_folder=static_dir)
    agent = create_agent()
    agent_lock = threading.Lock()

    # Autonomous background loop (optional)
    autonomous_enabled = False
    autonomous_interval = 60  # seconds

    @app.route('/', methods=['GET'])
    def index():
        return send_from_directory(static_dir, 'index.html')

    @app.route('/health', methods=['GET'])
    def health():
        return jsonify({"status": "ok", "mode": "server", "hostname": os.uname().nodename})

    @app.route('/ask', methods=['POST'])
    def ask():
        data = request.get_json()
        if not data or 'message' not in data:
            return jsonify({"error": "Missing 'message' field"}), 400

        with agent_lock:
            response = agent(data['message'])

        return jsonify({"response": str(response)})

    @app.route('/autonomous', methods=['POST'])
    def toggle_autonomous():
        nonlocal autonomous_enabled
        data = request.get_json() or {}
        autonomous_enabled = data.get('enabled', not autonomous_enabled)
        return jsonify({"autonomous": autonomous_enabled, "interval": autonomous_interval})

    @app.route('/tools', methods=['GET'])
    def get_tools():
        tool_files = []
        if os.path.isdir(TOOLS_DIR):
            tool_files = [f[:-3] for f in os.listdir(TOOLS_DIR)
                         if f.endswith('.py') and not f.startswith('_')]
        return jsonify({"dynamic_tools": tool_files})

    def autonomous_loop():
        """Background thread for autonomous behavior."""
        AUTONOMOUS_PROMPT = "Quick status check: blink green LED, check motion, report anomalies only."
        while True:
            time.sleep(autonomous_interval)
            if autonomous_enabled:
                try:
                    with agent_lock:
                        agent(AUTONOMOUS_PROMPT)
                except Exception as e:
                    print(f"  [autonomous] Error: {e}")

    # Start autonomous background thread
    bg_thread = threading.Thread(target=autonomous_loop, daemon=True)
    bg_thread.start()

    print("╔══════════════════════════════════════════╗")
    print("║   Atomic Pi Robot Agent (API Server)     ║")
    print("║   Powered by Strands + Bedrock Claude    ║")
    print("╚══════════════════════════════════════════╝")
    print()
    print(f"  Listening on http://{host}:{port}")
    print()
    print("  Endpoints:")
    print("    POST /ask              - Send a command")
    print("    POST /autonomous       - Toggle autonomous mode")
    print("    GET  /health           - Health check")
    print("    GET  /tools            - List dynamic tools")
    print()

    app.run(host=host, port=port, debug=False)


# ─── Cleanup ─────────────────────────────────────────────────────────────────

def _cleanup():
    """Clean up GPIO processes."""
    if hasattr(set_led, '_procs'):
        for proc in set_led._procs.values():
            proc.terminate()
    if hasattr(led_pattern, '_proc') and led_pattern._proc:
        led_pattern._proc.terminate()
    print("Done.")


# ─── Entry Point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Atomic Pi Robot Agent")
    parser.add_argument("--mode", choices=["interactive", "autonomous", "server"],
                       default="interactive",
                       help="Agent mode: interactive (CLI), autonomous (self-directed), server (HTTP API)")
    parser.add_argument("--host", default="0.0.0.0", help="API server host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=5000, help="API server port (default: 5000)")

    args = parser.parse_args()

    if args.mode == "interactive":
        mode_interactive()
    elif args.mode == "autonomous":
        mode_autonomous()
    elif args.mode == "server":
        mode_server(host=args.host, port=args.port)

