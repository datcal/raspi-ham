#!/usr/bin/env python3
"""
GPIO button daemon for raspi-ham WiFi switching.
Button A (GPIO17): switch to iPhone hotspot
Button B (GPIO27): switch to home WiFi
LED 1 (GPIO5): green - hotspot active
LED 2 (GPIO6): blue - home wifi active
"""

import subprocess
import sys
import logging
from signal import pause

from gpiozero import Button, LED

BUTTON_A_PIN = 17  # hotspot
BUTTON_B_PIN = 27  # home wifi
LED_A_PIN = 5      # green
LED_B_PIN = 6      # blue

BOUNCE_TIME = 0.3  # 300ms software debounce (hardware RC filter handles the rest)
HOLD_TIME = 1.0    # hold 1 second to trigger - prevents accidental switches

HOTSPOT_CONN = "raspi-ham-hotspot"
HOME_CONN = "raspi-ham-home"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("wifi-switch")

led_a = LED(LED_A_PIN)
led_b = LED(LED_B_PIN)
button_a = Button(BUTTON_A_PIN, bounce_time=BOUNCE_TIME, hold_time=HOLD_TIME)
button_b = Button(BUTTON_B_PIN, bounce_time=BOUNCE_TIME, hold_time=HOLD_TIME)


def blink_error(led):
    """3 slow blinks = something went wrong."""
    for _ in range(3):
        led.on()
        subprocess.run(["sleep", "0.5"])
        led.off()
        subprocess.run(["sleep", "0.5"])


def switch_wifi(connection_name, active_led, other_led):
    """Switch to a NetworkManager connection profile."""
    log.info("switching to: %s", connection_name)
    other_led.off()
    active_led.blink(on_time=0.1, off_time=0.1)  # fast blink = working

    try:
        # disconnect current wifi first
        subprocess.run(
            ["nmcli", "connection", "down", HOTSPOT_CONN],
            capture_output=True,
            timeout=10,
        )
        subprocess.run(
            ["nmcli", "connection", "down", HOME_CONN],
            capture_output=True,
            timeout=10,
        )

        # connect to target
        result = subprocess.run(
            ["nmcli", "connection", "up", connection_name],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode == 0:
            log.info("connected to %s", connection_name)
            active_led.on()  # solid = connected
        else:
            log.error("failed: %s", result.stderr.strip())
            active_led.off()
            blink_error(active_led)

    except subprocess.TimeoutExpired:
        log.error("wifi switch timed out")
        active_led.off()
        blink_error(active_led)
    except Exception as e:
        log.error("unexpected error: %s", e)
        active_led.off()
        blink_error(active_led)


def on_button_a():
    switch_wifi(HOTSPOT_CONN, led_a, led_b)


def on_button_b():
    switch_wifi(HOME_CONN, led_b, led_a)


# hold to trigger (not just press) - deliberate action required
button_a.when_held = on_button_a
button_b.when_held = on_button_b

# startup: both LEDs blink twice
log.info("wifi-switch daemon started, waiting for buttons...")
for led in (led_a, led_b):
    led.blink(on_time=0.3, off_time=0.3, n=2)

pause()
