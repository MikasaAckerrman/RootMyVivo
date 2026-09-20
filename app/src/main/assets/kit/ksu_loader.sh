#!/system/bin/sh
# ksu_loader.sh v3 — neo10 ReSukiSU 设备端载入器(以 root/daemon 运行)
# v3 变更:
#   1) slide 改从 cheese leak 行取(kvo+0xA8000000), 弃用 kbaseleak(perf 在 neo10 不可用)
#      优先级: $1 参数(hex slide) > env SLIDE > /data/local/tmp/cheese.log 的 leak: kvo=
#   2) 路径一律改用 /data/local/tmp2 (/data/local/tmp 被 vivo 锁)
#   3) 新增 LIBKSUD=1 时执行 libksud.so 备份+替换(防管理器卡死)
#   4) 新增 LOAD_COUNT=1 时仅做 insmod(模块已 patch 时)

# --- 0. 确保 tmp2 (root 专属, 幂等) ---
mkdir -p /data/local/tmp2 2>/dev/null

# ownroot fix: 64-битная арифметика строками (см. nibblemath.sh; v3 использовал
# $((16#..)) — на vivo 32-бит sh обрезает 64-битные адреса)
SCRIPT_DIR=$(dirname "$0")
[ -f "$SCRIPT_DIR/nibblemath.sh" ] && . "$SCRIPT_DIR/nibblemath.sh"

# --- 1. 求解 slide ---
SLIDE=""
if [ -n "$1" ]; then
  SLIDE=$1
elif [ -n "$SLIDE_ENV" ]; then
  SLIDE=$SLIDE_ENV
else
  L=$(grep -aoE 'leak: kvo=[0-9a-f]+ it=[0-9a-f]+ rf=[0-9a-f]+ rfu=[0-9a-f]+' /data/local/tmp/cheese.log 2>/dev/null | tail -1)
  RFU=$(echo "$L" | sed -n 's/.*rfu=\([0-9a-f]*\).*/\1/p')
  IT=$(echo "$L" | sed -n 's/.*it=\([0-9a-f]*\).*/\1/p')
  KVO=$(echo "$L" | sed -n 's/.*kvo=\([0-9a-f]*\).*/\1/p')
  KB=""
  case "$RFU" in ""|0*) ;; *) KB=$(hxb "$RFU" 1ef70c);; esac
  if [ -z "$KB" ]; then
    case "$IT" in ""|0*) ;; *) ITT=$(echo "$IT" | sed 's/^0*//'); [ -n "$ITT" ] && KB=$(hxb "$ITT" 1b078);; esac
  fi
  if [ -z "$KB" ] && [ -n "$KVO" ] && [ "$KVO" != "0" ]; then
    KB=$(hxa "$KVO" a8000000)
  fi
  if [ -n "$KB" ]; then
    SLIDE=$(hxb "$KB" ffffffc008000000)
    case "$SLIDE" in ""|0|0000000000000000) SLIDE="";; esac
  fi
fi
if [ -z "$SLIDE" ]; then
  echo "NO_SLIDE"
  exit 3
fi
echo "SLIDE=0x$SLIDE"

# --- 2. 选择变体 ---
VAR=$(cat /data/local/tmp/ksu_variant_flag 2>/dev/null)
BASE=resukisu.ko.base.rsc
[ "$VAR" = "canonical" ] && BASE=resukisu.ko.base.canonical
echo "VARIANT=${VAR:-rsc}"

# --- 3. 打补丁 + 装载 ---
cd /data/local/tmp2 || exit 5
/data/local/tmp2/slidepatch "$SLIDE" "/data/local/tmp2/$BASE" /data/local/tmp2/resukisu_patched.ko
SP_RC=$?
echo "SLIDEPATCH_RC=$SP_RC"
[ $SP_RC -ne 0 ] && { echo "PATCH_FAIL"; exit 4; }
insmod /data/local/tmp2/resukisu_patched.ko allow_shell=1 2>&1
INS_RC=$?
echo "INS_RC=$INS_RC"
if [ $INS_RC -eq 0 ] || grep -q kernelsu /proc/modules 2>/dev/null; then
  echo "MODULE_LOADED"
fi

# --- 4. 可选: libksud.so 备份 + 替换 (LIBKSUD=1) ---
if [ "$LIBKSUD" = "1" ]; then
  LIBDIR=$(ls -d /data/app/~~/com.resukisu.resukisu-*/lib/arm64 2>/dev/null | head -1)
  if [ -n "$LIBDIR" ] && [ -f "/data/local/tmp2/libksud.so.patched" ]; then
    [ -f "$LIBDIR/libksud.so.bak-20260815-probe" ] || cp "$LIBDIR/libksud.so" "$LIBDIR/libksud.so.bak-20260815-probe"
    [ -f /data/local/tmp/ksud-orig ] || cp "$LIBDIR/libksud.so" /data/local/tmp/ksud-orig
    cp /data/local/tmp2/libksud.so.patched "$LIBDIR/libksud.so"
    chmod 755 "$LIBDIR/libksud.so" /data/local/tmp/ksud-orig
    echo "LIBKSUD_REPLACED"
  else
    echo "LIBKSUD_SKIP"
  fi
fi
# made by tadaki