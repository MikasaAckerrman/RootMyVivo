#!/system/bin/sh
# ============================================================
# oneclick.sh v3 — Neo10 设备端一键 Root（GlassRoot App 版）
# 适配新套件 + 本机限制:
#   * 提权前: 所有文件只能落 /data/local/tmp (本机无法创建子目录)
#   * cheese 提权并放开 SELinux 后, 经 root 通道把二进制迁到
#     /data/local/tmp2 (device_reksu.sh 约定路径)
# 用法: sh oneclick.sh [<slide-hex>]   # slide 可选手动传入
# ============================================================
T=/data/local/tmp
T2=/data/local/tmp2
LOG=$T/cheese.log
say(){ echo "[oneclick] $*"; }
die(){ echo "[!] $*"; exit 1; }
N=0
CH=rc

# rootcmd 通道执行: cheese root daemon 读 rootcmd 执行, 输出到 rootout
# CH=direct 直接 sh; CH=su 回退 KSU su -c; CH=rc 走文件通道
RCMD() { # $1=cmd $2=超时秒(默认15)
  if [ "$CH" = "direct" ]; then
    sh -c "$1" 2>&1
    return
  fi
  if [ "$CH" = "su" ]; then
    $T/su -c "$1" 2>&1
    return
  fi
  N=$((N+1))
  rm -f $T/rootout 2>/dev/null
  echo "{ $1; echo RCMD_DONE_$N; } > $T/rootout 2>&1" > $T/rootcmd
  i=0; TO=${2:-15}
  while [ $i -lt $TO ]; do
    grep -q "RCMD_DONE_$N" $T/rootout 2>/dev/null && break
    sleep 1; i=$((i+1))
  done
  grep -v "^RCMD_DONE_" $T/rootout 2>/dev/null
}

# 定位 KSU su（insmod 带 allow_shell=1 → shell 立即可 su）。
# 注意: cheese daemon 虽然 uid=0, 但对 /data/app 写入被拒
# (日志实证: cp → Permission denied), 凡涉及 /data/app、/data/adb
# 的写操作必须经 KSU su 通道。
find_ksu_su() {
  P=$(command -v su 2>/dev/null)
  [ -n "$P" ] && { echo "$P"; return; }
  for p in /debug_ramdisk/su /system/bin/su /system/xbin/su; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  echo ""
}

have_root() {
  $T/su id 2>/dev/null | grep -q 'uid=0' && return 0
  rm -f $T/rootout 2>/dev/null
  echo 'echo RC_PROBE > /data/local/tmp/rootout' > $T/rootcmd 2>/dev/null
  sleep 3
  grep -q RC_PROBE $T/rootout 2>/dev/null && return 0
  return 1
}

