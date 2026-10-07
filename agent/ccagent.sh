#!/usr/bin/env bash
# ccagent sampler: appends one JSON line per sample to $DIR/metrics.jsonl.
# Builtins only, except an optional nvidia-smi call.
umask 077
CONF=${CCAGENT_CONF:-/etc/ccagent.conf}
INTERVAL=5; DIR=/var/lib/ccagent; MAX_BYTES=5242880
[ -r "$CONF" ] && . "$CONF"
LOG=$DIR/metrics.jsonl
mkdir -p "$DIR"

jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# ---- static info ----
cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
threads=$(grep -c '^processor' /proc/cpuinfo)
cores=$(grep -m1 'cpu cores' /proc/cpuinfo | awk '{print $4}'); : "${cores:=$threads}"
base_mhz=null; boost_mhz=null
cf=/sys/devices/system/cpu/cpu0/cpufreq
[ -r $cf/cpuinfo_max_freq ] && boost_mhz=$(( $(< $cf/cpuinfo_max_freq) / 1000 ))
[ -r $cf/base_frequency ] && base_mhz=$(( $(< $cf/base_frequency) / 1000 ))

# ---- GPU discovery ----
GPU_KIND=none; GPU_DIR=; gpu_model=; vram_total=null; GPU_HWMON=
for d in /sys/class/drm/card[0-9]*/device; do
  if [ -r "$d/gpu_busy_percent" ]; then
    GPU_KIND=amd; GPU_DIR=$d
    for h in "$d"/hwmon/hwmon*; do [ -d "$h" ] && GPU_HWMON=$h && break; done
    [ -r "$d/mem_info_vram_total" ] && vram_total=$(( $(< "$d/mem_info_vram_total") / 1048576 ))
    gpu_model=$(cat "$d/product_name" 2>/dev/null)
    if [ -z "$gpu_model" ] && command -v lspci >/dev/null; then
      gpu_model=$(lspci -s "$(basename "$(readlink -f "$d")")" 2>/dev/null | sed 's/^[^ ]* [^:]*: //')
    fi
    [ -z "$gpu_model" ] && gpu_model="AMD GPU ($(< "$d/device"))"
    break
  fi
