#!/bin/bash

find /var/log/ -type f -name "*.gz" -delete

echo "Done. All .gz files under /var/log/ have been deleted."