# ---------- 64 位安全 hex 运算 ----------
# 本机 /system/bin/sh 算术仅 32 位, 16 位内核地址 ($((16#...))) 会被截断,
# 故 slide 解析全部改用逐 nibble 字符串运算 (getslide.sh 在本机因此不可靠)。
nib() {
  case "$1" in
    0) printf 0;; 1) printf 1;; 2) printf 2;; 3) printf 3;; 4) printf 4;;
    5) printf 5;; 6) printf 6;; 7) printf 7;; 8) printf 8;; 9) printf 9;;
    a|A) printf 10;; b|B) printf 11;; c|C) printf 12;; d|D) printf 13;;
    e|E) printf 14;; f|F) printf 15;; *) printf 0;;
  esac
}
hxb() { # 十六进制减法 $1-$2 (字符串), 结果为负输出空串
  A=$1; B=$2
  while [ ${#A} -lt ${#B} ]; do A="0$A"; done
  while [ ${#B} -lt ${#A} ]; do B="0$B"; done
  R=""; BW=0; I=$((${#A}-1))
  while [ $I -ge 0 ]; do
    CA=$(printf '%s' "$A" | cut -c$((I+1)))
    CB=$(printf '%s' "$B" | cut -c$((I+1)))
    NA=$(nib "$CA"); NB=$(nib "$CB")
    D=$((NA-NB-BW))
    if [ $D -lt 0 ]; then D=$((D+16)); BW=1; else BW=0; fi
    case $D in 10)HX=a;;11)HX=b;;12)HX=c;;13)HX=d;;14)HX=e;;15)HX=f;;*)HX=$D;;esac
    R="$HX$R"; I=$((I-1))
  done
  [ $BW -eq 1 ] && return 1
  R=$(printf '%s' "$R" | sed 's/^0*//')
  printf '%s' "${R:-0}"
}
hxa() { # 十六进制加法 $1+$2 (字符串)
  A=$1; B=$2
  while [ ${#A} -lt ${#B} ]; do A="0$A"; done
  while [ ${#B} -lt ${#A} ]; do B="0$B"; done
  R=""; CY=0; I=$((${#A}-1))
  while [ $I -ge 0 ]; do
    CA=$(printf '%s' "$A" | cut -c$((I+1)))
    CB=$(printf '%s' "$B" | cut -c$((I+1)))
    NA=$(nib "$CA"); NB=$(nib "$CB")
    D=$((NA+NB+CY))
    if [ $D -ge 16 ]; then D=$((D-16)); CY=1; else CY=0; fi
    case $D in 10)HX=a;;11)HX=b;;12)HX=c;;13)HX=d;;14)HX=e;;15)HX=f;;*)HX=$D;;esac
    R="$HX$R"; I=$((I-1))
  done
  [ $CY -eq 1 ] && R="1$R"
  R=$(printf '%s' "$R" | sed 's/^0*//')
  printf '%s' "${R:-0}"
}
resolve_slide() { # 从 cheese.log 解析 kbase(交叉投票) 再减基址得 slide, 输出纯 hex
  L=$(grep -aoE 'leak: kvo=[0-9a-f]+ it=[0-9a-f]+ rf=[0-9a-f]+ rfu=[0-9a-f]+' $LOG 2>/dev/null | tail -1)
  RFU=$(echo "$L" | sed -n 's/.*rfu=\([0-9a-f]*\).*/\1/p')
  IT=$(echo "$L" | sed -n 's/.*it=\([0-9a-f]*\).*/\1/p')
  KVO=$(echo "$L" | sed -n 's/.*kvo=\([0-9a-f]*\).*/\1/p')
  TP0=$(grep -aoE 'tp0 funcs walk fail \([0-9a-f]+\)' $LOG 2>/dev/null | tail -1 | sed -n 's/.*fail (\([0-9a-f]*\)).*/\1/p')
  VK=$(grep -aoE 'vr: kbase=[0-9a-f]+' $LOG 2>/dev/null | tail -1 | cut -d= -f2)
  CAND=""
  [ -n "$RFU" ] && [ "$RFU" != "0" ] && CAND="$CAND $(hxb $RFU 1ef70c)"
  if [ -n "$IT" ] && [ "$IT" != "0" ]; then
    IT2=$(printf '%s' "$IT" | sed 's/^0*//')
    [ -n "$IT2" ] && CAND="$CAND $(hxb $IT2 1b078)"
  fi
  [ -n "$KVO" ] && [ "$KVO" != "0" ] && CAND="$CAND $(hxa $KVO a8000000)"
  [ -n "$TP0" ] && [ "$TP0" != "0" ] && CAND="$CAND $(hxb $TP0 1ef70c)"
  [ -n "$VK" ] && [ "$VK" != "0" ] && CAND="$CAND $(hxa $VK a8000000)"
  CAND=$(echo $CAND | sed 's/^ *//')
  [ -n "$CAND" ] || return 1
  # 注意: 本函数经 $() 捕获返回值, 日志必须走 stderr, 否则污染 slide 值
  say "kbase 候选:$CAND" >&2
  BEST=""; BESTN=0
  for c in $CAND; do
    n=0; for d in $CAND; do [ "$d" = "$c" ] && n=$((n+1)); done
    if [ $n -gt $BESTN ]; then BESTN=$n; BEST=$c; fi
  done
  say "采用 KBASE=0x$BEST (votes=$BESTN, 64 位安全运算)" >&2
  hxb $BEST ffffffc008000000
}

