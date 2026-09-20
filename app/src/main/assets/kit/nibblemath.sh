#!/system/bin/sh
# nibblemath.sh — 64-битная hex-арифметика строками (nibble за nibble).
# Причина: /system/bin/sh на vivo — 32-битная арифметика, $((16#<16hexdigits>))
# обрезается. Все kit-скрипты source-ят эту библиотеку.
# Портировано из oneclick.sh v3 (проверенная реализация tadaki).

nib() {
  case "$1" in
    0) printf 0;; 1) printf 1;; 2) printf 2;; 3) printf 3;; 4) printf 4;;
    5) printf 5;; 6) printf 6;; 7) printf 7;; 8) printf 8;; 9) printf 9;;
    a|A) printf 10;; b|B) printf 11;; c|C) printf 12;; d|D) printf 13;;
    e|E) printf 14;; f|F) printf 15;; *) printf 0;;
  esac
}

# hxb A B — hex-вычитание A−B строками; при отрицательном результате возвращает 1 и пусто
hxb() {
  A=$1; B=$2
  [ -n "$A" ] || return 1
  [ -n "$B" ] || return 1
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

# hxa A B — hex-сложение A+B строками
hxa() {
  A=$1; B=$2
  [ -n "$A" ] || A=0
  [ -n "$B" ] || B=0
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

# hxmod2m A — проверка A mod 0x200000 (2^21) == 0; выравнивание 2MB
# 2^21: младшие 21 бит = 0 → последние 5 hex-цифр «00000» И 6-я с конца ЧЁТНАЯ
hxmod2m() {
  A=$1
  [ -n "$A" ] || return 1
  A=$(printf '%s' "$A" | tr 'A-F' 'a-f')
  L5=$(printf '%s' "$A" | tail -c 5)
  [ "$L5" = "00000" ] || return 1
  D6=$(printf '%s' "$A" | tail -c 6 | cut -c 1)
  case "$D6" in
    0|2|4|6|8|a|c|e) return 0;;
    *) return 1;;
  esac
}
