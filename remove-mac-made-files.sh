read -p "Enter the volume path (e.g., /Volumes/SD_CARD): " VOLUME_PATH

sudo mdutil -X "$VOLUME_PATH"
sudo find "$VOLUME_PATH" -name "._*" -type f -delete