# ---------- 阶段0: 前置（提权前文件全在 $T） ----------
say "阶段0: 前置检查"
for f in $T/cheese $T/su_bin $T/slidepatch $T/resukisu.ko.base.rsc \
         $T/resukisu.ko.base.canonical $T/device_reksu.sh; do
  [ -f "$f" ] || die "缺少: $f"
done
chmod 755 $T/cheese $T/su_bin $T/su $T/slidepatch $T/device_reksu.sh $T/getslide.sh $T/oneclick.sh 2>/dev/null
say "✔ 文件齐全"

# ---------- 阶段1: cheese 提权 ----------
if grep -q kernelsu /proc/modules 2>/dev/null; then
  say "阶段1: kernelsu 已加载, 跳过 cheese"
elif have_root; then
  say "阶段1: root 通道已存活, 跳过 cheese"
else
  say "阶段1: cheese 提权 (最多 3 次尝试, 每次≤300s)"
  pkill -9 cheese 2>/dev/null
  OK=0
  ATT=0
  while [ $ATT -lt 3 ]; do
    ATT=$((ATT+1))
    say "--- 尝试 $ATT/3 ---"
    rm -f $LOG 2>/dev/null; touch $LOG
    ( cd $T && env CHEESE_CPURW=1 CHEESE_NO_RETRY=1 CHEESE_DROP_SU=1 \
        CHEESE_ROOT_DAEMON=1 CHEESE_CPURW_VERBOSE=1 CHEESE_PATCH_VR=1 \
        CHEESE_PHYSCAN_BASE=0xa3000000 CHEESE_PHYSCAN_END=0xae000000 \
        CHEESE_PHYSCAN_STRIDE=0x1000000 \
        ./cheese > $LOG 2>&1 ) &
    CPID=$!
    # 实时把 cheese.log 增量打到本脚本 stdout → App 日志区可见 (调试期必需)
    # 轮询式(每秒新起 tail 进程)而非 tail -f: 避免后台进程管道缓冲导致日志积压
    ( OFF=0
      while :; do
        if [ -f $LOG ]; then
          SZ=$(wc -c < $LOG 2>/dev/null)
          case "$SZ" in ''|*[!0-9]*) SZ=$OFF;; esac
          if [ "$SZ" -gt "$OFF" ]; then
            tail -c +$((OFF+1)) $LOG 2>/dev/null
            OFF=$SZ
          fi
        fi
        sleep 1
      done ) &
    TAILPID=$!
    i=0
    while [ $i -lt 300 ]; do
      kill -0 $CPID 2>/dev/null || break
      sleep 2; i=$((i+2))
      if grep -qE 'final uid: 0|root daemon forked|su server ready' $LOG 2>/dev/null; then
        say "ROOTDONE 检测到 (${i}s), 提前收尾"
        sleep 2; kill $CPID 2>/dev/null
        break
      fi
    done
    kill $TAILPID 2>/dev/null; kill $CPID 2>/dev/null
    wait $CPID 2>/dev/null
    if have_root; then OK=1; say "✔ 尝试 $ATT: 提权成功"; break; fi
    say "尝试 $ATT: 未获得 root (完整日志: $LOG)"
    sleep 3
  done
  [ $OK = 1 ] || die "cheese 3 次尝试均失败, 详见 $LOG (建议重启手机后重跑; 开机后 75 秒内竞态窗口更优)"
fi

# ---------- 阶段2: root 通道确认 ----------
say "阶段2: 确认 root 通道"
if [ "$(id -u)" = "0" ]; then
  CH=direct
  say "✔ 直接 root shell"
else
  rm -f $T/rootout 2>/dev/null
  echo 'echo RCM_OK > /data/local/tmp/rootout' > $T/rootcmd 2>/dev/null
  sleep 3
  if grep -q RCM_OK $T/rootout 2>/dev/null; then
    CH=rc; say "✔ 通道: rootcmd (cheese daemon)"
  elif $T/su id 2>/dev/null | grep -q 'uid=0'; then
    CH=su; say "✔ 通道: KSU su"
  else
    die "无可用 root 通道 (rootcmd 死, su 不可用)"
  fi
