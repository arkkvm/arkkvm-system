#!/bin/sh

#backlight
echo 255 > /sys/class/backlight/backlight/brightness

#GPIO3_A5  out
echo 101 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio101/direction
echo 1 > /sys/class/gpio/gpio101/value

#app demo start
lvgl_demo_latest &
#eth_check_fb 192.168.1.1 &
