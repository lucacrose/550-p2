#!/bin/bash
set -u
OUT=${1:-census-out.txt}
VMSEQ="101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117"
TMP=$(mktemp -d /tmp/census.XXXX)
echo "census start: $(date -u +%FT%TZ)" > "$OUT.tmp"
for v in $VMSEQ; do
  timeout 600 ssh -o ConnectTimeout=5 -o BatchMode=yes cc@192.168.77.$v \
    'ls -f /data/shared | grep -v "\.part$" | tail -n +3' \
    > "$TMP/v$v.names" 2>"$TMP/v$v.err"
  n=$(wc -l < "$TMP/v$v.names")
  echo "vm$v: $n names ($(date -u +%T))" >> "$OUT.tmp"
  if [ "$n" -lt 100 ]; then echo "vm$v: PROBLEM: $(head -2 "$TMP/v$v.err")" >> "$OUT.tmp"; fi
done
cat "$TMP"/v*.names | sort | uniq -c | awk '{print $2}' | sort | uniq -c \
  | awk '{h=$1; c=$2; hist[c]++; if(c>4) four[c]=1; tot+=$(1)} END {
      printf "copies-per-name histogram (name count by copy count):\n";
      for (k=1;k<=4;k++) printf "  exactly %d: %d\n", k, hist[k]?hist[k]:0;
      s=0; for (k=5;k in hist;k++) s+=hist[k];
      printf "  5+: %d\n", s;
    }' >> "$OUT.tmp" 2>/dev/null
cat "$TMP"/v*.names | sort | uniq -c > "$TMP/copies-per-name.txt"
echo "total unique names: $(wc -l < "$TMP/copies-per-name.txt")" >> "$OUT.tmp"
echo "histogram (copies per name):" >> "$OUT.tmp"
awk '{h[$1]++} END{for(k in h) printf "  %d copies: %d names\n", k, h[k]}' "$TMP/copies-per-name.txt" | sort -k1 -n >> "$OUT.tmp"
echo "max copies seen for one name:" >> "$OUT.tmp"
sort -k1 -nr "$TMP/copies-per-name.txt" | head -5 >> "$OUT.tmp"
cp "$OUT.tmp" "$OUT"
echo "census end: $(date -u +%FT%TZ)" >> "$OUT"
rm -rf "$TMP"
echo "wrote $OUT"
