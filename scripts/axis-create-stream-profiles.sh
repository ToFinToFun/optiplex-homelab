#!/bin/bash
# Skript för att automatiskt skapa 'main' och 'detect' profiler på Axis-kameror
# Kräver att curl och jq är installerat.

if [ "$#" -ne 3 ]; then
    echo "Användning: $0 <kamera-ip> <användarnamn> <lösenord>"
    exit 1
fi

CAMERA_IP=$1
USERNAME=$2
PASSWORD=$3

# API-endpoint för parametrar
API_URL="http://${CAMERA_IP}/axis-cgi/param.cgi"

echo "Skapar profiler på ${CAMERA_IP}..."

# Skapa 'main' profil (hög upplösning, 15 fps)
curl -s -u "${USERNAME}:${PASSWORD}" --anyauth \
  -d "action=add&group=StreamProfile.main" \
  "${API_URL}" > /dev/null

curl -s -u "${USERNAME}:${PASSWORD}" --anyauth \
  -d "action=update&StreamProfile.main.Description=Main Stream&StreamProfile.main.Parameters=resolution=1920x1080&fps=15&compression=30&videocodec=h264" \
  "${API_URL}" > /dev/null

# Skapa 'detect' profil (låg upplösning, 5 fps för AI)
curl -s -u "${USERNAME}:${PASSWORD}" --anyauth \
  -d "action=add&group=StreamProfile.detect" \
  "${API_URL}" > /dev/null

curl -s -u "${USERNAME}:${PASSWORD}" --anyauth \
  -d "action=update&StreamProfile.detect.Description=Detect Stream&StreamProfile.detect.Parameters=resolution=640x480&fps=5&compression=30&videocodec=h264" \
  "${API_URL}" > /dev/null

echo "Klart! Kontrollera i kamerans webbgränssnitt under Video -> Stream Profiles."
