#!/bin/bash
# check_display.sh — Investigate display configuration in the registry
set -euo pipefail

RAW="/workspace/cdrive_disp.raw"
START_SECTOR=63
OFFSET=$((START_SECTOR * 512))

LOOP=$(losetup --find --show --offset $OFFSET "$RAW")
mkdir -p /mnt/win2k
ntfsfix $LOOP >/dev/null 2>&1 || true
ntfs-3g $LOOP /mnt/win2k

HIVE=$(find /mnt/win2k -path "*/system32/config/system" -o -path "*/System32/config/system" 2>/dev/null | head -1)
echo "SYSTEM hive: $HIVE"

CURRENT=$(hivexget "$HIVE" "Select" Current 2>/dev/null)
CS="ControlSet00${CURRENT}"
echo "Active ControlSet: $CS"

echo ""
echo "=== Display-related Services ==="
for svc in VgaSave vga cirrus S3Inc s3 s3virge "vpc-s3"; do
    START=$(hivexget "$HIVE" "${CS}\\Services\\${svc}" Start 2>/dev/null || echo "NOT_FOUND")
    TYPE=$(hivexget "$HIVE" "${CS}\\Services\\${svc}" Type 2>/dev/null || echo "")
    echo "  ${svc}: Start=${START} Type=${TYPE}"
done

DISP_GUID="{4D36E968-E325-11CE-BFC1-08002BE10318}"

echo ""
echo "=== Display class root ==="
printf "cd ${CS}\\\\Control\\\\Class\\\\${DISP_GUID}\nls\nlsval\n" | hivexsh "$HIVE" 2>&1 | head -20

echo ""
echo "=== Display class 0000 (primary adapter) ==="
printf "cd ${CS}\\\\Control\\\\Class\\\\${DISP_GUID}\\\\0000\nlsval\n" | hivexsh "$HIVE" 2>&1 | head -30

echo ""
echo "=== VPC/S3 driver files ==="
find /mnt/win2k -iname "*vpc*s3*" 2>/dev/null || echo "  none"
find /mnt/win2k -iname "s3*.sys" -path "*/drivers/*" 2>/dev/null || echo "  none"
find /mnt/win2k -iname "s3*.dll" -path "*/system32/*" 2>/dev/null || echo "  none"

echo ""
echo "=== Winlogon settings ==="
SWIVE=$(find /mnt/win2k -path "*/system32/config/software" -o -path "*/System32/config/SOFTWARE" 2>/dev/null | head -1)
echo "SOFTWARE hive: $SWIVE"
hivexget "$SWIVE" 'Microsoft\Windows NT\CurrentVersion\Winlogon' DefaultUserName 2>/dev/null || echo "  No DefaultUserName"
hivexget "$SWIVE" 'Microsoft\Windows NT\CurrentVersion\Winlogon' AutoAdminLogon 2>/dev/null || echo "  No AutoAdminLogon" 

umount /mnt/win2k 2>/dev/null || umount -l /mnt/win2k 2>/dev/null || true
losetup -d $LOOP 2>/dev/null || true