fi
RCMD_ID=$(RCMD "id" 8)
echo "$RCMD_ID" | head -1 | sed 's/^/    /'
echo "$RCMD_ID" | grep -q 'uid=0' || die "root 通道验证失败"

# ---------- 阶段2.5: 创建 $T2 → 迁移二进制 ----------
# cheese 提权放开 SELinux 后, shell(本脚本身份)可写 $T2。
# tmp2 每次运行结束(阶段8)整体清空, 不留跨运行残留。
say "阶段2.5: 创建 $T2"
mkdir -p $T2 2>/dev/null || RCMD "mkdir -p $T2" >/dev/null 2>&1
if [ ! -d $T2 ]; then
  die "无法创建 $T2, 迁移中止"
fi
say "✔ $T2 就绪"
say "阶段2.5: 迁移二进制 → $T2"
# v3.2.17: 逐文件「md5 + 执行位」双校验自愈式迁移。
# 旧盲区: 上次运行残留的他人属主旧文件内容恰好一致时, md5 校验误判"迁移成功",
# 而 shell 既覆盖不了也 chmod 不动 → 阶段6 激活二进制不可用。现逐文件处置:
# 不一致/不可执行 → rm+重拷+chmod; shell 失败 → root 通道; 再失败 → 中止。
MIG_BIN="slidepatch device_reksu.sh getslide.sh libksud.orig libksud.dm"  # 需 +x
MIG_DAT="resukisu.ko.base.canonical resukisu.ko.base.rsc ksu_variant_flag"        # 仅 md5
mig_check() { # $1=文件名 $2=x则要求可执行
  A=$(md5sum "$T/$1" 2>/dev/null | cut -d' ' -f1); [ -n "$A" ] || return 1
  B=$(md5sum "$T2/$1" 2>/dev/null | cut -d' ' -f1)
  [ "$A" = "$B" ] || return 1
  [ "$2" != "x" ] || [ -x "$T2/$1" ]
}
mig_copy() { # $1=文件名: 强制重拷(先删残留, 防他人属主旧文件)
  rm -f "$T2/$1" 2>/dev/null
  cp -f "$T/$1" "$T2/$1" 2>/dev/null
  chmod 755 "$T2/$1" 2>/dev/null
}
MIG_FAIL=""
for f in $MIG_BIN $MIG_DAT; do
  case " $MIG_BIN " in *" $f "*) NX=x;; *) NX=d;; esac
  if ! mig_check "$f" "$NX"; then
    mig_copy "$f"
    if ! mig_check "$f" "$NX"; then
      say "  ⚠ $f shell 迁移失败, root 通道兜底..."
      RCMD "rm -f $T2/$f; cp -f $T/$f $T2/$f; chmod 755 $T2/$f" 30 >/dev/null 2>&1
      if ! mig_check "$f" "$NX"; then
        say "  ✗ $f 双通道迁移均失败"
        MIG_FAIL="$MIG_FAIL $f"
      fi
    fi
  fi
done
[ -z "$MIG_FAIL" ] || die "迁移到 $T2 失败:$MIG_FAIL (残留文件无法覆盖/置权), 中止"
say "✔ 迁移完成 (逐文件 md5+执行位校验通过)"

# ---------- 阶段3: slide 解析 ----------
say "阶段3: 解析 KASLR slide"
if [ -n "$1" ]; then
  SLIDE=$1
  say "slide 来自手动参数"
else
  SR=$(resolve_slide) || SR=""
  [ -n "$SR" ] && SLIDE=0x$SR
fi
[ -n "$SLIDE" ] || die "slide 解析失败: 手动传 slide 重跑: sh oneclick.sh <slide-hex>"
# 归一化: slide 必须是小偏移 (0xnnnnnn...); 若拿到 0xffffff... 形态,
# 那是 kbase (内核基址) 被误当 slide —— 自动换算: slide = kbase - 0xffffffc008000000
S2=${SLIDE#0x}
case "$S2" in
  ffffff*|ffffffff*)
    KBX=0x$S2
    # ownroot fix: было $((16#$S2 - ...)) — 32-битный sh обрезает 64-битный kbase
    S2=$(hxb "$S2" ffffffc008000000)
    [ -n "$S2" ] || die "kbase 形态值小于内核基址, 无效"
    SLIDE=0x$S2
    say "⚠ 检测到 kbase 形态值, 已换算: $KBX → 0x$SLIDE"
  ;;
