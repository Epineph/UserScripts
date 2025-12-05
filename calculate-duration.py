#!/usr/bin/env python3
import datetime
import sys
import time
import math
def convert_to_preferred_format(sec):
  sec = sec % (24 * 3600)
  hour = sec // 3600
  sec %= 3600
  min = sec // 60
  sec %= 60
  print("seconds value in hours:",hour)
  print("seconds value in minutes:",min)
  return "%02d:%02d:%02d" % (hour, min, sec)
n = 21178
time_format = str(datetime.timedelta(seconds = n))
print("Time in preferred format :-",time_format)
