#!/bin/bash
# EC2 user data, serves a page saying which instance answered
mkdir -p /srv/www
echo "<h1>lab05 $(hostname -s)</h1>" > /srv/www/index.html
cd /srv/www && nohup python3 -m http.server 80 >/dev/null 2>&1 &