done
if [ $GPU_KIND = none ] && command -v nvidia-smi >/dev/null; then
  q=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$q" ]; then GPU_KIND=nvidia; gpu_model=${q%%,*}; vram_total=$(echo "${q##*,}" | tr -d ' '); fi
fi
mem_total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
swap_total=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
gm=null; [ -n "$gpu_model" ] && gm=$(jstr "$gpu_model")
printf '{"v":1,"cpu_model":%s,"cores":%s,"threads":%s,"base_mhz":%s,"boost_mhz":%s,"gpu_model":%s,"vram_total_mb":%s,"ram_total_mb":%s,"swap_total_mb":%s,"interval":%s}\n' \
  "$(jstr "$cpu_model")" "$cores" "$threads" "$base_mhz" "$boost_mhz" "$gm" "$vram_total" "$mem_total" "$swap_total" "$INTERVAL" \
  > "$DIR/static.json.tmp" && mv "$DIR/static.json.tmp" "$DIR/static.json"

# ---- RAPL (cumulative energy counter; may be root-only on newer kernels) ----
RAPL=
for p in /sys/class/powercap/intel-rapl:[0-9] /sys/class/powercap/amd-rapl:[0-9]; do
  [ -r "$p/energy_uj" ] && RAPL=$p && break
done
rapl_max=0; [ -n "$RAPL" ] && rapl_max=$(< "$RAPL/max_energy_range_uj")
cpu_uj_acc=0; last_raw=; last_ts=0
prev_total=0; prev_idle=0

while :; do
  ts=$EPOCHSECONDS
  # CPU %
  read -r _ u n s i io irq sirq st _ < /proc/stat
  total=$((u+n+s+i+io+irq+sirq+st)); idle=$((i+io))
  dt=$((total-prev_total)); di=$((idle-prev_idle))
  if [ $prev_total -gt 0 ] && [ $dt -gt 0 ]; then
    p=$(( 1000*(dt-di)/dt )); cpu_pct="$((p/10)).$((p%10))"
  else cpu_pct=null; fi
  prev_total=$total; prev_idle=$idle
  # CPU MHz (mean of scaling_cur_freq, else /proc/cpuinfo)
  sum=0; c=0
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [ -r "$f" ] && { read -r v < "$f"; sum=$((sum+v)); c=$((c+1)); }
  done
  if [ $c -gt 0 ]; then cpu_mhz=$((sum/c/1000))
  else cpu_mhz=$(awk '/cpu MHz/{s+=$4;n++} END{if(n)printf "%d", s/n; else print "null"}' /proc/cpuinfo); fi
  # RAM
  mt=0; mf=0; mb=0; mc=0; sr=0; stt=0; sf=0; ma=0
  while read -r k v _; do
    case $k in MemTotal:) mt=$v;; MemFree:) mf=$v;; MemAvailable:) ma=$v;; Buffers:) mb=$v;; Cached:) mc=$v;;
      SReclaimable:) sr=$v;; SwapTotal:) stt=$v;; SwapFree:) sf=$v;; esac
  done < /proc/meminfo
  ram_used=$(( (mt-ma)/1024 )); ram_free=$((mf/1024)); ram_cached=$(( (mc+mb+sr)/1024 )); swap_used=$(( (stt-sf)/1024 ))
  # CPU power from RAPL counter
  cpu_uj=null; cpu_w=null
  if [ -n "$RAPL" ] && read -r raw < "$RAPL/energy_uj" 2>/dev/null; then
    if [ -n "$last_raw" ]; then
      d=$((raw-last_raw)); [ $d -lt 0 ] && d=$((d+rapl_max)); cpu_uj_acc=$((cpu_uj_acc+d))
      el=$((ts-last_ts)); [ $el -le 0 ] && el=1
      w=$((d/el)); cpu_w="$((w/1000000)).$(( (w%1000000)/100000 ))"
    fi
    last_raw=$raw; last_ts=$ts; cpu_uj=$cpu_uj_acc
  fi
  # GPU
  gpu_pct=null; gpu_mhz=null; vram_used=null; gpu_w=null
  if [ $GPU_KIND = amd ]; then
    read -r gpu_pct < "$GPU_DIR/gpu_busy_percent" 2>/dev/null
    [ -r "$GPU_DIR/mem_info_vram_used" ] && vram_used=$(( $(< "$GPU_DIR/mem_info_vram_used") / 1048576 ))
    if [ -r "$GPU_DIR/pp_dpm_sclk" ]; then
      m=$(grep '\*' "$GPU_DIR/pp_dpm_sclk" | awk '{print $2}'); gpu_mhz=${m%%[Mm]*}
    fi
    if [ -n "$GPU_HWMON" ]; then
      for pf in power1_average power1_input; do
        [ -r "$GPU_HWMON/$pf" ] && { read -r pw < "$GPU_HWMON/$pf"; gpu_w="$((pw/1000000)).$(( (pw%1000000)/100000 ))"; break; }
      done
    fi
  elif [ $GPU_KIND = nvidia ]; then
    IFS=', ' read -r gpu_pct vram_used gpu_mhz gpu_w _ < <(nvidia-smi --query-gpu=utilization.gpu,memory.used,clocks.sm,power.draw --format=csv,noheader,nounits 2>/dev/null)
  fi
  printf '{"v":1,"ts":%s,"cpu_pct":%s,"cpu_mhz":%s,"cpu_w":%s,"cpu_uj":%s,"gpu_pct":%s,"gpu_mhz":%s,"vram_used_mb":%s,"gpu_w":%s,"gpu_uj":null,"ram_used_mb":%s,"ram_free_mb":%s,"ram_cached_mb":%s,"swap_used_mb":%s}\n' \
    "$ts" "${cpu_pct:-null}" "${cpu_mhz:-null}" "$cpu_w" "$cpu_uj" "${gpu_pct:-null}" "${gpu_mhz:-null}" "${vram_used:-null}" "${gpu_w:-null}" \
    "$ram_used" "$ram_free" "$ram_cached" "$swap_used" >> "$LOG"
  # cap log size when nobody reads it
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt $MAX_BYTES ]; then
    tail -c $((MAX_BYTES/2)) "$LOG" | tail -n +2 > "$LOG.trim" && mv "$LOG.trim" "$LOG"
  fi
  sleep "$INTERVAL"
done
