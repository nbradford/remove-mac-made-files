read -p "Enter the volume path (e.g., /Volumes/SD_CARD): " VOLUME_PATH

sudo mdutil -X "$VOLUME_PATH"
sudo find "$VOLUME_PATH" \( -name "._*" -o -iname ".DS_Store" \) -type f -delete
echo "Mac-made files have been removed from $VOLUME_PATH."