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
