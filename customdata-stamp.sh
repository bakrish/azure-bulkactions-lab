#!/bin/bash
# Minimal CustomData: stamp the exact instant cloud-init hands control to
# user-data (the scripts-user module in cloud-final). Read back by
# measure-provisioning.ps1 as the "workload can start" anchor.
# Pass this to ANY provisioning method, e.g.:
#   az vm create ... --custom-data @customdata-stamp.sh
date +%s.%N > /var/lib/customdata-start.stamp
