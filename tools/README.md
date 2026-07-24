# Dynamic Tools Directory

Place Python files here with `@tool` decorated functions.
They will be auto-discovered and loaded by the agent on startup.

## Example

Create a file `tools/my_sensor.py`:

```python
from strands.tools import tool

@tool
def read_my_sensor() -> str:
    """Read data from my custom sensor."""
    # Your implementation here
    return "sensor value: 42"
```

The agent will load it on next restart.

## BNO055 rule

The BNO055 is owned by the Linux kernel IIO driver. Dynamic tools must read the
device under `/sys/bus/iio/devices/iio:device*/` whose `name` file contains
`bno055`. Prefer the agent's built-in `read_orientation`, `read_imu_full`, and
`detect_motion` tools.

Do not import `board`, `busio`, `adafruit_bno055`, or `Adafruit_BNO055`, and do
not open `/dev/i2c-50` from a dynamic tool. Competing with the kernel driver can
fail or disrupt the working IIO device.
