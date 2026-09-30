#!/usr/bin/env bash
# 日本节点可用性复查（机场换 IP 后跑一次；✓ 则 GLOBAL 钉回日本）
KEY=$(python3 -c "import yaml; print(yaml.safe_load(open('$HOME/.dsh/.credentials.yaml'))['refs']['SUB2API_ANTIGRAVITY_KEY'])")
for n in "日本-TY-1-流量倍率:1" "日本-TY-2-流量倍率:1" "日本-TY-3-流量倍率:0.6" "日本-TY-4-流量倍率:0.6" "日本-TY-5-流量倍率:1" "日本-OS-1-流量倍率:0.6" "日本-OS-2-流量倍率:0.6" "日本-OS-3-流量倍率:1"; do
  curl -s -X PUT http://127.0.0.1:49173/proxies/GLOBAL -H 'Content-Type: application/json' -d "{\"name\":\"$n\"}" -o /dev/null
  curl -s -X DELETE http://127.0.0.1:49173/connections -o /dev/null; sleep 0.4
  res=$(curl -s --max-time 45 http://localhost:8080/v1/chat/completions -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" -d '{"model":"gemini-3.8-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":50}')
  case "$res" in *choices*) echo "✓ 日本恢复: $n"; exit 0;; *) echo "✗ $n";; esac
done
echo "✗ 全部日本节点仍不可用"
