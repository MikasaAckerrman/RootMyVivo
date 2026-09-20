#!/system/bin/sh
# device_reksu.sh v2.1 — neo10 ReSukiSU 设备端加载器（以 root/daemon 执行）
# 职责: slide 解析 → slidepatch 偏移修补 → insmod 加载 KernelSU LKM;
#       ONLY_LIBKSUD=1 时仅修复管理器 libksud.so(设置页"修复"按钮调用)。
# v2 变更:
#   1) slide 来源改为 cheese leak 行(kvo+0xA8000000)，不再用 kbaseleak(perf 在 neo10 不可用)
#      优先: $1 参数(十六进制 slide) > /data/local/tmp/cheese.log 的 leak: kvo=
#   2) 全部路径改用 /data/local/tmp2 (/data/local/tmp 会被 vivo 锁)
#   3) 新增 LIBKSUD=1 时执行 libksud.so 备份+替换(防管理器卡死)
#   4) 新增 LOAD_COUNT=1 时仅走 insmod(模块已 patch 时)
# v2.1 变更: 删除 ksud-orig 副本创建(已无消费者)与无人调用的 SLIDE_ENV 分支

# --- 0. ensure tmp2 (root-only dir; idempotent) ---
mkdir -p /data/local/tmp2 2>/dev/null

# ownroot fix: 64-битная арифметика строками (v2.1 использовал $((16#..)) —
# на vivo /system/bin/sh 32-бит и обрезал 64-битные адреса в fallback-пути)
SCRIPT_DIR=$(dirname "$0")
[ -f "$SCRIPT_DIR/nibblemath.sh" ] && . "$SCRIPT_DIR/nibblemath.sh"

# --- 0.5 ONLY_LIBKSUD=1: 仅做管理器 libksud.so 修复（跳过 slide/insmod） ---
if [ "$ONLY_LIBKSUD" = "1" ]; then
  LIBKSUD=1
  SKIP_INSMOD=1
fi
[ "$SKIP_INSMOD" = "1" ] || SKIP_INSMOD=0

# --- 1. resolve slide ---
SLIDE=""
if [ "$SKIP_INSMOD" = "1" ]; then
  SLIDE=skip
elif [ -n "$1" ]; then
  SLIDE=$1
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
[ "$SLIDE" = "skip" ] || echo "SLIDE=0x$SLIDE"

# --- 2. variant ---
VAR=$(cat /data/local/tmp/ksu_variant_flag 2>/dev/null)
BASE=resukisu.ko.base.rsc
[ "$VAR" = "canonical" ] && BASE=resukisu.ko.base.canonical
echo "VARIANT=${VAR:-rsc}"

# --- 3. patch + insmod ---
if [ "$SKIP_INSMOD" != "1" ]; then
  cd /data/local/tmp2 || exit 5
  echo "BASE=$BASE BASE_MD5=$(md5sum /data/local/tmp2/$BASE 2>/dev/null | cut -d' ' -f1)"
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
fi

# --- 4. optional: 校验双体管理器内置防冻屏库 (LIBKSUD=1) ---
# Neo10 双体管理器 (me.weishu.kernelsu) 源码级内置防冻屏：
#   libksud.so = 原始体（完整超级调用，root shell 命令走它）
#   libksud_safe.so = 防冻屏体（编译期禁用 SYS_reboot，应用进程派生 debug su 走它）
# 无需再替换库文件——此模式仅校验双体是否就位（兼容旧入口调用）。
if [ "$LIBKSUD" = "1" ]; then
  LIBDIR=$(ls -d /data/app/~~*/me.weishu.kernelsu-*/lib/arm64 2>/dev/null | head -1)
  if [ -z "$LIBDIR" ]; then
    APKP=$(pm path me.weishu.kernelsu 2>/dev/null | head -1 | sed 's/^package://')
    [ -n "$APKP" ] && LIBDIR=$(dirname "$APKP")/lib/arm64 2>/dev/null
    [ -n "$LIBDIR" ] && echo "LIBDIR_VIA_PM=$LIBDIR"
  fi
  if [ -z "$LIBDIR" ] || [ ! -d "$LIBDIR" ]; then
    echo "LIBKSUD_NO_APP (Neo10 双体管理器未安装或 lib 目录不存在)"
  else
    echo "LIBDIR=$LIBDIR"
    ls -l "$LIBDIR/libksud.so" "$LIBDIR/libksud_safe.so" 2>&1 | head -4
    if [ -f "$LIBDIR/libksud.so" ] && [ -f "$LIBDIR/libksud_safe.so" ]; then
      echo "LIBKSUD_SAFE_BUILTIN (防冻屏体已内置, 源码级路由, 无需替换)"
      echo "LIBKSUD_VERIFIED"
    else
      echo "LIBKSUD_NO_SAFE (已装管理器缺少内置防冻屏体, 请安装 kit 内 ksu-manager.apk)"
    fi
  fi
fi
# made by tadaki
