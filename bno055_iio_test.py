#!/usr/bin/env python3
"""
Atomic Pi BNO055 IMU Reader (via kernel IIO interface)

Reads orientation, acceleration, gravity, gyroscope, magnetometer,
and temperature from the BNO055 via /sys/bus/iio/devices/iio:device0/

No external libraries required.
"""

import time
import os

IIO_PATH = "/sys/bus/iio/devices/iio:device0"

def read_iio(filename):
    """Read a single value from the IIO sysfs interface."""
    with open(os.path.join(IIO_PATH, filename)) as f:
        return f.read().strip()

def read_float(filename):
    """Read a numeric value."""
    return float(read_iio(filename))

def read_ints(filename):
    """Read space-separated integers."""
    return [int(x) for x in read_iio(filename).split()]

def get_euler():
    """Read Euler angles (degrees)."""
    scale = read_float("in_rot_scale")
    yaw = int(read_iio("in_rot_yaw_raw")) * scale
    pitch = int(read_iio("in_rot_pitch_raw")) * scale
    roll = int(read_iio("in_rot_roll_raw")) * scale
    return yaw, pitch, roll

def get_quaternion():
    """Read quaternion (w, x, y, z) normalized."""
    raw = read_ints("in_rot_quaternion_raw")
    # BNO055 quaternion is in Q14 format (divide by 2^14 = 16384)
    return [v / 16384.0 for v in raw]

def get_accel():
    """Read accelerometer (m/s²)."""
    scale = read_float("in_accel_scale")
    x = int(read_iio("in_accel_x_raw")) * scale
    y = int(read_iio("in_accel_y_raw")) * scale
    z = int(read_iio("in_accel_z_raw")) * scale
    return x, y, z

def get_linear_accel():
    """Read linear acceleration (m/s², gravity removed)."""
    scale = read_float("in_accel_scale")
    x = int(read_iio("in_accel_linear_x_raw")) * scale
    y = int(read_iio("in_accel_linear_y_raw")) * scale
    z = int(read_iio("in_accel_linear_z_raw")) * scale
    return x, y, z

def get_gravity():
    """Read gravity vector (m/s²)."""
    scale = read_float("in_gravity_scale")
    x = int(read_iio("in_gravity_x_raw")) * scale
    y = int(read_iio("in_gravity_y_raw")) * scale
    z = int(read_iio("in_gravity_z_raw")) * scale
    return x, y, z

def get_gyro():
    """Read gyroscope (rad/s)."""
    scale = read_float("in_anglvel_scale")
    x = int(read_iio("in_anglvel_x_raw")) * scale
    y = int(read_iio("in_anglvel_y_raw")) * scale
    z = int(read_iio("in_anglvel_z_raw")) * scale
    return x, y, z

def get_mag():
    """Read magnetometer (Gauss)."""
    scale = read_float("in_magn_scale")
    x = int(read_iio("in_magn_x_raw")) * scale
    y = int(read_iio("in_magn_y_raw")) * scale
    z = int(read_iio("in_magn_z_raw")) * scale
    return x, y, z

def get_temp():
    """Read temperature (°C)."""
    return read_float("in_temp_input") / 1000.0

def get_calibration():
    """Read calibration status for each subsystem."""
    accel = read_iio("in_accel_calibration_auto_status")
    gyro = read_iio("in_gyro_calibration_auto_status")
    magn = read_iio("in_magn_calibration_auto_status")
    sys = read_iio("sys_calibration_auto_status")
    return {"system": sys, "gyro": gyro, "accel": accel, "magn": magn}

def main():
    # Verify sensor
    name = read_iio("name")
    print(f"Sensor: {name}")
    print(f"Serial: {read_iio('serialnumber')}")
    print(f"Fusion: {read_iio('fusion_enable')}")
    print()

    try:
        while True:
            yaw, pitch, roll = get_euler()
            qw, qx, qy, qz = get_quaternion()
            ax, ay, az = get_linear_accel()
            gx, gy, gz = get_gravity()
            wx, wy, wz = get_gyro()
            mx, my, mz = get_mag()
            temp = get_temp()
            cal = get_calibration()

            print(f"\033[2J\033[H")  # Clear screen
            print("═══════════════════════════════════════════")
            print("   Atomic Pi BNO055 IMU - Live Data")
            print("═══════════════════════════════════════════")
            print()
            print(f"  Orientation (Euler):")
            print(f"    Heading: {yaw:7.1f}°")
            print(f"    Pitch:   {pitch:7.1f}°")
            print(f"    Roll:    {roll:7.1f}°")
            print()
            print(f"  Quaternion:")
            print(f"    W={qw:6.3f}  X={qx:6.3f}  Y={qy:6.3f}  Z={qz:6.3f}")
            print()
            print(f"  Linear Acceleration (m/s²):")
            print(f"    X={ax:6.2f}  Y={ay:6.2f}  Z={az:6.2f}")
            print()
            print(f"  Gravity (m/s²):")
            print(f"    X={gx:6.2f}  Y={gy:6.2f}  Z={gz:6.2f}")
            print()
            print(f"  Gyroscope (rad/s):")
            print(f"    X={wx:6.3f}  Y={wy:6.3f}  Z={wz:6.3f}")
            print()
            print(f"  Magnetometer (Gauss):")
            print(f"    X={mx:6.2f}  Y={my:6.2f}  Z={mz:6.2f}")
            print()
            print(f"  Temperature: {temp:.1f}°C")
            print()
            print(f"  Calibration: Sys={cal['system']} Gyro={cal['gyro']}"
                  f" Accel={cal['accel']} Magn={cal['magn']}")
            print()
            print("  [Ctrl+C to exit]")

            time.sleep(0.1)

    except KeyboardInterrupt:
        print("\nDone.")

if __name__ == "__main__":
    main()
