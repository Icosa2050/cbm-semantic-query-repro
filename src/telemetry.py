"""Vehicle sensor telemetry: battery, cabin temperature, tyre pressure."""

from dataclasses import dataclass

BATTERY_CRITICAL_PERCENT = 12
CABIN_TEMPERATURE_CEILING_C = 8.0
TYRE_PRESSURE_MIN_BAR = 2.1


@dataclass(frozen=True)
class SensorReading:
    sensor_id: str
    battery_percent: int
    cabin_temperature_c: float
    tyre_pressure_bar: float


def battery_is_critical(reading: SensorReading) -> bool:
    """True when the onboard battery has dropped below the critical charge."""
    return reading.battery_percent < BATTERY_CRITICAL_PERCENT


def refrigeration_breached(reading: SensorReading) -> bool:
    """True when the cold-chain cabin temperature ceiling was exceeded."""
    return reading.cabin_temperature_c > CABIN_TEMPERATURE_CEILING_C


def tyre_pressure_low(reading: SensorReading) -> bool:
    """True when any tyre has fallen under the minimum safe pressure."""
    return reading.tyre_pressure_bar < TYRE_PRESSURE_MIN_BAR


def summarize_sensor_alarms(readings: list[SensorReading]) -> dict[str, int]:
    """Count how many readings tripped each hardware alarm."""
    return {
        "battery": sum(1 for r in readings if battery_is_critical(r)),
        "refrigeration": sum(1 for r in readings if refrigeration_breached(r)),
        "tyre_pressure": sum(1 for r in readings if tyre_pressure_low(r)),
    }