esac
# ownroot fix: было [ $((16#$S2)) -ne 0 ] — 12-hex может превысить 32 бита; строковая проверка
case "$S2" in ""|0) die "slide 为零, 无效";; esac
[ ${#S2} -le 12 ] || die "slide 数值异常: 0x$S2 (超过 12 位十六进制, 疑似地址而非偏移)"
SLIDE=0x$S2
say "✔ slide=$SLIDE"

# ---------- 阶段4: KernelSU 管理器（安装源=Neo10 源码级双体管理器） ----------
# ksu-manager.apk = KernelSU v3.3.0 (versionCode 35071) 源码重编双体管理器（包名 me.weishu.kernelsu）：
#   * libksud.so = 原始体（完整超级调用）：root shell 内命令/模块安装/boot-patch 等走它
#   * libksud_safe.so = 防冻屏体（编译期禁用 SYS_reboot）：应用进程自身派生 root shell (debug su) 走它
#   * 源码级双体路由 (KsuCli.kt getKsuDaemonSafePath)，自带防冻屏，无需再修复库文件
# 已装 → md5 对比: 与 kit 不一致(官方版/旧签名版)自动卸载重装, 一致才跳过。
say "阶段4: KernelSU 管理器 (Neo10 源码级双体)"
if [ ! -f $T/ksu-manager.apk ]; then
  say "⚠ 无管理器 APK: 跳过管理器安装 (激活用 kit 内 libksud.orig)"
elif pm list packages 2>/dev/null | grep -q me.weishu.kernelsu; then
  # 已装：md5 对比已装 base.apk 与 kit 版本——不一致(旧签名/旧版本)则卸了重装
  LMD5=$(md5sum $T/ksu-manager.apk 2>/dev/null | cut -d' ' -f1)
  IPATH=$(RCMD "pm path me.weishu.kernelsu 2>/dev/null | head -1 | sed 's/package://'" 10)
  IMD5=$(RCMD "md5sum \"$IPATH\" 2>/dev/null | cut -d' ' -f1" 25)
  if [ -n "$LMD5" ] && [ "$LMD5" = "$IMD5" ]; then
    say "✔ Neo10 双体管理器已安装且与 kit 版本一致, 跳过"
  else
    say "已装管理器与 kit 版本不一致 (md5 ${IMD5:-未知} != $LMD5), 卸载后重装..."
    OUT=$(RCMD "pm uninstall me.weishu.kernelsu; pm install -r $T/ksu-manager.apk" 150)
    echo "$OUT" | tail -3 | sed 's/^/    /'
    if echo "$OUT" | grep -q Success; then
      say "✔ Neo10 双体管理器重装成功"
    else
      say "⚠ 重装未成功: 请手动卸载旧管理器后安装 $T/ksu-manager.apk (不影响 root 流程)"
    fi
  fi
else
  say "未安装管理器, 经 root 通道自动安装 Neo10 双体版 (约 10-60s)..."
  OUT=$(RCMD "pm install -r $T/ksu-manager.apk" 120)
  echo "$OUT" | tail -3 | sed 's/^/    /'
  if echo "$OUT" | grep -q Success; then
    say "✔ Neo10 双体管理器自动安装成功"
  else
    say "⚠ 自动安装未成功: 可手动安装 $T/ksu-manager.apk (不影响 root 流程)"
  fi
fi

# ---------- 阶段5: slidepatch + insmod (变体轮换 ≤4) ----------
if grep -q kernelsu /proc/modules 2>/dev/null; then
  say "阶段5: 模块已加载, 跳过"
  LOADED=1
else
  say "阶段5: 加载 KernelSU 模块 (变体自动轮换)"
  LOADED=0
  VATT=0
  SLIDEHEX=${SLIDE#0x}
  say "传给 slidepatch 的 slide = $SLIDE (小偏移格式)"
  while [ $VATT -lt 4 ]; do
    VATT=$((VATT+1))
    VAR=$(cat $T/ksu_variant_flag 2>/dev/null)
    say "--- insmod 轮次 $VATT (variant=${VAR:-rsc}) ---"
    OUT=$(RCMD "sh $T2/device_reksu.sh $SLIDEHEX" 30)
    echo "$OUT" | sed 's/^/    /'
    if echo "$OUT" | grep -q MODULE_LOADED || grep -q kernelsu /proc/modules 2>/dev/null; then
      LOADED=1; break
    fi
    case "$VAR" in
      canonical) NEXT=rsc;; *) NEXT=canonical;;
    esac
    echo $NEXT > $T/ksu_variant_flag 2>/dev/null
    echo $NEXT > $T2/ksu_variant_flag 2>/dev/null
    say "变体轮换 → $NEXT"
    sleep 2
  done
  [ $LOADED = 1 ] || die "insmod 失败 (两种变体各试过多轮; 检查 slide 是否正确)"
fi

# ---------- 阶段6: 激活 ----------
say "阶段6: 激活 (libksud.orig post-fs-data/boot-completed)"
# v3.2.18: 阶段5 模块加载成功后统一走 KSU su (内核 root) 通道——
# cheese daemon 对 /data/app、/data/adb 写入被拒, RCMD 激活通道淘汰。
# v3.2.21: 执行位相关动作全部收进 KSU su 调用内部。原因(本机日志实证):
# 模块加载后 shell 对 tmp2 的访问被收回(0827 日志: 阶段2.5 shell cp/chmod
# 成功, insmod 后同样操作全部失败)。脚本以 app shell 身份跑的 [ -x ]
# (access(2), 受 SELinux 管) 既查错主体(真正执行的是 KSU su), 又会在
# 访问权被收回后误报失败。故: chmod 固定权限 + 执行位校验 + 执行,
# 在同一个 KSU su 调用里以执行者身份完成; 不可执行时输出 ERR_NOEXEC。
KSU_SU=$(find_ksu_su)
[ -n "$KSU_SU" ] || die "模块已加载但未找到 KSU su: 激活/注册无法执行"
KSUD_ORIG=$T2/libksud.orig
say "激活: $KSU_SU → $KSUD_ORIG (看门狗 60s)"
rm -f $T/suact 2>/dev/null
( "$KSU_SU" -c "chmod 755 $KSUD_ORIG 2>/dev/null; [ -x $KSUD_ORIG ] || { echo ERR_NOEXEC; exit 9; }; $KSUD_ORIG post-fs-data; $KSUD_ORIG boot-completed" > $T/suact 2>&1 ) &
SUI=$!
WI=0
while [ $WI -lt 60 ]; do kill -0 $SUI 2>/dev/null || break; sleep 1; WI=$((WI+1)); done
if kill -0 $SUI 2>/dev/null; then
  kill -9 $SUI 2>/dev/null; wait $SUI 2>/dev/null
  say "⚠ 激活超时(60s) 已强杀: 激活状态以重启后为准"
else
  wait $SUI 2>/dev/null
fi
ACT=$(cat $T/suact 2>/dev/null); rm -f $T/suact 2>/dev/null
if echo "$ACT" | grep -q ERR_NOEXEC; then
  die "激活失败: $KSUD_ORIG 在 KSU su 身份下仍不可执行"
fi
[ -n "$ACT" ] && echo "$ACT" | tail -5 | sed 's/^/    /'
say "✔ 激活完成"

# ---------- 阶段6.5: 动态管理器注册（让内核认识 Neo10 双体管理器） ----------
# 内核按 APK 签名 sha256 认管理器（内置白名单只有各家官方签名），
# Neo10 双体管理器用自定义 release key (key.jks) 签名(b6d21941…) 不在白名单 → 管理器显示"未工作"。
# `ksud dynamic-manager set-apk` 从 APK 提取签名 supercall 注册给内核，
# 持久化 /data/adb/ksu/.dynamic_manager，内核随即 track_throne 定位已装的双体管理器。
# 注意: 动态管理器命令只有 ReSukiSU fork 的 ksud 支持（KernelSU 3.3.0 上游无此命令），
#       故注册专用 $KSUD_DM=libksud.dm（原 kit libksud.orig 存档）；激活仍用新版 libksud.orig。
# 管理器 APK 必须是纯 v2 签名——内核拒绝 v1(扫 META-INF/MANIFEST.MF) 也拒绝 v3/v3.1。
say "阶段6.5: 注册动态管理器签名"
if [ -f $T/ksu-manager.apk ] && [ -f $T2/libksud.dm ]; then
  KSU_SU=$(find_ksu_su)
  KSUD_DM=$T2/libksud.dm
  DMRC=1; DMOUT=""
  if [ -n "$KSU_SU" ]; then
    rm -f $T/dmout 2>/dev/null
    ( "$KSU_SU" -c "$KSUD_DM kernel dynamic-manager set-apk $T/ksu-manager.apk" > $T/dmout 2>&1 ) &
    DPI=$!
    WI=0
    while [ $WI -lt 45 ]; do kill -0 $DPI 2>/dev/null || break; sleep 1; WI=$((WI+1)); done
    if kill -0 $DPI 2>/dev/null; then
      kill -9 $DPI 2>/dev/null; wait $DPI 2>/dev/null
      DMRC=124; DMOUT="timeout(45s)"
    else
      wait $DPI 2>/dev/null; DMRC=$?
      DMOUT=$(cat $T/dmout 2>/dev/null)
    fi
    rm -f $T/dmout 2>/dev/null
  else
    DMOUT="KSU su 未找到 (阶段5 之后应当存在)"; DMRC=125
  fi
  [ -n "$DMOUT" ] && echo "$DMOUT" | tail -3 | sed 's/^/    /'
  if [ $DMRC -eq 0 ]; then
    say "✔ 动态管理器已注册 (期望: size=0x2e8, sha256=b6d21941…) — 重开管理器应显示'工作中'"
  else
    say "⚠ 动态管理器注册失败 rc=$DMRC: Neo10 双体管理器可能仍显示'未工作' (官方管理器不受影响)"
  fi
else
  say "⚠ $T/ksu-manager.apk 或 $T2/libksud.dm 不存在, 跳过动态管理器注册"
fi

# ---------- 阶段6.6: 内核日志诊断 (加冕是否成功) ----------
# 诊断用开关: 1=抓 KernelSU 内核日志定位加冕链, 0=关闭(日常使用)
ENABLE_KLOG_DIAG=0
if [ "$ENABLE_KLOG_DIAG" = "0" ]; then
  say "阶段6.6: 内核日志诊断 (已关闭)"
else
# 关键日志: "dynamic manager updated" / "Searching for manager(s)..." /
#          "sha256: ..." (内核解析每个候选 APK 证书) / "Crowning manager: <pkg> uid=X"
say "阶段6.6: 内核日志诊断"
KSU_SU=$(find_ksu_su)
KLOG=""
if [ -n "$KSU_SU" ]; then
  rm -f $T/klog 2>/dev/null
  ( "$KSU_SU" -c "dmesg 2>/dev/null | grep -a 'KernelSU' | tail -50" > $T/klog 2>&1 ) &
  KPI=$!
  WI=0
  while [ $WI -lt 20 ]; do kill -0 $KPI 2>/dev/null || break; sleep 1; WI=$((WI+1)); done
  if kill -0 $KPI 2>/dev/null; then
    kill -9 $KPI 2>/dev/null; wait $KPI 2>/dev/null
  else
    wait $KPI 2>/dev/null
  fi
  KLOG=$(cat $T/klog 2>/dev/null); rm -f $T/klog 2>/dev/null
fi
if [ -n "$KLOG" ]; then
  echo "$KLOG" | sed 's/^/    /'
  echo "$KLOG" | grep -q "Crowning manager" && say "✔ 内核已加冕管理器" || say "⚠ 未见 'Crowning manager' — 签名未匹配或搜索未命中 (上面是完整内核侧记录)"
else
  say "⚠ 未能读取内核日志 (dmesg 受限), 跳过诊断"
fi
fi

# ---------- 阶段7: 校验 ----------
say "阶段7: 状态校验 (KSU su 通道)"
rm -f $T/vout 2>/dev/null
( "$KSU_SU" -c "id; echo ---; grep kernelsu /proc/modules; echo ---; getenforce" > $T/vout 2>&1 ) &
VPI=$!
WI=0
while [ $WI -lt 20 ]; do kill -0 $VPI 2>/dev/null || break; sleep 1; WI=$((WI+1)); done
if kill -0 $VPI 2>/dev/null; then
  kill -9 $VPI 2>/dev/null; wait $VPI 2>/dev/null
  say "⚠ 校验命令超时(20s)"
else
  wait $VPI 2>/dev/null
fi
cat $T/vout 2>/dev/null | sed 's/^/    /'; rm -f $T/vout 2>/dev/null
if grep -q kernelsu /proc/modules 2>/dev/null; then
  say "🎉 kernelsu 已加载 — 打开 KernelSU 管理器应显示'工作中'"
else
  say "⚠ /proc/modules 未见 kernelsu (若刚 insmod 成功, 重启后再看)"
fi
# ---------- 阶段8: 清理现场（$T 与 $T2 全清, 同步执行） ----------
# v3.2.19: 改同步清理。旧版 "( sleep 3; rm ) &" 后台延迟清理从未生效——
# 脚本打印 ALL-DONE 即退出, App 侧随即结束会话, 孤儿子进程轮不到执行 rm。
# 另: $T/su 等文件由 cheese 以 root 落下且 /data/local/tmp 带 sticky 位,
# shell 身份删不掉 → KSU su (root) 收尾扫尾。运行中删除自身脚本在 Unix 无害。
say "阶段8: 清理部署痕迹 ($T 与 $T2)"
CLEAN_T="$T/cheese $T/cheese.log $T/su $T/su_bin $T/slidepatch \
$T/resukisu.ko.base.canonical $T/resukisu.ko.base.rsc \
$T/libksud.orig $T/libksud.dm $T/device_reksu.sh $T/getslide.sh \
$T/ksu_variant_flag $T/ksu-manager.apk \
$T/rootcmd $T/rootout $T/dmout $T/suact $T/klog $T/vout $T/oneclick.sh"
rm -f $CLEAN_T 2>/dev/null
rm -rf $T2 2>/dev/null
if [ -n "$KSU_SU" ]; then
  # v3.2.21: root 收尾 + 残留自检都在 KSU su 身份里做——模块加载后
  # shell 对 tmp2 连 stat 都可能被拒, shell 身份的 [ -d ] 自检会误报已清空。
  rm -f $T/clean.out 2>/dev/null
  ( "$KSU_SU" -c "rm -f $CLEAN_T 2>/dev/null; rm -rf $T2 2>/dev/null; [ -d $T2 ] && { echo T2_LEFT:; ls $T2; }; true" > $T/clean.out 2>&1 ) &
  CPI=$!
  WI=0
  while [ $WI -lt 15 ]; do kill -0 $CPI 2>/dev/null || break; sleep 1; WI=$((WI+1)); done
  if kill -0 $CPI 2>/dev/null; then
    kill -9 $CPI 2>/dev/null; wait $CPI 2>/dev/null
    say "⚠ root 收尾清理超时(15s)"
  else
    wait $CPI 2>/dev/null
  fi
  CLEANOUT=$(cat $T/clean.out 2>/dev/null); rm -f $T/clean.out 2>/dev/null
  if echo "$CLEANOUT" | grep -q T2_LEFT; then
    say "⚠ $T2 仍有残留: $(echo "$CLEANOUT" | grep -v '^T2_LEFT:' | tr '\n' ' ')"
  else
    say "✔ $T2 已清空"
  fi
else
  [ -d $T2 ] && say "⚠ KSU su 不可用, $T2 清理未验证" || say "✔ $T2 已清空"
fi
say "✔ 清理完成"
echo "ALL-DONE"
